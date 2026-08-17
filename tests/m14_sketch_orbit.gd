extends SceneTree

# M14: orbitable sketch view. Shift+MMB inside a sketch leaves the locked 2D
# view for a free 3D orbit; sketching CONTINUES off-axis with clicks
# ray-cast onto the original plane (Fusion's workflow — QA revision); the
# plane's view-cube face or Esc flies back to the locked view at the exact
# pan/zoom the user left.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m14_sketch_orbit: " + msg)
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var rig: OrbitCamera = _root.rig
	var sv: SketchView = _root.sketch_view

	# --- enter a sketch on XZ; the locked view is orthographic on the plane --
	var sid := _root.create_sketch("XZ")
	var sk: Sketch = _root.doc.sketch_feature(sid).sketch
	_rect(sk, Vector2(10, 10), Vector2(60, 40))
	await _idle()
	if _root.mode != AppRoot.Mode.SKETCH or _root.sketch_orbit:
		return _fail("should start locked in sketch mode")
	sv.set_view(Vector2(30, 10), 6.0)
	await _idle()
	if not rig.is_orthographic():
		return _fail("locked sketch view is not orthographic")
	var basis := SketchFeature.plane_basis("XZ")
	var fwd := Basis.from_euler(rig.rotation) * Vector3(0, 0, -1)
	if fwd.distance_to(-basis.z) > 1e-4:
		return _fail("locked view does not face the sketch plane")

	# --- Shift+MMB leaves the locked view -----------------------------------
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	press.shift_pressed = true
	press.position = Vector2(640, 400)
	sv._gui_input(press)
	if not _root.sketch_orbit:
		return _fail("shift+MMB did not enter the off-axis sub-state")
	if sv.visible:
		return _fail("2D canvas still visible off-axis")
	if rig.is_orthographic():
		return _fail("off-axis view should be perspective")
	if not rig.is_orbiting():
		return _fail("orbit gesture did not start")
	if not sv.is_projection_3d():
		return _fail("mapping did not delegate to the 3D camera")

	# Sketching continues off-axis: shortcuts work, clicks land on the plane.
	var lkey := InputEventKey.new()
	lkey.keycode = KEY_L
	lkey.pressed = true
	if not _root.handle_app_key(lkey):
		return _fail("tool shortcut dead while off-axis")
	if _root.tools.active_id() != "line":
		return _fail("L did not activate the line tool off-axis")
	await _idle()
	# The delegated mapping round-trips through the camera.
	var probe := Vector2(22, 14)
	var rt := sv.screen_to_world(sv.world_to_screen(probe))
	if rt.distance_to(probe) > 0.01:
		return _fail("off-axis mapping round-trip drifted: %s -> %s"
			% [str(probe), str(rt)])
	# Draw a line with clicks routed through the viewport (ray -> plane).
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	var n_before := sk.size()
	for w: Vector2 in [Vector2(70, 15), Vector2(95, 32)]:
		var lc := InputEventMouseButton.new()
		lc.button_index = MOUSE_BUTTON_LEFT
		lc.pressed = true
		lc.position = sv.world_to_screen(w)
		_root._on_viewport_input(lc)
		var lu := InputEventMouseButton.new()
		lu.button_index = MOUSE_BUTTON_LEFT
		lu.pressed = false
		lu.position = lc.position
		_root._on_viewport_input(lu)
		await _idle()
	var esc_chain := InputEventKey.new()
	esc_chain.keycode = KEY_ESCAPE
	esc_chain.pressed = true
	_root.handle_app_key(esc_chain)   # end the chain (drops back to Select)
	if sk.size() != n_before + 3:
		return _fail("off-axis clicks did not draw a line (+%d entities)"
			% (sk.size() - n_before))
	var drawn_ok := false
	for e in sk.entities():
		if e.kind() == "point" and (e as SketchPoint).pos.distance_to(Vector2(70, 15)) < 0.1:
			drawn_ok = true
	if not drawn_ok:
		return _fail("off-axis click did not land on the plane at (70,15)")
	if not _root.sketch_orbit:
		return _fail("drawing off-axis must stay off-axis")

	# --- the orbit actually moves the camera off the plane -------------------
	# The overlay chrome (vertex markers) projects through the camera, so it
	# must repaint on every orbit step — not only when the orbit ends.
	var redraws := [0]
	_root.overlay.draw.connect(func() -> void: redraws[0] += 1)
	var rot_before := rig.rotation
	for i in 10:
		var mm := InputEventMouseMotion.new()
		mm.position = Vector2(640 + i * 15, 400 + i * 6)
		mm.relative = Vector2(15, 6)
		mm.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		_root._on_viewport_input(mm)
		await process_frame
	if rig.rotation.is_equal_approx(rot_before):
		return _fail("orbit did not rotate the camera")
	if redraws[0] < 5:
		return _fail("overlay repainted only %d times over 10 orbit steps — "
			% redraws[0] + "vertices trail the lines mid-orbit")
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_MIDDLE
	rel.pressed = false
	_root._on_viewport_input(rel)
	if rig.is_orbiting():
		return _fail("MMB release did not end the orbit gesture")
	if not _root.sketch_orbit:
		return _fail("releasing MMB must stay off-axis until the user returns")

	# --- undo/redo still work off-axis --------------------------------------
	var pid := sk.entities()[0].id
	var before: Vector2 = sk.point(pid).pos
	_root.stack.push_no_merge(CmdMovePoints.new(sid, {pid: before + Vector2(5, 0)}))
	_root.stack.undo()
	if sk.point(pid).pos.distance_to(before) > 1e-9:
		return _fail("undo broken while off-axis")
	_root.stack.redo()
	if sk.point(pid).pos.distance_to(before + Vector2(5, 0)) > 1e-9:
		return _fail("redo broken while off-axis")
	if not _root.sketch_orbit or _root.mode != AppRoot.Mode.SKETCH:
		return _fail("undo/redo knocked the app out of the off-axis sub-state")

	# --- a DIFFERENT cube face reorients but stays off-axis ------------------
	_root._on_cube_face(Vector3(0, 0, 1), Vector3(0, 1, 0))
	if not _root.sketch_orbit:
		return _fail("a non-plane cube face must not return to the sketch")

	# --- the plane's own face flies home at the exact pan/zoom ---------------
	_root._on_cube_face(basis.z, basis.y)
	await _idle()
	if _root.sketch_orbit:
		return _fail("plane cube face did not return to the locked view")
	if not sv.visible:
		return _fail("2D canvas not restored")
	if sv.pan().distance_to(Vector2(30, 10)) > 1e-6 or absf(sv.zoom() - 6.0) > 1e-6:
		return _fail("pan/zoom not restored exactly (got %s @ %f)"
			% [str(sv.pan()), sv.zoom()])
	if not rig.is_orthographic():
		return _fail("restored view is not orthographic")
	var fwd2 := Basis.from_euler(rig.rotation) * Vector3(0, 0, -1)
	if fwd2.distance_to(-basis.z) > 1e-4:
		return _fail("restored view does not face the sketch plane")

	# --- Esc is the other way home -------------------------------------------
	sv._gui_input(press)
	if not _root.sketch_orbit:
		return _fail("second shift+MMB did not re-enter off-axis")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	if not _root.handle_app_key(esc):
		return _fail("Esc not handled while off-axis")
	await _idle()
	if _root.sketch_orbit or not sv.visible:
		return _fail("Esc did not return to the locked view")

	# --- Finish Sketch from off-axis leaves cleanly --------------------------
	sv._gui_input(press)
	_root.finish_sketch()
	if _root.mode != AppRoot.Mode.MODEL or _root.sketch_orbit:
		return _fail("finish_sketch from off-axis left stale state")

	print("M14 OK: in-sketch orbit sub-state, cube-face/Esc return, exact view restore")
	return true


func _rect(sk: Sketch, a: Vector2, b: Vector2) -> void:
	var ids: Array[String] = []
	for p: Vector2 in [a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)]:
		var pt := SketchPoint.make(p)
		pt.id = sk.next_id()
		sk.add(pt)
		ids.append(pt.id)
	for i in 4:
		var ln := SketchLine.make(ids[i], ids[(i + 1) % 4])
		ln.id = sk.next_id()
		sk.add(ln)
