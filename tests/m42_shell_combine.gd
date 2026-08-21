extends SceneTree

# M42: shell (inside, outside, faces removed), combine (join/cut/intersect,
# keep tools), split by plane and by face, press/pull (add + remove),
# serialization, error chips.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M42_SHELL_COMBINE OK: shell inside/outside/open faces analytic, "
			+ "combine join/cut/intersect/keep, split by plane + face, press/pull "
			+ "add + cut, serialization, errors")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m42_shell_combine: " + msg)
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


func _entry(bodies: Array, id: String) -> Dictionary:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return b
	return {}


func _vol(bodies: Array, id: String) -> float:
	var e := _entry(bodies, id)
	return BodyBuilder.mesh_volume(e["mesh"]) if not e.is_empty() else -1.0


func _watertight(mesh: ArrayMesh) -> bool:
	var s := SolidKernel.from_mesh(mesh, 1)
	return s != null and SolidKernel.is_valid(s)


func _face(point: Vector3, dir: Vector3) -> Dictionary:
	return _root.world.pick_face(point, dir)


func _ref(face: Dictionary) -> TopoRef:
	return TopoRef.make(String(face["body"]), int(face["face"]), face["normal"], face["point"])


func _push(f: Feature, label: String) -> String:
	f.id = _root.doc.next_feature_id()
	f.name = _root.doc.auto_name(label)
	_root.stack.push_no_merge(CmdAddFeature.new(f))
	return f.id


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A. shell a box: inside, top removed ---------------------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var box := _root.extrude(s1, Vector2(20, 15), 10.0)
	await _idle()
	var top := _face(Vector3(20, 15, 50), Vector3(0, 0, -1))
	var sh := ShellFeature.new()
	sh.body = box
	sh.thickness = 2.0
	sh.remove = [_ref(top)]
	var sh_id := _push(sh, "Shell")
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	# Cavity 36 x 26 x 8 (floor 2 thick, open top).
	var want_a := 12000.0 - 36.0 * 26.0 * 8.0
	if absf(_vol(bodies, box) - want_a) > 0.05:
		return _fail("A: open-top shell %f vs %f (%s)" % [_vol(bodies, box), want_a, sh.rebuild_error])
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("A: shell not watertight")
	# Closed shell (no faces removed): hollow box.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(sh_id, "remove", []))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_a2 := 12000.0 - 36.0 * 26.0 * 6.0
	if absf(_vol(bodies, box) - want_a2) > 0.05:
		return _fail("A: closed shell %f vs %f" % [_vol(bodies, box), want_a2])
	# Outside shell: walls grow outward around the (now cavity) box.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(sh_id, "direction", ShellFeature.DIR_OUTSIDE))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_a3 := 44.0 * 34.0 * 14.0 - 12000.0
	if absf(_vol(bodies, box) - want_a3) > 0.05:
		return _fail("A: outside shell %f vs %f" % [_vol(bodies, box), want_a3])
	# Too thick inside: error, body unchanged.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(sh_id, "direction", ShellFeature.DIR_INSIDE))
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(sh_id, "thickness", 8.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if sh.rebuild_error == "" or absf(_vol(bodies, box) - 12000.0) > 0.05:
		return _fail("A: over-thick shell should error and leave the body: %s / %f"
			% [sh.rebuild_error, _vol(bodies, box)])
	for _i in 5:
		_root.stack.undo()   # shell + its four edits
	await _idle()

	# --- B. combine ---------------------------------------------------------
	var s2 := _sketch_rect("XY", Vector2(30, 10), Vector2(60, 20))
	var bar := _root.extrude(s2, Vector2(45, 15), 10.0)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2:
		return _fail("B: expected 2 bodies before combining (extrude overlapping the box should be a NEW body), got %d" % bodies.size())
	var cb := CombineFeature.new()
	cb.target = box
	cb.tools = [bar]
	cb.operation = SolidFeature.OP_CUT
	var cb_id := _push(cb, "Combine")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# Bar overlaps the box in x 30..40 × y 10..20 × z 0..10 = 1000.
	if bodies.size() != 1 or absf(_vol(bodies, box) - 11000.0) > 0.05:
		return _fail("B: combine cut should consume the tool and remove 1000: %d bodies, %f"
			% [bodies.size(), _vol(bodies, box)])
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cb_id, "keep_tools", true))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2 or absf(_vol(bodies, bar) - 3000.0) > 0.05:
		return _fail("B: keep tools should leave the bar (%d bodies)" % bodies.size())
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cb_id, "operation", SolidFeature.OP_JOIN))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, box) - (12000.0 + 3000.0 - 1000.0)) > 0.05:
		return _fail("B: combine join %f" % _vol(bodies, box))
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cb_id, "operation", SolidFeature.OP_INTERSECT))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, box) - 1000.0) > 0.05:
		return _fail("B: combine intersect %f" % _vol(bodies, box))
	for _i in 4:
		_root.stack.undo()
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2:
		return _fail("B: undo should restore both bodies")

	# --- C. split by plane and by face ---------------------------------------
	var sp := SplitBodyFeature.new()
	sp.body = box
	sp.by = SplitBodyFeature.BY_PLANE
	sp.plane = "YZ"   # x = 0 ... the box spans 0..40: use an offset plane instead
	var pl := _root.create_offset_plane("YZ", 10.0)
	sp.plane = pl
	var sp_id := _push(sp, "Split")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 3:
		return _fail("C: split should add a body (3), got %d (%s)" % [bodies.size(), sp.rebuild_error])
	# Positive side of YZ(+x) offset 10 keeps x>10: 30x30x10 = 9000; other 3000.
	if absf(_vol(bodies, box) - 9000.0) > 0.05 or absf(_vol(bodies, sp_id) - 3000.0) > 0.05:
		return _fail("C: split halves %f / %f" % [_vol(bodies, box), _vol(bodies, sp_id)])
	if _entry(bodies, sp_id).is_empty() or not _watertight(_entry(bodies, sp_id)["mesh"]):
		return _fail("C: split half not watertight")
	_root.stack.undo()
	_root.stack.undo()
	await _idle()
	# By face: the bar's top face (z=10) splits... use the bar's side face x=30
	# to split the box: face normal -x at x=30 -> kept side x<30 (20..? no:
	# positive side of the normal (-x) is x<30: 30x30x10 = 9000, other 3000).
	bodies = await BodyBuilder.build(_root.doc, _root)
	var side := _face(Vector3(20, 15, 5), Vector3(1, 0, 0))   # ray +x from inside the box hits the bar's face at x=30? the box's own face at x=40 first
	# Pick the bar's -x face from outside the bar but inside the box region: ray from (25,15,5) toward +x hits the BOX's x=40 face first
	# (the bar starts at 30 but its face at x=30 faces -x, toward the ray origin: it IS hit first at t=5).
	if side.is_empty() or String(side["body"]) != bar:
		return _fail("C: expected to hit the bar's -x face, got %s" % str(side))
	var sp2 := SplitBodyFeature.new()
	sp2.body = box
	sp2.by = SplitBodyFeature.BY_FACE
	sp2.face_ref = _ref(side)
	var sp2_id := _push(sp2, "Split")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 3 or absf(_vol(bodies, box) - 9000.0) > 0.05 or absf(_vol(bodies, sp2_id) - 3000.0) > 0.05:
		return _fail("C: split by face %d bodies, %f / %f (%s)" % [bodies.size(), _vol(bodies, box), _vol(bodies, sp2_id), sp2.rebuild_error])
	_root.stack.undo()
	await _idle()

	# --- D. press / pull -----------------------------------------------------
	bodies = await BodyBuilder.build(_root.doc, _root)
	var top2 := _face(Vector3(10, 15, 50), Vector3(0, 0, -1))
	var po := FaceOffsetFeature.new()
	po.body = box
	po.ref = _ref(top2)
	po.distance = 5.0
	var po_id := _push(po, "Press Pull")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, box) - (12000.0 + 40.0 * 30.0 * 5.0)) > 0.05:
		return _fail("D: pull +5 should add 6000: %f (%s)" % [_vol(bodies, box), po.rebuild_error])
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(po_id, "distance", -4.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, box) - (12000.0 - 40.0 * 30.0 * 4.0)) > 0.05:
		return _fail("D: push -4 should remove 4800: %f" % _vol(bodies, box))
	# The face follows: the pushed face keeps being the top → editing the
	# extrude height keeps the push relative.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(box, "distance", 20.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, box) - (24000.0 - 4800.0)) > 0.05:
		return _fail("D: push should follow the face after an upstream edit: %f" % _vol(bodies, box))
	if po.rebuild_error != "":
		return _fail("D: " + po.rebuild_error)

	# --- E. serialization ---------------------------------------------------
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var kinds := {}
	for f in loaded.features:
		kinds[(f as Feature).kind()] = true
	if not kinds.has("face_offset"):
		return _fail("E: press/pull lost in round trip")
	var lb: Array = await BodyBuilder.build(loaded, _root)
	if absf(_vol(lb, box) - _vol(bodies, box)) > 1e-3:
		return _fail("E: loaded volume differs")
	return true
