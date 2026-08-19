class_name SvgImporter
extends RefCounted
## SVG reader (M31), the second 2D interchange path after DXF. Pure
## GDScript, modeled on DxfImporter: parse -> neutral ents -> populate a
## fresh Sketch (welded endpoints, one undoable feature).
##
## Supported: path (M/L/H/V/C/S/Q/T/A/Z, absolute + relative), rect (sharp
## corners), circle, ellipse, line, polyline, polygon; nested <g> and
## element `transform` (translate/scale/rotate/matrix); viewBox + physical
## width/height (px at 96 dpi when unitless). SVG is Y-DOWN — the import
## flips into the sketch's Y-up frame, so what you see in a browser is what
## lands in the sketch.
##
## Curves: circles/arcs that stay circular under the transform come in as
## exact SketchCircle/SketchArc. Everything genuinely curved-and-not-
## circular (beziers, ellipses, arcs under non-uniform transforms) becomes a
## SketchSpline through points SAMPLED ON the source curve (the model's
## splines are G1 Catmull-Rom, so interiors are a close approximation while
## every sampled fit point is exact). Text/images/uses are skipped, counted,
## reported — an import never fails on them.

const WELD_MM := 0.001
const PX_TO_MM := 25.4 / 96.0
## Fit points sampled per cubic bezier span (chain junctions shared).
const SAMPLES_PER_CUBIC := 3

## -> {"ok", "error", "ents", "skipped", "size": Vector2 (mm),
##     "physical": bool — the root carried a real-world width/height
##     (mm/cm/in/pt); false means px-at-96-dpi was assumed and a caller
##     may rescale for a different DPI (M31 QA note)}
## ents: {"kind": "line"|"circle"|"arc"|"spline", ...} all in mm, Y-up.
static func parse(text: String) -> Dictionary:
	var xml := XMLParser.new()
	if xml.open_buffer(text.to_utf8_buffer()) != OK:
		return {"ok": false, "error": "not parsable XML", "ents": [],
			"skipped": 0}
	var ents: Array = []
	var skipped := 0
	var stack: Array = []          # Transform2D per open group
	var root := Transform2D.IDENTITY
	var saw_svg := false
	var size_mm := Vector2.ZERO
	var physical := false
	while xml.read() == OK:
		var t := xml.get_node_type()
		if t == XMLParser.NODE_ELEMENT_END:
			var closing := xml.get_node_name()
			if closing == "g" and not stack.is_empty():
				stack.pop_back()
			continue
		if t != XMLParser.NODE_ELEMENT:
			continue
		var name := xml.get_node_name()
		var empty := xml.is_empty()
		match name:
			"svg":
				if saw_svg:
					continue
				saw_svg = true
				var r := _root_transform(xml)
				root = r["xf"]
				size_mm = r["size"]
				physical = r["physical"]
				stack = [root]
			"g":
				var xf: Transform2D = _tip(stack) * _transform_of(xml)
				if not empty:
					stack.append(xf)
			"path":
				_parse_path(xml.get_named_attribute_value_safe("d"),
					_tip(stack) * _transform_of(xml), ents)
			"rect":
				_emit_rect(xml, _tip(stack) * _transform_of(xml), ents)
			"circle":
				_emit_circle(xml, _tip(stack) * _transform_of(xml), ents)
			"ellipse":
				_emit_ellipse(xml, _tip(stack) * _transform_of(xml), ents)
			"line":
				var lxf := _tip(stack) * _transform_of(xml)
				ents.append({"kind": "line",
					"a": lxf * Vector2(_f(xml, "x1"), _f(xml, "y1")),
					"b": lxf * Vector2(_f(xml, "x2"), _f(xml, "y2"))})
			"polyline", "polygon":
				_emit_poly(xml, _tip(stack) * _transform_of(xml),
					name == "polygon", ents)
			"text", "image", "use":
				skipped += 1
			_:
				pass   # defs/style/title/desc/metadata... structural, free
	if not saw_svg:
		return {"ok": false, "error": "no <svg> element", "ents": [],
			"skipped": 0}
	if ents.is_empty():
		return {"ok": false, "error": "no importable geometry", "ents": [],
			"skipped": skipped}
	return {"ok": true, "error": "", "ents": ents, "skipped": skipped,
		"size": size_mm, "physical": physical}


