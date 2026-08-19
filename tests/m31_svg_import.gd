extends SceneTree

# M31: SVG import — shapes census, Y-flip + viewBox units to mm, transforms,
# path parsing (lines/beziers/arcs), welding into extrudable profiles,
# width override, spline fit points sampled exactly on source beziers,
# malformed input refusal.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m31_svg_import: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _write(fname: String, content: String) -> String:
	var path := OS.get_user_data_dir() + "/" + fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return path


func _kinds(sk: Sketch, kind: String) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e.kind() == kind:
			out.append(e)
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	await _idle()

	# --- rect + circle, physical mm size, Y-flip --------------------------
	var p1 := _write("m31_a.svg", """
<svg xmlns="http://www.w3.org/2000/svg" width="40mm" height="20mm"
     viewBox="0 0 40 20">
  <rect x="5" y="5" width="10" height="8"/>
  <circle cx="30" cy="10" r="6"/>
</svg>""")
	var f1 := _root.import_svg(p1, "XY")
	if f1 == "":
		return _fail("basic import refused")
	var sk1 := _root.doc.sketch_feature(f1).sketch
	if _kinds(sk1, "line").size() != 4 or _kinds(sk1, "circle").size() != 1:
		return _fail("census wrong: %d lines %d circles"
			% [_kinds(sk1, "line").size(), _kinds(sk1, "circle").size()])
	# viewBox unit == 1mm here. SVG y=5 (top) -> sketch y = 20-5 = 15; the
	# rect spans y 7..15. Circle at (30, 10).
	var ci := _kinds(sk1, "circle")[0] as SketchCircle
	var cc := sk1.point(ci.center).pos
	if cc.distance_to(Vector2(30, 10)) > 1e-6 or absf(ci.radius - 6.0) > 1e-6:
		return _fail("circle misplaced: %s r=%f" % [str(cc), ci.radius])
	var ys: Array = []
	for e in _kinds(sk1, "point"):
		ys.append((e as SketchPoint).pos.y)
	if not (ys.has(15.0) and ys.has(7.0)):
		return _fail("rect not Y-flipped into 7..15 (ys=%s)" % str(ys))
	# The rect welds into ONE closed profile.
	var profs := ProfileFinder.profiles(sk1)
	var areas: Array = []
	for pr in profs:
		areas.append(snappedf(absf(float(pr["area"])), 0.1))
	if not areas.has(80.0):
		return _fail("rect profile (80mm²) missing: %s" % str(areas))

	# --- px units: 96px == 25.4mm -----------------------------------------
	var p2 := _write("m31_px.svg", """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
  <rect x="0" y="0" width="96" height="96"/>
</svg>""")
	var f2 := _root.import_svg(p2, "XY")
	var sk2 := _root.doc.sketch_feature(f2).sketch
	var span := 0.0
	for e in _kinds(sk2, "point"):
		span = maxf(span, (e as SketchPoint).pos.x)
	if absf(span - 25.4) > 1e-4:
		return _fail("unitless px not read at 96dpi (span %f)" % span)

	# --- transforms + path with lines, bezier, arc ------------------------
	var p3 := _write("m31_path.svg", """
<svg xmlns="http://www.w3.org/2000/svg" width="100mm" viewBox="0 0 100 100">
  <g transform="translate(10,10)">
    <path d="M 0 0 L 20 0 A 10 10 0 0 1 40 0 L 60 0
             C 70 0 70 20 60 20 L 0 20 Z"/>
  </g>
</svg>""")
	var f3 := _root.import_svg(p3, "XY")
	if f3 == "":
		return _fail("path import refused")
	var sk3 := _root.doc.sketch_feature(f3).sketch
	if _kinds(sk3, "arc").size() != 1:
		return _fail("A command did not land as an exact arc")
	if _kinds(sk3, "spline").size() != 1:
		return _fail("C command did not land as a spline")
	if _kinds(sk3, "line").size() != 4:
		return _fail("path lines wrong (%d)" % _kinds(sk3, "line").size())
	# The whole outline welds into one closed profile.
	var profs3 := ProfileFinder.profiles(sk3)
	if profs3.size() != 1:
		return _fail("path outline did not weld closed (%d profiles)"
			% profs3.size())
	# Spline fit points lie exactly on the source cubic (10,10)-translated,
	# Y-flipped: source C from (60,0) ctrl (70,0)(70,20) to (60,20).
	var sp := _kinds(sk3, "spline")[0] as SketchSpline
	for pid in sp.points:
		var pos := sk3.point(pid).pos
		var on_curve := false
		for k in 301:
			var t := k / 300.0
			var mt := 1.0 - t
			var b: Vector2 = Vector2(60, 0) * (mt * mt * mt) \
				+ Vector2(70, 0) * (3 * mt * mt * t) \
				+ Vector2(70, 20) * (3 * mt * t * t) \
				+ Vector2(60, 20) * (t * t * t)
			var world := Vector2(b.x + 10, 100.0 - (b.y + 10))
			if world.distance_to(pos) < 0.05:
				on_curve = true
				break
		if not on_curve:
			return _fail("spline fit point %s not on the source bezier"
				% str(pos))
	# The arc's sweep bulges upward (sweep=1 in SVG Y-down = toward -y there
	# = +y here): its midpoint sits above the chord.
	var arc := _kinds(sk3, "arc")[0] as SketchArc
	var mid := SketchGeometry.closest_on_entity(sk3, arc,
		Vector2(40, 100 - 10 + 20))["pos"] as Vector2
	if mid.y <= 90.0:
		return _fail("arc winding flipped wrong (mid %s)" % str(mid))

	# --- width override rescales uniformly --------------------------------
	var f4 := _root.import_svg(p1, "XY", 80.0)
	var sk4 := _root.doc.sketch_feature(f4).sketch
	var ci4 := _kinds(sk4, "circle")[0] as SketchCircle
	if absf(ci4.radius - 12.0) > 1e-6:
		return _fail("width override did not scale (r=%f)" % ci4.radius)

	# --- one undo step per import -----------------------------------------
	var n_features := _root.doc.features.size()
	_root.stack.undo()
	if _root.doc.features.size() != n_features - 1:
		return _fail("undo did not remove the imported sketch in one step")

	# --- malformed input refused, doc untouched ---------------------------
	var junk := _write("m31_junk.svg", "this is not xml <at all")
	var nf := _root.doc.features.size()
	if _root.import_svg(junk, "XY") != "":
		return _fail("garbage accepted")
	var empty := _write("m31_empty.svg",
		"<svg xmlns='http://www.w3.org/2000/svg'><desc>nothing</desc></svg>")
	if _root.import_svg(empty, "XY") != "":
		return _fail("geometry-free svg accepted")
	if _root.doc.features.size() != nf:
		return _fail("failed imports touched the document")

	print("M31_SVG_IMPORT OK: shapes, units, Y-flip, transforms, path ",
		"(lines/bezier/arc), welded profile, width override, refusal")
	return true
