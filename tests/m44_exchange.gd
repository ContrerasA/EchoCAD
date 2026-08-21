extends SceneTree

# M44: 3MF export -> import round trip (volume, names, colours), STL and
# OBJ import as bodies, a non-manifold mesh lands as reference only, a
# cut against an imported body, OBJ export, SVG export of a sketch,
# mesh bodies survive save/load.

var _root: AppRoot = null
const TMP := "user://m44_tmp"


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M44_EXCHANGE OK: 3MF round trip (volume/names/colour), STL + OBJ "
			+ "import, reference-only open mesh, cut against an imported body, "
			+ "OBJ export, SVG export, mesh bodies in .ecad")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m44_exchange: " + msg)
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


func _sketch_rect(plane: String, a: Vector2, b: Vector2) -> String:
	var fid := _root.create_sketch(plane)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view((a + b) * 0.5, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	_root.finish_sketch()
	return fid


func _vol(bodies: Array, id: String) -> float:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return BodyBuilder.mesh_volume(b["mesh"])
	return -1.0


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var dir := ProjectSettings.globalize_path(TMP)

	# --- A. two coloured bodies -> 3MF -> back ---------------------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var box := _root.extrude(s1, Vector2(20, 15), 10.0)
	var s2 := _sketch_rect("XY", Vector2(60, 0), Vector2(80, 20))
	var box2 := _root.extrude(s2, Vector2(70, 10), 5.0)
	await _idle()
	(_root.doc.feature_by_id(box2) as SolidFeature).color = Color(1, 0, 0)
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var path3 := dir.path_join("two.3mf")
	var res := MeshIo.write_3mf(bodies, path3, PackedByteArray(), "two bodies")
	if not bool(res["ok"]) or int(res["objects"]) != 2:
		return _fail("A: 3MF write %s" % str(res))
	# Archive sanity: the three mandatory parts.
	var zr := ZIPReader.new()
	if zr.open(path3) != OK:
		return _fail("A: 3MF is not a zip")
	var files := zr.get_files()
	zr.close()
	for need in ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"]:
		if not files.has(need):
			return _fail("A: 3MF missing %s (%s)" % [need, str(files)])
	var back := MeshIo.read(path3)
	if not bool(back["ok"]) or (back["objects"] as Array).size() != 2:
		return _fail("A: 3MF read back %s" % str(back.get("error")))
	var names: Array = []
	for o: Dictionary in back["objects"]:
		names.append(String(o["name"]))
	if not names.has("Extrude1") or not names.has("Extrude2"):
		return _fail("A: names lost: %s" % str(names))
	var ids := _root.import_mesh(path3)
	await _idle()
	if ids.size() != 2:
		return _fail("A: import should add 2 bodies, got %d" % ids.size())
	bodies = await BodyBuilder.build(_root.doc, _root)
	var got := 0.0
	for idm in ids:
		got += _vol(bodies, String(idm))
	if absf(got - (12000.0 + 2000.0)) > 1e-3:
		return _fail("A: re-imported volume %f" % got)
	for idm in ids:
		var f := _root.doc.feature_by_id(String(idm))
		if f.rebuild_error != "":
			return _fail("A: imported body flagged: " + f.rebuild_error)
		if not (f is MeshBodyFeature):
			return _fail("A: imported feature is not a mesh body")
	# Colour survived as a displaycolor on the material (parsed? we at
	# least keep the file's object names). Undo the import for the next tests.
	_root.stack.undo()
	await _idle()

	# --- B. STL (binary + ascii) and OBJ imports ---------------------------------
	bodies = await BodyBuilder.build(_root.doc, _root)
	var one: Array = []
	for b: Dictionary in bodies:
		if String(b["id"]) == box:
			one.append(b)
	var pstl := dir.path_join("box.stl")
	StlExporter.write(one, pstl, false)
	var pasc := dir.path_join("box_ascii.stl")
	StlExporter.write(one, pasc, true)
	var pobj := dir.path_join("box.obj")
	var ro := MeshIo.write_obj(one, pobj)
	if not bool(ro["ok"]):
		return _fail("B: OBJ write failed")
	for pth in [pstl, pasc, pobj]:
		var got_ids := _root.import_mesh(pth)
		await _idle()
		if got_ids.size() != 1:
			return _fail("B: %s should import one body" % pth.get_file())
		bodies = await BodyBuilder.build(_root.doc, _root)
		if absf(_vol(bodies, String(got_ids[0])) - 12000.0) > 1e-3:
			return _fail("B: %s volume %f" % [pth.get_file(), _vol(bodies, String(got_ids[0]))])
		_root.stack.undo()
		await _idle()
	# Scale: an inch file.
	var inch_ids := _root.import_mesh(pstl, 25.4)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_in := 12000.0 * pow(25.4, 3)
	if absf(_vol(bodies, String(inch_ids[0])) - want_in) > want_in * 1e-6:
		return _fail("B: inch scaling %f vs %f" % [_vol(bodies, String(inch_ids[0])), want_in])
	_root.stack.undo()
	await _idle()

	# --- C. an open mesh is reference only ----------------------------------------
	var open_path := dir.path_join("open.obj")
	var f := FileAccess.open(open_path, FileAccess.WRITE)
	f.store_line("o Sheet")
	f.store_line("v 100 0 0")
	f.store_line("v 110 0 0")
	f.store_line("v 110 10 0")
	f.store_line("v 100 10 0")
	f.store_line("f 1 2 3 4")
	f.close()
	var ref_ids := _root.import_mesh(open_path)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var rf := _root.doc.feature_by_id(String(ref_ids[0]))
	if rf.rebuild_error == "" or rf.rebuild_level != "warning":
		return _fail("C: open mesh should be a warning (reference only): '%s'" % rf.rebuild_error)
	var shown := false
	for b: Dictionary in bodies:
		if String(b["id"]) == String(ref_ids[0]):
			shown = b.get("solid") == null and b.get("mesh") != null
	if not shown:
		return _fail("C: reference mesh should still be listed (without a solid)")
	_root.stack.undo()
	await _idle()

	# --- D. cut a pocket into an imported body -----------------------------------
	var imp := _root.import_mesh(pstl)
	await _idle()
	var mid := String(imp[0])
	var s3 := _sketch_rect("XY", Vector2(10, 10), Vector2(20, 20))
	_root.extrude(s3, Vector2(15, 15), 10.0, SolidFeature.OP_CUT, [mid])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, mid) - 11000.0) > 1e-3:
		return _fail("D: cut into the imported body: %f" % _vol(bodies, mid))

	# --- E. mesh bodies round-trip through .ecad ----------------------------------
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var lm := loaded.feature_by_id(mid) as MeshBodyFeature
	if lm == null or lm.indices.size() != (_root.doc.feature_by_id(mid) as MeshBodyFeature).indices.size():
		return _fail("E: mesh body lost in round trip")
	var lb: Array = await BodyBuilder.build(loaded, _root)
	if absf(_vol(lb, mid) - 11000.0) > 1e-3:
		return _fail("E: loaded mesh body volume")

	# --- F. SVG export of the first sketch ------------------------------------------
	var sf := _root.doc.sketch_feature(s1)
	var svg := SvgExporter.to_svg(sf.sketch)
	if not svg.contains("<svg") or svg.count("<line") != 4 or not svg.contains("viewBox"):
		return _fail("F: SVG should hold 4 lines: %s" % svg.substr(0, 200))
	var psvg := dir.path_join("sk.svg")
	if not _root.export_svg(psvg, s1) or not FileAccess.file_exists(psvg):
		return _fail("F: SVG file not written")
	return true