static func _tip(stack: Array) -> Transform2D:
	return stack.back() if not stack.is_empty() else Transform2D.IDENTITY


static func _f(xml: XMLParser, attr: String, def := 0.0) -> float:
	var s := xml.get_named_attribute_value_safe(attr)
	return s.to_float() if s.strip_edges().is_valid_float() else def


## Length attr ("100", "40mm", "2in", "96px") -> mm. NAN when absent.
static func _len_mm(s: String) -> float:
	s = s.strip_edges()
	if s == "":
		return NAN
	var mult := PX_TO_MM
	for suffix_def: Array in [["mm", 1.0], ["cm", 10.0], ["in", 25.4],
			["pt", 25.4 / 72.0], ["px", PX_TO_MM]]:
		if s.ends_with(suffix_def[0]):
			mult = suffix_def[1]
			s = s.trim_suffix(suffix_def[0]).strip_edges()
			break
	return s.to_float() * mult if s.is_valid_float() else NAN


## Does the length string carry a REAL-WORLD unit (mm/cm/in/pt)? Bare
## numbers and px are screen units, subject to a DPI assumption.
static func _len_physical(s: String) -> bool:
	s = s.strip_edges()
	for suffix in ["mm", "cm", "in", "pt"]:
		if s.ends_with(suffix):
			return true
	return false


## The svg element's user-space -> mm Y-up transform + document size (mm).
static func _root_transform(xml: XMLParser) -> Dictionary:
	var vb := xml.get_named_attribute_value_safe("viewBox").split_floats(" ",
		false)
	if vb.size() != 4:
		var alt := xml.get_named_attribute_value_safe("viewBox").replace(
			",", " ").split_floats(" ", false)
		vb = alt
	var w_mm := _len_mm(xml.get_named_attribute_value_safe("width"))
	var h_mm := _len_mm(xml.get_named_attribute_value_safe("height"))
	var minx := 0.0
	var miny := 0.0
	var vw := 0.0
	var vh := 0.0
	if vb.size() == 4:
		minx = vb[0]
		miny = vb[1]
		vw = vb[2]
		vh = vb[3]
	if vw <= 0.0 or vh <= 0.0:
		# No viewBox: user units are px; size from width/height if present.
		vw = w_mm / PX_TO_MM if not is_nan(w_mm) else 100.0
		vh = h_mm / PX_TO_MM if not is_nan(h_mm) else 100.0
	var s := PX_TO_MM
	if not is_nan(w_mm) and vw > 0.0:
		s = w_mm / vw
	elif not is_nan(h_mm) and vh > 0.0:
		s = h_mm / vh
	# (x, y)user -> ((x-minx)*s, (miny+vh-y)*s): Y flip, origin bottom-left.
	var xf := Transform2D(Vector2(s, 0), Vector2(0, -s),
		Vector2(-minx * s, (miny + vh) * s))
	var physical := _len_physical(
			xml.get_named_attribute_value_safe("width")) \
		or _len_physical(xml.get_named_attribute_value_safe("height"))
	return {"xf": xf, "size": Vector2(vw * s, vh * s), "physical": physical}


## `transform` attribute -> Transform2D (SVG matrix order, left-to-right).
static func _transform_of(xml: XMLParser) -> Transform2D:
	return parse_transform(xml.get_named_attribute_value_safe("transform"))


