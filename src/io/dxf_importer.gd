class_name DxfImporter
extends RefCounted
## DXF (ASCII) reader (M25). Round-trips DxfExporter's R12 output and reads
## the common real-world 2D subset: LINE, CIRCLE, ARC, POINT, LWPOLYLINE and
## R12 POLYLINE/VERTEX/SEQEND (bulge arcs included) from the ENTITIES
## section, in the drawing's XY. $INSUNITS scales into canonical mm (bare/
## unitless drawings are taken as mm). Layer "CONSTRUCTION" marks geometry
## construction. Everything else (blocks, splines, dimensions, 3D) is
## skipped, counted, and reported — an import never fails on them.

## $INSUNITS -> mm per drawing unit.
const UNIT_SCALE := {
	0: 1.0,     # unitless: assume mm
	1: 25.4,    # inches
	2: 304.8,   # feet
	4: 1.0,     # millimetres
	5: 10.0,    # centimetres
	6: 1000.0,  # metres
}

## Endpoints closer than this (mm) weld into one shared SketchPoint, so
## imported outlines close into profiles.
const WELD_MM := 0.001


## Parse DXF text -> {"ok": bool, "error": String, "ents": Array, "skipped":
## int}. Each ent: {"kind": "line"|"circle"|"arc"|"point", "construction":
## bool, ...geometry in mm}. Arcs are ccw from "a0" to "a1" (degrees) around
## "c" with radius "r" — DXF's own convention.
static func parse(text: String) -> Dictionary:
	# Tokenize into (code, value) pairs.
	var lines := text.split("\n")
	var pairs: Array = []
	var i := 0
	while i + 1 < lines.size():
		var code := lines[i].strip_edges()
		if code == "":
			i += 1
			continue
		if not code.is_valid_int():
			return {"ok": false, "error": "bad group code at line %d" % (i + 1),
				"ents": [], "skipped": 0}
		pairs.append([code.to_int(), lines[i + 1].strip_edges()])
		i += 2
	if pairs.is_empty():
		return {"ok": false, "error": "empty file", "ents": [], "skipped": 0}

	var scale := 1.0
	var ents: Array = []
	var skipped := 0
	var section := ""
	var idx := 0

	# One entity record: consume pairs until the next 0-code, into a dict of
	# code -> last value (plus arrays for repeatable polyline codes).
	var read_record := func(from: int) -> Dictionary:
		var rec := {"_codes": {}, "_xs": [], "_ys": [], "_bulges": [],
			"_bulge_at": {}}
		var j := from
		while j < pairs.size() and int(pairs[j][0]) != 0:
			var code := int(pairs[j][0])
			var val := String(pairs[j][1])
			(rec["_codes"] as Dictionary)[code] = val
			match code:
				10:
					(rec["_xs"] as Array).append(val.to_float())
				20:
					(rec["_ys"] as Array).append(val.to_float())
				42:
					# Bulge belongs to the vertex last started (a 10-code).
					(rec["_bulge_at"] as Dictionary)[
						(rec["_xs"] as Array).size() - 1] = val.to_float()
			j += 1
		rec["_next"] = j
		return rec

	while idx < pairs.size():
		var code := int(pairs[idx][0])
		var val := String(pairs[idx][1])
		if code == 0 and val == "SECTION" and idx + 1 < pairs.size():
			section = String(pairs[idx + 1][1])
			idx += 2
			continue
		if code == 0 and val == "ENDSEC":
			section = ""
			idx += 1
			continue
		if section == "HEADER" and code == 9 and val == "$INSUNITS":
			# The 70-code that follows carries the unit.
			if idx + 1 < pairs.size() and int(pairs[idx + 1][0]) == 70:
				var u := String(pairs[idx + 1][1]).to_int()
				scale = float(UNIT_SCALE.get(u, 1.0))
			idx += 1
			continue
		if section != "ENTITIES" or code != 0:
			idx += 1
			continue

		# An entity starts here.
		var rec: Dictionary = read_record.call(idx + 1)
		var codes: Dictionary = rec["_codes"]
		var cons := String(codes.get(8, "0")) == "CONSTRUCTION"
		var xs: Array = rec["_xs"]
		var ys: Array = rec["_ys"]
		match val:
			"LINE":
				if codes.has(10) and codes.has(11):
					ents.append({"kind": "line", "construction": cons,
						"a": Vector2(String(codes[10]).to_float(),
							String(codes.get(20, "0")).to_float()) * scale,
						"b": Vector2(String(codes[11]).to_float(),
							String(codes.get(21, "0")).to_float()) * scale})
			"CIRCLE":
				if codes.has(10) and codes.has(40):
					ents.append({"kind": "circle", "construction": cons,
						"c": Vector2(String(codes[10]).to_float(),
							String(codes.get(20, "0")).to_float()) * scale,
						"r": String(codes[40]).to_float() * scale})
			"ARC":
				if codes.has(10) and codes.has(40):
					ents.append({"kind": "arc", "construction": cons,
						"c": Vector2(String(codes[10]).to_float(),
							String(codes.get(20, "0")).to_float()) * scale,
						"r": String(codes[40]).to_float() * scale,
						"a0": String(codes.get(50, "0")).to_float(),
						"a1": String(codes.get(51, "0")).to_float()})
			"POINT":
				if codes.has(10):
					ents.append({"kind": "point", "construction": cons,
						"p": Vector2(String(codes[10]).to_float(),
							String(codes.get(20, "0")).to_float()) * scale})
			"LWPOLYLINE":
				_polyline_ents(ents, xs, ys, rec["_bulge_at"] as Dictionary,
					(String(codes.get(70, "0")).to_int() & 1) == 1, cons, scale)
			"POLYLINE":
				# R12 heavyweight polyline: vertices follow as VERTEX records
				# until SEQEND.
				var closed := (String(codes.get(70, "0")).to_int() & 1) == 1
				var vx: Array = []
				var vy: Array = []
				var vb := {}
				var j := int(rec["_next"])
				while j < pairs.size():
					if int(pairs[j][0]) != 0:
						j += 1
						continue
					var kind := String(pairs[j][1])
					if kind == "SEQEND":
						var seq: Dictionary = read_record.call(j + 1)
						j = int(seq["_next"])
						break
					if kind != "VERTEX":
						break
					var vrec: Dictionary = read_record.call(j + 1)
					var vcodes: Dictionary = vrec["_codes"]
					if vcodes.has(10):
						vx.append(String(vcodes[10]).to_float())
						vy.append(String(vcodes.get(20, "0")).to_float())
						if vcodes.has(42):
							vb[vx.size() - 1] = String(vcodes[42]).to_float()
					j = int(vrec["_next"])
				rec["_next"] = j
				_polyline_ents(ents, vx, vy, vb, closed, cons, scale)
			"ENDSEC", "EOF":
				pass
			_:
				skipped += 1
		idx = int(rec["_next"])

	if ents.is_empty():
		return {"ok": false, "error": "no importable entities "
			+ "(supported: LINE, CIRCLE, ARC, POINT, LWPOLYLINE, POLYLINE)",
			"ents": [], "skipped": skipped}
	return {"ok": true, "error": "", "ents": ents, "skipped": skipped}


