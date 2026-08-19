extends SceneTree

# M33: solid mirror + body patterns. Mirror reflects across a plane with
# volume preserved and winding fixed (volume stays POSITIVE); linear and
# circular patterns place parametric instances; edits replay; serialization.

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
	push_error("m33_solid_patterns: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


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


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# An asymmetric body (L-ish rect off to +X) so mirroring is visible.
	var f1 := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2(30, 10), 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	_root.tools.set_active("rect")
	_click(Vector2(10, 0))
	_click(Vector2(40, 20))
	_root.finish_sketch()
	await _idle()
	var body_id := _root.extrude(f1, Vector2(25, 10), 8.0)
	await _idle()

	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var vol0 := BodyBuilder.mesh_volume(bodies[0]["mesh"])
	if vol0 <= 0.0:
		return _fail("source volume not positive")

	# --- mirror across YZ: lands in -X, volume still POSITIVE -------------
	var mid := _root.mirror_body(body_id, "YZ")
	if mid == "":
		return _fail("mirror refused")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2:
		return _fail("mirror did not add a body")
	var mirrored: Dictionary = {}
	for b in bodies:
		if String(b["id"]) == mid:
			mirrored = b
	if mirrored.is_empty():
		return _fail("mirrored body missing")
	var mbox := (mirrored["mesh"] as ArrayMesh).get_aabb()
	if mbox.position.x < -40.1 - 1e-3 or mbox.end.x > -9.9 + 1e-3:
		return _fail("mirror landed wrong: %s" % str(mbox))
	var mvol := BodyBuilder.mesh_volume(mirrored["mesh"])
	if absf(mvol - vol0) > vol0 * 1e-6:
		return _fail("mirror volume wrong: %f vs %f (winding flip?)"
			% [mvol, vol0])
	if _root.mirror_body(body_id, "bogus") != "":
		return _fail("bogus mirror plane accepted")

	# --- linear pattern 3 x 2 ---------------------------------------------
	var pid := _root.pattern_body(body_id, {
		"mode": PatternBodyFeature.MODE_LINEAR,
		"count1": 3, "offset1": Vector3(50, 0, 0),
		"count2": 2, "offset2": Vector3(0, 40, 0)})
	if pid == "":
		return _fail("linear pattern refused")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# source + mirror + 5 instances.
	if bodies.size() != 7:
		return _fail("3x2 pattern body count wrong (%d)" % bodies.size())
	var found_far := false
	for b in bodies:
		var box := (b["mesh"] as ArrayMesh).get_aabb()
		if box.position.distance_to(Vector3(110, 40, 0)) < 1e-3:
			found_far = true
		if String(b["id"]).begins_with(pid) \
				and absf(BodyBuilder.mesh_volume(b["mesh"]) - vol0) \
					> vol0 * 1e-6:
			return _fail("pattern instance volume drifted")
	if not found_far:
		return _fail("far pattern instance misplaced")
	# Edit the count parametrically.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(pid, "count2", 1))
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 4:
		return _fail("count edit did not replay (%d bodies)" % bodies.size())
	_root.stack.undo()

	# --- circular pattern: 4 about Z through a point ----------------------
	_root.stack.undo()   # drop the linear pattern
	var cid := _root.pattern_body(body_id, {
		"mode": PatternBodyFeature.MODE_CIRCULAR,
		"count1": 4, "axis_origin": Vector3.ZERO,
		"axis_dir": Vector3(0, 0, 1), "total_deg": 360.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 5:
		return _fail("circular pattern body count wrong (%d)" % bodies.size())
	# The 90° instance of a +X body lands in +Y.
	var hit_y := false
	for b in bodies:
		var box := (b["mesh"] as ArrayMesh).get_aabb()
		if box.get_center().distance_to(Vector3(-10, 25, 4)) < 1e-2:
			hit_y = true
	if not hit_y:
		return _fail("90-degree instance misplaced")
	# Partial-angle convention shared with the sketch tool.
	if absf(PatternBodyFeature.step_deg(3, 180.0) - 90.0) > 1e-9:
		return _fail("partial-angle step wrong")

	# --- suppress + serialization -----------------------------------------
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cid, "suppressed", true))
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2:
		return _fail("suppressed pattern still instanced")
	_root.stack.undo()
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var pf2 := doc2.feature_by_id(cid) as PatternBodyFeature
	var mf2 := doc2.feature_by_id(mid) as MirrorBodyFeature
	if pf2 == null or mf2 == null:
		return _fail("features lost in serialization")
	if pf2.mode != PatternBodyFeature.MODE_CIRCULAR or pf2.count1 != 4 \
			or mf2.plane != "YZ" or mf2.source != body_id:
		return _fail("feature props lost in serialization")

	print("M33_SOLID_PATTERNS OK: mirror (winding-safe), linear + circular ",
		"patterns, parametric edits, suppress, serialization")
	return true