static func parse_transform(s: String) -> Transform2D:
	var out := Transform2D.IDENTITY
	var re := RegEx.create_from_string(
		"(matrix|translate|scale|rotate|skewX|skewY)\\s*\\(([^)]*)\\)")
	for m in re.search_all(s):
		var op := m.get_string(1)
		var args := m.get_string(2).replace(",", " ").split_floats(" ", false)
		var t := Transform2D.IDENTITY
		match op:
			"matrix":
				if args.size() == 6:
					t = Transform2D(Vector2(args[0], args[1]),
						Vector2(args[2], args[3]), Vector2(args[4], args[5]))
			"translate":
				t = Transform2D(0.0, Vector2(args[0] if args.size() > 0 else 0.0,
					args[1] if args.size() > 1 else 0.0))
			"scale":
				var sx: float = args[0] if args.size() > 0 else 1.0
				var sy: float = args[1] if args.size() > 1 else sx
				t = Transform2D(Vector2(sx, 0), Vector2(0, sy), Vector2.ZERO)
			"rotate":
				var ang: float = deg_to_rad(args[0]) if args.size() > 0 else 0.0
				if args.size() >= 3:
					var c := Vector2(args[1], args[2])
					t = Transform2D(0.0, c) * Transform2D(ang, Vector2.ZERO) \
						* Transform2D(0.0, -c)
				else:
					t = Transform2D(ang, Vector2.ZERO)
			"skewX":
				if args.size() > 0:
					t = Transform2D(Vector2(1, 0),
						Vector2(tan(deg_to_rad(args[0])), 1), Vector2.ZERO)
			"skewY":
				if args.size() > 0:
					t = Transform2D(Vector2(1, tan(deg_to_rad(args[0]))),
						Vector2(0, 1), Vector2.ZERO)
		out = out * t
	return out


## Is `xf` a uniform scale + rotation (+ flip) — i.e. circles stay circles?
static func _is_conformal(xf: Transform2D) -> bool:
	var a := xf.x
	var b := xf.y
	return absf(a.length() - b.length()) < 1e-6 * maxf(a.length(), 1.0) \
		and absf(a.dot(b)) < 1e-6 * maxf(a.length_squared(), 1.0)


static func _emit_rect(xml: XMLParser, xf: Transform2D, ents: Array) -> void:
	var x := _f(xml, "x")
	var y := _f(xml, "y")
	var w := _f(xml, "width")
	var h := _f(xml, "height")
	if w <= 0.0 or h <= 0.0:
		return
	var c: Array = [xf * Vector2(x, y), xf * Vector2(x + w, y),
		xf * Vector2(x + w, y + h), xf * Vector2(x, y + h)]
	for i in 4:
		ents.append({"kind": "line", "a": c[i], "b": c[(i + 1) % 4]})


static func _emit_circle(xml: XMLParser, xf: Transform2D, ents: Array) -> void:
	var c := Vector2(_f(xml, "cx"), _f(xml, "cy"))
	var r := _f(xml, "r")
	if r <= 0.0:
		return
	if _is_conformal(xf):
		ents.append({"kind": "circle", "c": xf * c, "r": r * xf.x.length()})
	else:
		_ring_spline(xf, c, r, r, ents)


static func _emit_ellipse(xml: XMLParser, xf: Transform2D, ents: Array) -> void:
	var c := Vector2(_f(xml, "cx"), _f(xml, "cy"))
	var rx := _f(xml, "rx")
	var ry := _f(xml, "ry")
	if rx <= 0.0 or ry <= 0.0:
		return
	if absf(rx - ry) < 1e-9 and _is_conformal(xf):
		ents.append({"kind": "circle", "c": xf * c, "r": rx * xf.x.length()})
	else:
		_ring_spline(xf, c, rx, ry, ents)


## Closed spline through 12 points sampled on an ellipse (user space).
static func _ring_spline(xf: Transform2D, c: Vector2, rx: float, ry: float,
		ents: Array) -> void:
	var pts: Array = []
	for k in 12:
		var a := TAU * k / 12.0
		pts.append(xf * (c + Vector2(cos(a) * rx, sin(a) * ry)))
	ents.append({"kind": "spline", "pts": pts, "closed": true})


static func _emit_poly(xml: XMLParser, xf: Transform2D, close: bool,
		ents: Array) -> void:
	var nums := xml.get_named_attribute_value_safe("points").replace(
		",", " ").split_floats(" ", false)
	var pts: Array = []
	var i := 0
	while i + 1 < nums.size():
		pts.append(xf * Vector2(nums[i], nums[i + 1]))
		i += 2
	for k in pts.size() - 1:
		ents.append({"kind": "line", "a": pts[k], "b": pts[k + 1]})
	if close and pts.size() > 2:
		ents.append({"kind": "line", "a": pts[pts.size() - 1], "b": pts[0]})


## --- path data ---------------------------------------------------------------

