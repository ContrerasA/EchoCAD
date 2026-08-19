extends SceneTree

# M32: move/copy bodies + appearance. Transform bakes into the built mesh
# (volume preserved, AABB moves, rotation about the body center), copies
# are parametric (source edits propagate), color rides the root feature and
# survives serialization, undo/suppress behave.

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
	push_error("m32_move_bodies: " + msg)
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


func _bodies() -> Array:
	return await BodyBuilder.build(_root.doc, _root)


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# A 40x30 box, 10 tall.
	var f1 := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.finish_sketch()
	await _idle()
	var body_id := _root.extrude(f1, Vector2(20, 15), 10.0)
	if body_id == "":
		return _fail("extrude refused")
	await _idle()

	var bodies: Array = await _bodies()
	if bodies.size() != 1:
		return _fail("expected 1 body")
	var mesh0: ArrayMesh = bodies[0]["mesh"]
	var vol0 := BodyBuilder.mesh_volume(mesh0)
	var c0 := mesh0.get_aabb().get_center()

	# --- move: translate (10, 5, 20) --------------------------------------
	var mid := _root.move_body(body_id, Vector3(10, 5, 20))
	if mid == "":
		return _fail("move refused")
	await _idle()
	bodies = await _bodies()
	var mesh1: ArrayMesh = bodies[0]["mesh"]
	if absf(BodyBuilder.mesh_volume(mesh1) - vol0) > vol0 * 1e-6:
		return _fail("move changed the volume")
	if mesh1.get_aabb().get_center().distance_to(
			c0 + Vector3(10, 5, 20)) > 1e-4:
		return _fail("move did not land at the offset")

	# --- rotation about the body center: 90° about Z swaps X/Y extents ----
	var batch := CmdMergeBatch.new("Edit Move", [])
	_root.stack.push_no_merge(batch)
	_root.stack.push(CmdSetFeatureFlag.new(mid, "rot_deg", 90.0))
	batch.seal()
	bodies = await _bodies()
	var box1 := (bodies[0]["mesh"] as ArrayMesh).get_aabb()
	if absf(box1.size.x - 30.0) > 1e-4 or absf(box1.size.y - 40.0) > 1e-4:
		return _fail("rotation did not swap extents: %s" % str(box1.size))
	if box1.get_center().distance_to(c0 + Vector3(10, 5, 20)) > 1e-4:
		return _fail("rotation did not pivot about the body center")

	# --- zero move refused, undo removes the feature ----------------------
	if _root.move_body(body_id, Vector3.ZERO) != "":
		return _fail("zero move accepted")
	_root.stack.undo()   # undo the rot edit
	_root.stack.undo()   # undo the move feature
	bodies = await _bodies()
	if (bodies[0]["mesh"] as ArrayMesh).get_aabb().get_center() \
			.distance_to(c0) > 1e-4:
		return _fail("undo did not restore the original placement")
	_root.stack.redo()
	_root.stack.redo()

	# --- suppress the move puts the body back -----------------------------
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(mid, "suppressed", true))
	bodies = await _bodies()
	if (bodies[0]["mesh"] as ArrayMesh).get_aabb().get_center() \
			.distance_to(c0) > 1e-4:
		return _fail("suppressed move still applied")
	_root.stack.undo()

	# --- copy: second body, parametric ------------------------------------
	var cid := _root.copy_body(body_id, Vector3(100, 0, 0))
	await _idle()
	bodies = await _bodies()
	if bodies.size() != 2:
		return _fail("copy did not produce a second body (%d)" % bodies.size())
	var copy_b: Dictionary = {}
	for b in bodies:
		if String(b["id"]) == cid:
			copy_b = b
	if copy_b.is_empty():
		return _fail("copy body id missing from the build")
	if absf(BodyBuilder.mesh_volume(copy_b["mesh"]) - vol0) > vol0 * 1e-6:
		return _fail("copy volume differs")
	# Source edit propagates: double the extrude height.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(body_id, "distance", 20.0))
	bodies = await _bodies()
	for b in bodies:
		if String(b["id"]) == cid \
				and absf(BodyBuilder.mesh_volume(b["mesh"]) - vol0 * 2.0) \
					> vol0 * 0.01:
			return _fail("copy did not follow the source edit")
	_root.stack.undo()

	# --- color on the root feature, serialized ----------------------------
	if _root.set_body_color(body_id, Color(0.9, 0.2, 0.2)) != "":
		return _fail("set color refused")
	bodies = await _bodies()
	var painted := false
	for b in bodies:
		if String(b["id"]) == body_id \
				and (b["color"] as Color).r > 0.85:
			painted = true
	if not painted:
		return _fail("built body did not carry the color")
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var sf2 := doc2.feature_by_id(body_id) as SolidFeature
	if sf2 == null or sf2.color.a <= 0.0 or sf2.color.r < 0.85:
		return _fail("color lost in serialization")
	# Transform + copy features round trip too.
	if not (doc2.feature_by_id(mid) is TransformFeature) \
			or not (doc2.feature_by_id(cid) is CopyBodyFeature):
		return _fail("move/copy features lost in serialization")
	var tf2 := doc2.feature_by_id(mid) as TransformFeature
	if tf2.translation.distance_to(Vector3(10, 5, 20)) > 1e-9 \
			or absf(tf2.rot_deg - 90.0) > 1e-9:
		return _fail("transform props lost in serialization")

	print("M32_MOVE_BODIES OK: move/rotate about center, undo/suppress, ",
		"parametric copy, color, serialization")
	return true