## Expand one polyline's vertices into line/arc ents. A vertex bulge
## (tan of a quarter of the included angle, sign = ccw) turns that segment
## into an arc.
static func _polyline_ents(ents: Array, xs: Array, ys: Array,
		bulges: Dictionary, closed: bool, cons: bool, scale: float) -> void:
	var n := xs.size()
	if n < 2:
		return
	var count := n if closed else n - 1
	for i in count:
		var a := Vector2(float(xs[i]), float(ys[i])) * scale
		var b := Vector2(float(xs[(i + 1) % n]), float(ys[(i + 1) % n])) * scale
		if a.distance_to(b) < 1e-9:
			continue
		var bulge := float(bulges.get(i, 0.0))
		if absf(bulge) < 1e-9:
			ents.append({"kind": "line", "construction": cons, "a": a, "b": b})
			continue
		# Included angle theta = 4*atan(bulge); center sits on the chord's
		# perpendicular bisector, on the side the sign picks.
		var theta := 4.0 * atan(bulge)
		var chord := b - a
		var r := chord.length() / (2.0 * sin(absf(theta) * 0.5))
		var mid := (a + b) * 0.5
		var h := r * cos(absf(theta) * 0.5)     # center distance from chord
		var pn := Vector2(-chord.y, chord.x).normalized()   # left of a->b
		var center := mid + pn * h if bulge > 0.0 else mid - pn * h
		# DXF arc convention: ccw from a0 to a1. A negative bulge runs cw
		# from a to b — same arc ccw from b to a.
		var pa := a if bulge > 0.0 else b
		var pb := b if bulge > 0.0 else a
		ents.append({"kind": "arc", "construction": cons, "c": center,
			"r": r, "a0": rad_to_deg((pa - center).angle()),
			"a1": rad_to_deg((pb - center).angle())})


## Materialize parsed ents into `sk` (a sketch NOT yet in any document —
## the import builds the whole sketch first, then one CmdAddFeature makes
## it undoable as a unit). Endpoints weld within WELD_MM so closed outlines
## come in extrudable. -> census {"lines", "arcs", "circles", "points"}.
static func populate(sk: Sketch, ents: Array) -> Dictionary:
	var census := {"lines": 0, "arcs": 0, "circles": 0, "points": 0}
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
		var cons := bool(ent["construction"])
		match String(ent["kind"]):
			"line":
				var l := SketchLine.make(point_for.call(ent["a"] as Vector2),
					point_for.call(ent["b"] as Vector2))
				l.id = sk.next_id()
				l.construction = cons
				sk.add(l)
				census["lines"] += 1
			"circle":
				var cp: String = point_for.call(ent["c"] as Vector2)
				var ci := SketchCircle.make(cp, float(ent["r"]))
				ci.id = sk.next_id()
				ci.construction = cons
				sk.add(ci)
				census["circles"] += 1
			"arc":
				var c: Vector2 = ent["c"]
				var r := float(ent["r"])
				var sa := deg_to_rad(float(ent["a0"]))
				var ea := deg_to_rad(float(ent["a1"]))
				var sp: String = point_for.call(c + Vector2(cos(sa), sin(sa)) * r)
				var ep: String = point_for.call(c + Vector2(cos(ea), sin(ea)) * r)
				var ccp: String = point_for.call(c)
				var arc := SketchArc.make(ccp, sp, ep, true)
				arc.id = sk.next_id()
				arc.construction = cons
				sk.add(arc)
				census["arcs"] += 1
			"point":
				var pp := SketchPoint.make(ent["p"] as Vector2)
				pp.id = sk.next_id()
				pp.construction = cons
				sk.add(pp)
				census["points"] += 1
	return census