## Tokenize + walk one `d` attribute, emitting lines / arcs / spline chains
## (already transformed by `xf`).
static func _parse_path(d: String, xf: Transform2D, ents: Array) -> void:
	if d.strip_edges() == "":
		return
	var toks := _tokenize_path(d)
	var i := 0
	var cur := Vector2.ZERO          # user space
	var start := Vector2.ZERO
	var last_cmd := ""
	var last_ctrl := Vector2.ZERO    # for S/T reflection
	# Curve chain being accumulated: fit points in USER space.
	var chain: Array = []
	var chain_started_at := Vector2.ZERO
	# NOTE: mutate `chain` only (clear/append) — a lambda captures the
	# VARIABLE by value, so a `chain = []` inside would rebind the lambda's
	# copy and silently split it from the loop's array.
	var flush_chain := func(closed := false) -> void:
		if chain.size() >= 2:
			var out: Array = []
			for p in chain:
				out.append(xf * p)
			# A chain that loops back onto its own start IS a closed curve —
			# mark it so, or ProfileFinder sees an open spline whose welded
			# endpoints collapse to one node and drops it, which is exactly
			# why all-curve outlines (circles drawn as beziers, blobs) never
			# highlighted in Extrude picking (QA §M31.2/7).
			if not closed and out.size() > 2 and (out[0] as Vector2) \
					.distance_to(out[out.size() - 1]) < WELD_MM:
				closed = true
			ents.append({"kind": "spline", "pts": out, "closed": closed})
		chain.clear()

	while i < toks.size():
		var tok = toks[i]
		var cmd := ""
		if tok is String:
			cmd = tok
			i += 1
		else:
			# Implicit command repetition; M/m repeat as L/l.
			cmd = last_cmd
			if cmd == "M":
				cmd = "L"
			elif cmd == "m":
				cmd = "l"
		if cmd == "":
			return
		var prev_cmd := last_cmd
		last_cmd = cmd
		var rel := cmd == cmd.to_lower()
		var base := cur if rel else Vector2.ZERO
		match cmd.to_upper():
			"M":
				flush_chain.call()
				cur = base + Vector2(_num(toks, i), _num(toks, i + 1))
				i += 2
				start = cur
			"L":
				flush_chain.call()
				var to := base + Vector2(_num(toks, i), _num(toks, i + 1))
				i += 2
				_line(xf, cur, to, ents)
				cur = to
			"H":
				flush_chain.call()
				var to2 := Vector2((base.x if rel else 0.0) + _num(toks, i), cur.y)
				i += 1
				_line(xf, cur, to2, ents)
				cur = to2
			"V":
				flush_chain.call()
				var to3 := Vector2(cur.x, (base.y if rel else 0.0) + _num(toks, i))
				i += 1
				_line(xf, cur, to3, ents)
				cur = to3
			"Z":
				flush_chain.call()
				if cur.distance_to(start) > 1e-9:
					_line(xf, cur, start, ents)
				cur = start
			"C", "S", "Q", "T":
				var c1 := Vector2.ZERO
				var c2 := Vector2.ZERO
				var to4 := Vector2.ZERO
				var up := cmd.to_upper()
				if up == "C":
					c1 = base + Vector2(_num(toks, i), _num(toks, i + 1))
					c2 = base + Vector2(_num(toks, i + 2), _num(toks, i + 3))
					to4 = base + Vector2(_num(toks, i + 4), _num(toks, i + 5))
					i += 6
				elif up == "S":
					c1 = cur * 2.0 - last_ctrl \
						if last_cmd_curve(prev_cmd, ["C", "S"]) else cur
					c2 = base + Vector2(_num(toks, i), _num(toks, i + 1))
					to4 = base + Vector2(_num(toks, i + 2), _num(toks, i + 3))
					i += 4
				elif up == "Q":
					var q := base + Vector2(_num(toks, i), _num(toks, i + 1))
					to4 = base + Vector2(_num(toks, i + 2), _num(toks, i + 3))
					i += 4
					c1 = cur + (q - cur) * (2.0 / 3.0)
					c2 = to4 + (q - to4) * (2.0 / 3.0)
					last_ctrl = q
				else:   # T
					var q2 := cur * 2.0 - last_ctrl \
						if last_cmd_curve(prev_cmd, ["Q", "T"]) else cur
					to4 = base + Vector2(_num(toks, i), _num(toks, i + 1))
					i += 2
					c1 = cur + (q2 - cur) * (2.0 / 3.0)
					c2 = to4 + (q2 - to4) * (2.0 / 3.0)
					last_ctrl = q2
				if up == "C" or up == "S":
					last_ctrl = c2
				_chain_cubic(chain, cur, c1, c2, to4)
				cur = to4
			"A":
				# An exact-arc emission would break the running chain's
				# continuity bookkeeping — flush first; elliptical fallbacks
				# start a fresh chain at `cur` inside the helper.
				flush_chain.call()
				var rx := absf(_num(toks, i))
				var ry := absf(_num(toks, i + 1))
				var rot := deg_to_rad(_num(toks, i + 2))
				var large := _num(toks, i + 3) != 0.0
				var sweep := _num(toks, i + 4) != 0.0
				var to5 := base + Vector2(_num(toks, i + 5), _num(toks, i + 6))
				i += 7
				_emit_svg_arc(xf, cur, to5, rx, ry, rot, large, sweep,
					ents, chain)
				cur = to5
			_:
				return   # unknown command: stop parsing this path safely
	# Close a trailing curve chain (flush marks it closed itself when it
	# loops back onto its start).
	flush_chain.call()


