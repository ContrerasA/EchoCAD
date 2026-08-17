extends SceneTree

# M21: DXF R12 export. Line/arc/circle/lone-point go out in sketch mm on
# layer 0, construction geometry on CONSTRUCTION, cw arcs swap ends so DXF's
# ccw convention still draws the same arc, referenced points and the sketch
# origin are not exported, and $INSUNITS says millimetres.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m21_dxf_export: " + msg)
	return false


## DXF text -> Array of {type, layer, codes: {code: [values...]}}.
func _parse_entities(text: String) -> Array:
	var lines := text.split("\n", false)
	var out: Array = []
	var cur: Dictionary = {}
	var in_entities := false
	var i := 0
	while i + 1 < lines.size():
		var code := int(lines[i].strip_edges())
		var val := lines[i + 1].strip_edges()
		i += 2
		if code == 2 and val == "ENTITIES":
			in_entities = true
			continue
		if not in_entities:
			continue
		if code == 0:
			if val == "ENDSEC":
				break
			cur = {"type": val, "layer": "", "codes": {}}
			out.append(cur)
			continue
		if cur.is_empty():
			continue
		if code == 8:
			cur["layer"] = val
		var codes: Dictionary = cur["codes"]
		if not codes.has(code):
			codes[code] = []
		(codes[code] as Array).append(val)
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()

	# Line (10,0)-(50,0); construction line (0,20)-(10,30); circle c(0,-30)
	# r=8; ccw arc and cw arc on the same three points; one lone point.
	var mk_pt := func(p: Vector2) -> String:
		var e := SketchPoint.make(p)
		e.id = sk.next_id()
		sk.add(e)
		return e.id
	var a: String = mk_pt.call(Vector2(10, 0))
	var b: String = mk_pt.call(Vector2(50, 0))
	var l := SketchLine.make(a, b)
	l.id = sk.next_id()
	sk.add(l)
	var c1: String = mk_pt.call(Vector2(0, 20))
	var c2: String = mk_pt.call(Vector2(10, 30))
	var cl := SketchLine.make(c1, c2)
	cl.id = sk.next_id()
	cl.construction = true
	sk.add(cl)
	var cc: String = mk_pt.call(Vector2(0, -30))
	var ci := SketchCircle.make(cc, 8.0)
	ci.id = sk.next_id()
	sk.add(ci)
	var ac: String = mk_pt.call(Vector2(-40, 0))
	var as_: String = mk_pt.call(Vector2(-30, 0))    # angle 0
	var ae: String = mk_pt.call(Vector2(-40, 10))    # angle 90
	var arc_ccw := SketchArc.make(ac, as_, ae, true)
	arc_ccw.id = sk.next_id()
	sk.add(arc_ccw)
	var arc_cw := SketchArc.make(ac, as_, ae, false)
	arc_cw.id = sk.next_id()
	sk.add(arc_cw)
	var _lone: String = mk_pt.call(Vector2(70, 70))

	var text := DxfExporter.to_dxf(sk)
	if not text.contains("$INSUNITS"):
		return _fail("missing $INSUNITS header")
	var ents := _parse_entities(text)

	var of_type := func(t: String) -> Array:
		var out2: Array = []
		for e: Dictionary in ents:
			if String(e["type"]) == t:
				out2.append(e)
		return out2

	var dxf_lines: Array = of_type.call("LINE")
	if dxf_lines.size() != 2:
		return _fail("expected 2 LINEs, got %d" % dxf_lines.size())
	var normal_line: Dictionary = {}
	var con_line: Dictionary = {}
	for e: Dictionary in dxf_lines:
		if String(e["layer"]) == "CONSTRUCTION":
			con_line = e
		else:
			normal_line = e
	if normal_line.is_empty() or con_line.is_empty():
		return _fail("construction layer split wrong")
	var codes: Dictionary = normal_line["codes"]
	if absf(float((codes[10] as Array)[0]) - 10.0) > 1e-6 \
			or absf(float((codes[11] as Array)[0]) - 50.0) > 1e-6:
		return _fail("line coords wrong: %s" % str(codes))

	var circles: Array = of_type.call("CIRCLE")
	if circles.size() != 1:
		return _fail("expected 1 CIRCLE, got %d" % circles.size())
	var ccodes: Dictionary = (circles[0] as Dictionary)["codes"]
	if absf(float((ccodes[40] as Array)[0]) - 8.0) > 1e-6 \
			or absf(float((ccodes[20] as Array)[0]) + 30.0) > 1e-6:
		return _fail("circle wrong: %s" % str(ccodes))

	var arcs: Array = of_type.call("ARC")
	if arcs.size() != 2:
		return _fail("expected 2 ARCs, got %d" % arcs.size())
	# Both arcs run 0deg..90deg in DXF: the ccw one as-is, the cw one with
	# its ends swapped (start was at 0deg, end at 90deg; cw swaps to 90->0,
	# which DXF then draws ccw 90..360+0 — so the SWAP must have happened,
	# giving 90..0 -> normalized [90, 0].
	var spans := {}
	for e: Dictionary in arcs:
		var ecodes: Dictionary = e["codes"]
		var a0 := float((ecodes[50] as Array)[0])
		var a1 := float((ecodes[51] as Array)[0])
		spans["%d-%d" % [roundi(a0), roundi(a1)]] = true
	if not spans.has("0-90"):
		return _fail("ccw arc span wrong: %s" % str(spans.keys()))
	if not spans.has("90-0"):
		return _fail("cw arc should swap ends to 90-0: %s" % str(spans.keys()))

	var points: Array = of_type.call("POINT")
	if points.size() != 1:
		return _fail("only the LONE point exports, got %d POINTs" % points.size())
	var pcodes: Dictionary = (points[0] as Dictionary)["codes"]
	if absf(float((pcodes[10] as Array)[0]) - 70.0) > 1e-6:
		return _fail("lone point coords wrong")

	# File-level API writes a parseable file and appends the extension.
	var path := "user://m21_test_out"
	if not _root.export_dxf(path):
		return _fail("export_dxf refused")
	var f := FileAccess.open("user://m21_test_out.dxf", FileAccess.READ)
	if f == null:
		return _fail("exported file missing (extension not appended?)")
	var ondisk := f.get_as_text()
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://m21_test_out.dxf"))
	if not ondisk.contains("ENTITIES") or not ondisk.contains("EOF"):
		return _fail("exported file malformed")

	print("M21_DXF_EXPORT OK: layers, mm units, line/circle/arc/point, "
		+ "cw arc end-swap, lone-point rule, file API")
	return true
