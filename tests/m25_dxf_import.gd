extends SceneTree

# M25: DXF import — export -> import round trip (census, coordinates,
# construction flags, weld -> profile), $INSUNITS scaling, LWPOLYLINE with
# bulge arcs, R12 POLYLINE/VERTEX/SEQEND, unsupported entities skipped,
# malformed refusal, one-undo-step import, import onto a construction plane.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m25_dxf_import: " + msg)
	return false


func _click(world: Vector2) -> void:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	_root.tools.handle_pointer_move(world, screen, InputEventMouseMotion.new())
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(world, screen, down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(world, screen, up)


func _census(sk: Sketch) -> Dictionary:
	var out := {"line": 0, "arc": 0, "circle": 0, "point": 0, "cons": 0}
	for e in sk.entities():
		out[e.kind()] = int(out.get(e.kind(), 0)) + 1
		if e.construction:
			out["cons"] += 1
	return out


func _has_point_at(sk: Sketch, pos: Vector2) -> bool:
	for e in sk.entities():
		if e.kind() == "point" and (e as SketchPoint).pos.distance_to(pos) < 1e-6:
			return true
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var dir := OS.get_cache_dir().path_join("echocad_m25")
	DirAccess.make_dir_recursive_absolute(dir)

	# --- round trip: rect + circle + a construction line + a lone point.
	var s1 := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.tools.set_active("circle")
	_click(Vector2(60, 15))
	_click(Vector2(65, 15))
	_root.tools.set_active("line")
	_click(Vector2(-10, 0))
	_click(Vector2(-10, 30))
	_root.tools.handle_cancel()
	_root.tools.set_active("point")
	_click(Vector2(70, 40))
	var sk := _root.active_sketch()
	# Flag the lone line construction (direct: this is export fixture setup).
	for e in sk.entities():
		if e.kind() == "line":
			var l := e as SketchLine
			if absf(sk.point(l.p0).pos.x + 10.0) < 1e-6:
				e.construction = true
	_root.finish_sketch()

	var p_round := dir.path_join("round.dxf")
	if DxfExporter.save(sk, p_round) != "":
		return _fail("export failed")
	var feats_before := _root.doc.features.size()
	var fid := _root.import_dxf(p_round)
	if fid == "":
		return _fail("round-trip import refused")
	var isk := _root.doc.sketch_feature(fid).sketch
	var c := _census(isk)
	if c["line"] != 5 or c["circle"] != 1 or c["arc"] != 0:
		return _fail("round-trip census wrong: %s" % c)
	if c["cons"] != 1:
		return _fail("construction flag lost: %s" % c)
	if not _has_point_at(isk, Vector2(70, 40)):
		return _fail("lone point lost")
	# Welded corners close the rect into an extrudable profile.
	var profs := ProfileFinder.profiles(isk)
	if profs.size() != 2:   # rect + circle
		return _fail("imported profiles wrong: %d" % profs.size())
	# One undo step removes the whole import.
	_root.stack.undo()
	if _root.doc.features.size() != feats_before:
		return _fail("import was not one undo step")
	_root.stack.redo()

	# --- $INSUNITS = 1 (inches): geometry scales x25.4.
	var inch_dxf := "\n".join(PackedStringArray([
		"0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "1",
		"0", "ENDSEC",
		"0", "SECTION", "2", "ENTITIES",
		"0", "LINE", "8", "0", "10", "0", "20", "0", "11", "1", "21", "0",
		"0", "ENDSEC", "0", "EOF"])) + "\n"
	var p_inch := dir.path_join("inch.dxf")
	var fi := FileAccess.open(p_inch, FileAccess.WRITE)
	fi.store_string(inch_dxf)
	fi.close()
	var fid2 := _root.import_dxf(p_inch)
	if fid2 == "":
		return _fail("inch import refused")
	var isk2 := _root.doc.sketch_feature(fid2).sketch
	var got_len := -1.0
	for e in isk2.entities():
		if e.kind() == "line":
			var l := e as SketchLine
			got_len = isk2.point(l.p0).pos.distance_to(isk2.point(l.p1).pos)
	if absf(got_len - 25.4) > 1e-6:
		return _fail("inch scaling wrong: %f" % got_len)

	# --- LWPOLYLINE: closed square + a 2-vertex bulge=1 semicircle; an
	# unsupported SPLINE is skipped without failing the import.
	var poly_dxf := "\n".join(PackedStringArray([
		"0", "SECTION", "2", "ENTITIES",
		"0", "LWPOLYLINE", "8", "0", "90", "4", "70", "1",
		"10", "0", "20", "0", "10", "20", "20", "0",
		"10", "20", "20", "20", "10", "0", "20", "20",
		"0", "LWPOLYLINE", "8", "0", "90", "2", "70", "0",
		"10", "40", "20", "0", "42", "1", "10", "50", "20", "0",
		"0", "SPLINE", "8", "0",
		"0", "ENDSEC", "0", "EOF"])) + "\n"
	var parsed := DxfImporter.parse(poly_dxf)
	if not bool(parsed["ok"]) or int(parsed["skipped"]) != 1:
		return _fail("polyline parse wrong: %s" % parsed)
	var p_poly := dir.path_join("poly.dxf")
	var fp := FileAccess.open(p_poly, FileAccess.WRITE)
	fp.store_string(poly_dxf)
	fp.close()
	var fid3 := _root.import_dxf(p_poly)
	var isk3 := _root.doc.sketch_feature(fid3).sketch
	var c3 := _census(isk3)
	if c3["line"] != 4 or c3["arc"] != 1:
		return _fail("polyline census wrong: %s" % c3)
	# The bulge arc: center (45,0), radius 5.
	for e in isk3.entities():
		if e.kind() == "arc":
			var arc := e as SketchArc
			var ctr: Vector2 = isk3.point(arc.center).pos
			var r := ctr.distance_to(isk3.point(arc.start).pos)
			if ctr.distance_to(Vector2(45, 0)) > 1e-6 or absf(r - 5.0) > 1e-6:
				return _fail("bulge arc wrong: c=%s r=%f" % [ctr, r])
	# The closed square welds into a profile.
	var sq := false
	for prof: Dictionary in ProfileFinder.profiles(isk3):
		if absf(float(prof["area"]) - 400.0) < 1.0:
			sq = true
	if not sq:
		return _fail("closed polyline did not weld into a profile")

	# --- R12 POLYLINE/VERTEX/SEQEND.
	var r12_dxf := "\n".join(PackedStringArray([
		"0", "SECTION", "2", "ENTITIES",
		"0", "POLYLINE", "8", "0", "70", "1", "66", "1",
		"0", "VERTEX", "8", "0", "10", "0", "20", "0",
		"0", "VERTEX", "8", "0", "10", "10", "20", "0",
		"0", "VERTEX", "8", "0", "10", "10", "20", "10",
		"0", "SEQEND",
		"0", "ENDSEC", "0", "EOF"])) + "\n"
	var parsed2 := DxfImporter.parse(r12_dxf)
	if not bool(parsed2["ok"]) or (parsed2["ents"] as Array).size() != 3:
		return _fail("R12 polyline parse wrong: %s" % parsed2)

	# --- malformed / empty refuse; the document stays untouched.
	if bool(DxfImporter.parse("this is not a dxf")["ok"]):
		return _fail("garbage accepted")
	var feats_now := _root.doc.features.size()
	var p_bad := dir.path_join("bad.dxf")
	var fb := FileAccess.open(p_bad, FileAccess.WRITE)
	fb.store_string("hello\nworld\n")
	fb.close()
	if _root.import_dxf(p_bad) != "":
		return _fail("malformed import accepted")
	if _root.doc.features.size() != feats_now:
		return _fail("failed import touched the document")

	# --- import onto a construction plane (M22 integration).
	var pid := _root.create_offset_plane("XY", 12.0)
	var fid4 := _root.import_dxf(p_round, pid)
	if fid4 == "":
		return _fail("import onto plane refused")
	var sf4 := _root.doc.sketch_feature(fid4)
	if sf4.plane != pid \
			or not sf4.plane_transform().origin.is_equal_approx(Vector3(0, 0, 12)):
		return _fail("imported sketch not on the construction plane")

	print("M25_DXF_IMPORT OK: round trip census + construction + welds, "
		+ "inch scaling, LWPOLYLINE bulge + closed weld, R12 POLYLINE, "
		+ "skip census, malformed refusal, one undo step, plane target")
	return true