static func last_cmd_curve(prev: String, kinds: Array) -> bool:
	return prev.to_upper() in kinds


static func _line(xf: Transform2D, a: Vector2, b: Vector2, ents: Array) -> void:
	if a.distance_to(b) < 1e-9:
		return
	ents.append({"kind": "line", "a": xf * a, "b": xf * b})


## Append fit points sampled on cubic (p0..p3) to the running chain.
static func _chain_cubic(chain: Array, p0: Vector2, p1: Vector2, p2: Vector2,
		p3: Vector2) -> void:
	if chain.is_empty():
		chain.append(p0)
	for k in range(1, SAMPLES_PER_CUBIC + 1):
		var t := float(k) / SAMPLES_PER_CUBIC
		var mt := 1.0 - t
		chain.append(p0 * (mt * mt * mt) + p1 * (3.0 * mt * mt * t)
			+ p2 * (3.0 * mt * t * t) + p3 * (t * t * t))


## SVG endpoint-parametrized elliptical arc. Circular arcs under conformal
## transforms come in EXACT (SketchArc); anything else joins the spline
## chain via bezier sampling.
static func _emit_svg_arc(xf: Transform2D, from: Vector2, to: Vector2,
		rx: float, ry: float, rot: float, large: bool, sweep: bool,
		ents: Array, chain: Array) -> void:
	if rx < 1e-9 or ry < 1e-9 or from.distance_to(to) < 1e-9:
		if from.distance_to(to) > 1e-9:
			_line(xf, from, to, ents)
		return
	# Endpoint -> center parametrization (SVG spec B.2.4).
	var cr := cos(rot)
	var sr := sin(rot)
	var dp := (from - to) * 0.5
	var p1 := Vector2(cr * dp.x + sr * dp.y, -sr * dp.x + cr * dp.y)
	var lam := (p1.x * p1.x) / (rx * rx) + (p1.y * p1.y) / (ry * ry)
	if lam > 1.0:
		var sl := sqrt(lam)
		rx *= sl
		ry *= sl
	var num := rx * rx * ry * ry - rx * rx * p1.y * p1.y - ry * ry * p1.x * p1.x
	var den := rx * rx * p1.y * p1.y + ry * ry * p1.x * p1.x
	var co := sqrt(maxf(num / den, 0.0))
	if large == sweep:
		co = -co
	var cp := Vector2(co * rx * p1.y / ry, -co * ry * p1.x / rx)
	var center := Vector2(cr * cp.x - sr * cp.y, sr * cp.x + cr * cp.y) \
		+ (from + to) * 0.5
	var v1 := Vector2((p1.x - cp.x) / rx, (p1.y - cp.y) / ry)
	var v2 := Vector2((-p1.x - cp.x) / rx, (-p1.y - cp.y) / ry)
	var a0 := v1.angle()
	var da := fposmod(v2.angle() - v1.angle(), TAU)
	if not sweep and da > 0.0:
		da -= TAU
	if sweep and da < 0.0:
		da += TAU

	if absf(rx - ry) < 1e-9 * maxf(rx, 1.0) and _is_conformal(xf):
		# Exact circular arc. The transform may flip (root does: Y-flip),
		# which reverses the sweep direction in sketch space.
		var flips := xf.determinant() < 0.0
		var ccw := (da > 0.0) != flips
		ents.append({"kind": "arc", "c": xf * center,
			"r": rx * xf.x.length(),
			"from": xf * from, "to": xf * to, "ccw": ccw})
		return
	# General ellipse: sample straight into the chain (quarter-arc steps).
	if chain.is_empty():
		chain.append(from)
	var steps := maxi(2, int(ceil(absf(da) / (PI / 6.0))))
	for k in range(1, steps + 1):
		var a := a0 + da * k / steps
		var pt := Vector2(cos(a) * rx, sin(a) * ry)
		chain.append(center + Vector2(cr * pt.x - sr * pt.y,
			sr * pt.x + cr * pt.y))


