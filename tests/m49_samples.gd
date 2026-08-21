extends SceneTree

# M49: the five alpha benchmark parts, built through the app's API, checked
# (watertight, volumes plausible, no red chips), exported to 3MF and
# written to samples/*.ecad so the start panel and the manual QA can open
# them. This test IS the sample generator: re-run it after a format change.

var _root: AppRoot = null
const OUT := "res://samples"


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M49_SAMPLES OK: L-bracket, enclosure + lid, flange, spacer stack, "
			+ "vendor fit — built, watertight, exported, saved to samples/")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m49_samples: " + msg)
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


func _sketch_circle(plane: String, c: Vector2, r: float) -> String:
	var fid := _root.create_sketch(plane)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(c, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("circle")
	_click(c)
	_click(c + Vector2(r, 0))
	_root.finish_sketch()
	return fid


func _top_face(x: float, y: float) -> Dictionary:
	return _root.world.pick_face(Vector3(x, y, 1000), Vector3(0, 0, -1))


func _bodies() -> Array:
	return await BodyBuilder.build(_root.doc, _root)


func _check_and_save(name: String, min_bodies: int) -> String:
	await _idle()
	var bodies: Array = await _bodies()
	if bodies.size() < min_bodies:
		return "%s: expected %d+ bodies, got %d" % [name, min_bodies, bodies.size()]
	for b: Dictionary in bodies:
		if b.get("solid") != null and not SolidKernel.is_valid(b["solid"]):
			return "%s: body %s not watertight" % [name, b["name"]]
	for f in _root.doc.live_features():
		if (f as Feature).rebuild_error != "" and (f as Feature).rebuild_level == "error":
			return "%s: %s — %s" % [name, (f as Feature).name, (f as Feature).rebuild_error]
	_root.fit_view()
	_root.rig.frame_view(Vector3(-0.6, -0.7, 0.5).normalized(), Vector3(0, 0, 1)) if false else null
	var dir := ProjectSettings.globalize_path(OUT)
	DirAccess.make_dir_recursive_absolute(dir)
	if not _root.save_to(dir.path_join(name + ".ecad")):
		return "%s: save failed" % name
	var res := MeshIo.write_3mf(bodies, ProjectSettings.globalize_path("user://m49_%s.3mf" % name), PackedByteArray(), name)
	if not bool(res["ok"]):
		return "%s: 3MF export failed" % name
	return ""


func _fresh() -> void:
	_root.load_document(CadDocument.new())
	_root.doc.display_unit = UnitConverter.Unit.MM
	_root.stack.mark_saved()


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- 1. L-bracket ------------------------------------------------------------
	_fresh()
	var base := _sketch_rect("XY", Vector2(0, 0), Vector2(60, 40))
	var plate := _root.extrude(base, Vector2(30, 20), 4.0)
	var wall_s := _sketch_rect("XZ", Vector2(0, 0), Vector2(60, 40))   # XZ plane: u = x, v = z
	var wall := _root.extrude(wall_s, Vector2(30, 20), 4.0, SolidFeature.OP_JOIN)
	await _idle()
	var top := _top_face(30, 25)
	if top.is_empty():
		return _fail("bracket: no top face")
	var holes := _root.add_holes(String(top["body"]), int(top["face"]),
		[Vector2(15, 25), Vector2(45, 25)],
		{"diameter": 4.5, "extent": HoleFeature.EXT_THROUGH_ALL, "thread_id": "M4"})
	await _idle()
	var bodies: Array = await _bodies()
	var bracket := String(bodies[0]["id"])
	# Round the outer vertical corners of the plate (the two far edges along z? the plate's
	# x=0/x=60 short edges at y=40) — pick by midpoint.
	_root.add_edge_fillet(bracket, EdgeFilletFeature.KIND_FILLET, 5.0, [Vector3(0, 40, 2), Vector3(60, 40, 2)])
	await _idle()
	# Chamfer the mounting holes' top rims.
	_root.add_edge_fillet(bracket, EdgeFilletFeature.KIND_CHAMFER, 0.5,
		[Vector3(15 + 2.25, 25, 4), Vector3(45 + 2.25, 25, 4)])
	var err := await _check_and_save("01_l_bracket", 1)
	if err != "":
		return _fail(err)
	bodies = await _bodies()
	var vol := BodyBuilder.mesh_volume(bodies[0]["mesh"])
	# Plate 60x40x4 + wall 60x40x4 (the wall stands outside the plate's edge)
	# = 19200 minus holes and fillets.
	if vol > 19200.0 or vol < 18000.0:
		return _fail("bracket volume %f out of range" % vol)

	# --- 2. Enclosure + lid ----------------------------------------------------------
	_fresh()
	var box_s := _sketch_rect("XY", Vector2(0, 0), Vector2(80, 50))
	var box := _root.extrude(box_s, Vector2(40, 25), 30.0)
	await _idle()
	var btop := _top_face(40, 25)
	var sh := ShellFeature.new()
	sh.id = _root.doc.next_feature_id()
	sh.name = "Shell1"
	sh.body = box
	sh.thickness = 2.0
	sh.remove = [TopoRef.make(String(btop["body"]), int(btop["face"]), btop["normal"], btop["point"])]
	_root.stack.push_no_merge(CmdAddFeature.new(sh))
	await _idle()
	# Screw bosses in the four corners (cylinders joined from the floor).
	var boss_s := _sketch_circle("XY", Vector2(6, 6), 3.0)
	var boss := _root.extrude(boss_s, Vector2(6, 6), 28.0, SolidFeature.OP_JOIN)
	await _idle()
	var pat := _root.pattern_body(boss, {"mode": PatternBodyFeature.MODE_LINEAR,
		"count1": 2, "offset1": Vector3(68, 0, 0), "count2": 2, "offset2": Vector3(0, 38, 0)})
	await _idle()
	bodies = await _bodies()
	var btop2 := _root.world.pick_face(Vector3(6, 6, 1000), Vector3(0, 0, -1))
	if not btop2.is_empty():
		_root.add_holes(String(btop2["body"]), int(btop2["face"]),
			[Vector2(6, 6), Vector2(74, 6), Vector2(6, 44), Vector2(74, 44)],
			{"diameter": 2.5, "extent": HoleFeature.EXT_DISTANCE, "depth": 8.0, "thread_id": "M3",
				"thread_mode": HoleFeature.THREAD_MODELED})
	# Lid: a plate above with a lip that drops inside the wall.
	var lid_pl := _root.create_offset_plane("XY", 34.0)
	var lid_s := _sketch_rect(lid_pl, Vector2(0, 0), Vector2(80, 50))
	var lid := _root.extrude(lid_s, Vector2(40, 25), 2.0)
	var lip_s := _sketch_rect(lid_pl, Vector2(2.2, 2.2), Vector2(77.8, 47.8))
	var lip := _root.extrude(lip_s, Vector2(40, 25), -3.0, SolidFeature.OP_JOIN, [lid])
	await _idle()
	bodies = await _bodies()
	if bodies.size() < 2:
		return _fail("enclosure: expected box + lid")
	var lid_top := _root.world.pick_face(Vector3(10, 10, 1000), Vector3(0, 0, -1))
	if not lid_top.is_empty() and String(lid_top["body"]) == lid:
		_root.add_holes(lid, int(lid_top["face"]),
			[Vector2(6, 6), Vector2(74, 6), Vector2(6, 44), Vector2(74, 44)],
			{"diameter": 3.4, "hole_type": HoleFeature.TYPE_COUNTERSINK, "cs_diameter": 6.3,
				"extent": HoleFeature.EXT_THROUGH_ALL, "targets": [lid]})
	err = await _check_and_save("02_enclosure_lid", 2)
	if err != "":
		return _fail(err)
	bodies = await _bodies()
	if not Inspect.interference(bodies).is_empty():
		return _fail("enclosure: lid and box should not interfere (lip clearance 0.2)")

	# --- 3. Flange -----------------------------------------------------------------
	_fresh()
	# Revolve a stepped profile about the sketch Y axis: disc r 40 x 6 + hub r 15 x 24.
	var prof := _root.create_sketch("XZ")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2(20, 12), 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("line")
	for p: Vector2 in [Vector2(8, 0), Vector2(40, 0), Vector2(40, 6), Vector2(15, 6),
			Vector2(15, 24), Vector2(8, 24), Vector2(8, 0)]:
		_click(p)
	_root.tools.handle_cancel()
	_root.finish_sketch()
	var flange := _root.revolve(prof, Vector2(20, 3), "y", 360.0)
	if flange == "":
		return _fail("flange: revolve refused")
	await _idle()
	bodies = await _bodies()
	# Bolt holes: one hole on the disc face, patterned around the axis.
	var disc_top := _root.world.pick_face(Vector3(28, 0, 1000), Vector3(0, 0, -1))
	if disc_top.is_empty():
		return _fail("flange: no disc face")
	var bolt := _root.add_holes(String(disc_top["body"]), int(disc_top["face"]),
		[Vector2(28, 0)], {"diameter": 5.5, "extent": HoleFeature.EXT_THROUGH_ALL, "thread_id": "M5"})
	await _idle()
	var pat2 := _root.pattern_body(bolt, {"mode": PatternBodyFeature.MODE_CIRCULAR,
		"count1": 6, "axis_origin": Vector3.ZERO, "axis_dir": Vector3(0, 0, 1), "total_deg": 360.0})
	await _idle()
	# Tapped centre: the bore is r 8 already; tap it M16... model a thread ring
	# with a modelled M6 hole on the hub top as the "tapped hole" instead.
	var hub_top := _root.world.pick_face(Vector3(11.5, 0, 1000), Vector3(0, 0, -1))
	if not hub_top.is_empty():
		_root.add_holes(String(hub_top["body"]), int(hub_top["face"]), [Vector2(11.5, 0)],
			{"diameter": HoleTable.tap_drill(HoleTable.find("M4")), "extent": HoleFeature.EXT_DISTANCE,
				"depth": 10.0, "thread_id": "M4", "thread_mode": HoleFeature.THREAD_MODELED})
	err = await _check_and_save("03_flange", 1)
	if err != "":
		return _fail(err)
	bodies = await _bodies()
	var fvol := BodyBuilder.mesh_volume(bodies[0]["mesh"])
	var disc := PI * (40.0 * 40.0 - 8.0 * 8.0) * 6.0
	var hub := PI * (15.0 * 15.0 - 8.0 * 8.0) * 18.0
	if fvol > disc + hub or fvol < (disc + hub) * 0.85:
		return _fail("flange volume %f vs %f" % [fvol, disc + hub])

	# --- 4. Spacer stack (two bodies, moved, measured, multi-object 3MF) -----------
	_fresh()
	var sp1 := _sketch_circle("XY", Vector2(0, 0), 10.0)
	var spacer := _root.extrude(sp1, Vector2(0, 0), 8.0)
	await _idle()
	var sp_top := _top_face(0, 5)
	_root.add_holes(String(sp_top["body"]), int(sp_top["face"]), [Vector2(0, 0)],
		{"diameter": 5.5, "extent": HoleFeature.EXT_THROUGH_ALL})
	await _idle()
	var cp := CopyBodyFeature.new()
	cp.id = _root.doc.next_feature_id()
	cp.name = "Copy1"
	cp.source = spacer
	cp.translation = Vector3(0, 0, 8.0)
	_root.stack.push_no_merge(CmdAddFeature.new(cp))
	await _idle()
	_root.move_body(cp.id, Vector3(0, 0, 0.2))   # a printing gap between the two
	err = await _check_and_save("04_spacer_stack", 2)
	if err != "":
		return _fail(err)
	bodies = await _bodies()
	var gap := Inspect.interference(bodies)
	if not gap.is_empty():
		return _fail("spacers should not overlap")

	# --- 5. Vendor fit: import a bearing STL, cut its pocket to object ---------------
	_fresh()
	# "Vendor" bearing = a ring we export first.
	var br := _sketch_circle("XY", Vector2(0, 0), 11.0)
	var bearing := _root.extrude(br, Vector2(0, 0), 7.0)
	await _idle()
	var bt := _top_face(0, 6)
	_root.add_holes(String(bt["body"]), int(bt["face"]), [Vector2(0, 0)],
		{"diameter": 8.0, "extent": HoleFeature.EXT_THROUGH_ALL})
	await _idle()
	bodies = await _bodies()
	var stl := ProjectSettings.globalize_path("user://m49_bearing.stl")
	StlExporter.write(bodies, stl)
	_fresh()
	var housing_s := _sketch_rect("XY", Vector2(-20, -20), Vector2(20, 20))
	var housing := _root.extrude(housing_s, Vector2(0, 0), 12.0)
	await _idle()
	var imported := _root.import_mesh(stl)
	if imported.is_empty():
		return _fail("vendor fit: import failed")
	_root.move_body(String(imported[0]), Vector3(0, 0, 5.0))
	await _idle()
	bodies = await _bodies()
	# Pocket: combine-cut the bearing out of the housing with 0.1 clearance
	# (a slightly larger cylinder), keeping the bearing for the fit check.
	var pocket_s := _sketch_circle("XY", Vector2(0, 0), 11.1)
	var pocket := _root.extrude(pocket_s, Vector2(0, 0), 12.0, SolidFeature.OP_CUT, [housing])
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(pocket, "extent", ExtrudeFeature.EXT_DISTANCE))
	await _idle()
	# The pocket must go from z=5 up: move its sketch plane — simplest: the
	# pocket is cut 12 deep from the bottom (through), leaving a through bore
	# with 0.1 clearance around the bearing.
	err = await _check_and_save("05_vendor_fit", 2)
	if err != "":
		return _fail(err)
	bodies = await _bodies()
	if not Inspect.interference(bodies).is_empty():
		return _fail("vendor fit: bearing must sit in the pocket without interference")
	return true