static func _num(toks: Array, i: int) -> float:
	if i < toks.size() and toks[i] is float:
		return toks[i]
	return 0.0


static func _tokenize_path(d: String) -> Array:
	var out: Array = []
	var i := 0
	var n := d.length()
	while i < n:
		var ch := d[i]
		if ch == "," or ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
			i += 1
			continue
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z"):
			out.append(ch)
			i += 1
			continue
		# Number: sign, digits, dot, exponent. A second dot starts a new
		# number (SVG allows "1.5.5").
		var j := i
		var seen_dot := false
		var seen_exp := false
		while j < n:
			var c := d[j]
			if c >= "0" and c <= "9":
				j += 1
			elif c == "." and not seen_dot and not seen_exp:
				seen_dot = true
				j += 1
			elif (c == "e" or c == "E") and not seen_exp and j > i:
				seen_exp = true
				j += 1
				if j < n and (d[j] == "+" or d[j] == "-"):
					j += 1
			elif (c == "-" or c == "+") and j == i:
				j += 1
			else:
				break
		if j == i:
			i += 1   # unparsable character: skip it
			continue
		out.append(d.substr(i, j - i).to_float())
		i = j
	return out


## --- materialization ---------------------------------------------------------

## Build entities into a fresh sketch, welding endpoints (DxfImporter's
## pattern). -> census {"lines","arcs","circles","splines"}.
static func populate(sk: Sketch, ents: Array) -> Dictionary:
	var census := {"lines": 0, "arcs": 0, "circles": 0, "splines": 0}
	var weld := {}
	var point_for := func(pos: Vector2) -> String:
		var key := "%d|%d" % [roundi(pos.x / WELD_MM), roundi(pos.y / WELD_MM)]
		if weld.has(key):
			return String(weld[key])
		var np := SketchPoint.make(pos)
		np.id = sk.next_id()
		sk.add(np)
		weld[key] = np.id
		return np.id
	for ent: Dictionary in ents:
		match String(ent["kind"]):
			"line":
				var a: Vector2 = ent["a"]
				var b: Vector2 = ent["b"]
				if a.distance_to(b) < WELD_MM:
					continue
				var l := SketchLine.make(point_for.call(a), point_for.call(b))
				l.id = sk.next_id()
				sk.add(l)
				census["lines"] += 1
			"circle":
				var ci := SketchCircle.make(
					point_for.call(ent["c"] as Vector2), float(ent["r"]))
				ci.id = sk.next_id()
				sk.add(ci)
				census["circles"] += 1
			"arc":
				var arc := SketchArc.make(point_for.call(ent["c"] as Vector2),
					point_for.call(ent["from"] as Vector2),
					point_for.call(ent["to"] as Vector2), bool(ent["ccw"]))
				arc.id = sk.next_id()
				sk.add(arc)
				census["arcs"] += 1
			"spline":
				var pts: Array = ent["pts"]
				var closed := bool(ent["closed"])
				if closed and pts.size() > 2 and (pts[0] as Vector2) \
						.distance_to(pts[pts.size() - 1]) < WELD_MM:
					pts = pts.slice(0, pts.size() - 1)
				var ids: Array = []
				for p in pts:
					var pid: String = point_for.call(p as Vector2)
					if ids.is_empty() or ids[ids.size() - 1] != pid:
						ids.append(pid)
				if ids.size() < 2:
					continue
				var sp := SketchSpline.make(ids, closed)
				sp.id = sk.next_id()
				sk.add(sp)
				census["splines"] += 1
	return census
