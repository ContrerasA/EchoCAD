extends SceneTree

# M13: Z-up world axis, sticky orbit gestures, and the three orbit pivot
# modes (Fusion body-center default, Blender-style under-cursor, view-center).

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


## Let Godot flush node transforms so unproject_position() sees the new pose.
func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m13_zup_orbit: " + msg)
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var rig: OrbitCamera = _root.rig

	# --- Z-up plane bases -------------------------------------------------
	# XY is the ground plane with the normal pointing up; the other two
	# stand on it with +v up. Every basis stays right-handed.
	var expect := {
		"XY": [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
		"XZ": [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)],
		"YZ": [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
	}
	for pname: String in expect:
		var b := SketchFeature.plane_basis(pname)
		var want: Array = expect[pname]
		if b.x.distance_to(want[0]) > 1e-6 or b.y.distance_to(want[1]) > 1e-6 \
				or b.z.distance_to(want[2]) > 1e-6:
			return _fail("plane %s basis is %s, want %s" % [pname, str(b), str(want)])
		if b.x.cross(b.y).distance_to(b.z) > 1e-6:
			return _fail("plane %s basis is not right-handed" % pname)
	# The two vertical planes must carry world +Z as their sketch "up".
	for pname: String in ["XZ", "YZ"]:
		if SketchFeature.plane_basis(pname).y.distance_to(Vector3(0, 0, 1)) > 1e-6:
			return _fail("plane %s +v is not world up" % pname)

	# --- camera faces each plane, Z-up ------------------------------------
	for pname: String in expect:
		var b := SketchFeature.plane_basis(pname)
		rig.frame_view(b.z, b.y, Vector3.ZERO, 500.0, false)
		var cb := Basis.from_euler(rig.rotation)
		if (cb * Vector3(0, 0, -1)).distance_to(-b.z) > 1e-4:
			return _fail("camera does not face plane %s" % pname)
		if (cb * Vector3(0, 1, 0)).distance_to(b.y) > 1e-4:
			return _fail("camera up is not plane %s's +v" % pname)

	# A free orbit must keep world +Z pointing up on screen (no roll): the
	# camera's right vector stays parallel to the ground plane.
	rig.frame_view(Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3.ZERO, 500.0, false)
	rig.pivot_mode = OrbitCamera.PivotMode.VIEW_CENTER
	rig.begin_orbit()
	for i in 12:
		rig.orbit(37.0, 11.0)
		var right := Basis.from_euler(rig.rotation) * Vector3(1, 0, 0)
		if absf(right.z) > 1e-4:
			return _fail("orbit rolled the camera: right.z = %f" % right.z)
	rig.end_orbit()

	# --- sticky orbit gesture ---------------------------------------------
	# Shift decides orbit at MMB-press; releasing Shift mid-drag must not
	# switch the gesture to pan.
	rig.frame_view(Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3.ZERO, 500.0, false)
	_press_mmb(Vector2(640, 400), true)
	if not rig.is_orbiting():
		return _fail("shift+MMB did not start an orbit")
	var yaw_before := rig.yaw
	var target_before := rig.target
	_drag(Vector2(660, 400), false)              # shift RELEASED mid-drag
	if not rig.is_orbiting():
		return _fail("orbit stopped when shift was released")
	if absf(rig.yaw - yaw_before) < 1e-6:
		return _fail("orbit did not rotate after shift release")
	if rig.target.distance_to(target_before) > 1e-6:
		return _fail("orbit panned the view center (VIEW_CENTER pivot)")
	_release_mmb()
	if rig.is_orbiting():
		return _fail("orbit did not end on MMB release")
	# Plain MMB (no shift) is a pan, not an orbit.
	_press_mmb(Vector2(640, 400), false)
	if rig.is_orbiting():
		return _fail("plain MMB started an orbit")
	_release_mmb()

	# --- empty document ----------------------------------------------------
	# The state on open: no body at all. BODY_CENTER must fall back to the
	# world origin (where the axes and origin planes are), NOT the view
	# centre — and after panning the origin off-centre, orbiting must leave
	# it exactly where it sits rather than spinning it about the window.
	if _root.world.model_bounds().size.length_squared() > 1e-12:
		return _fail("document should still be empty here")
	rig.pivot_mode = OrbitCamera.PivotMode.BODY_CENTER
	if rig.resolve_pivot(Vector2(500, 350)) != Vector3.ZERO:
		return _fail("empty-document BODY_CENTER pivot should be the origin, got %s"
			% str(rig.resolve_pivot(Vector2(500, 350))))
	rig.frame_view(Vector3(0.5, -0.7, 0.5), Vector3(0, 0, 1), Vector3.ZERO,
		900.0, false)
	for i in 12:                                  # pan the origin off-centre
		rig.pan(22.0, 0.0)
	await _idle()
	var org_before := rig.camera.unproject_position(Vector3.ZERO)
	var vp_mid := rig.camera.get_viewport().get_visible_rect().size * 0.5
	if absf(org_before.x - vp_mid.x) < 80.0:
		return _fail("pan did not move the origin off-centre (%s vs mid %s)"
			% [str(org_before), str(vp_mid)])
	rig.begin_orbit(org_before)
	if rig._orbit_pivot != Vector3.ZERO:
		return _fail("empty-document orbit pivot is %s, want the origin"
			% str(rig._orbit_pivot))
	await _idle()
	for i in 14:
		rig.orbit(18.0, 5.0)
	await _idle()
	var org_after := rig.camera.unproject_position(Vector3.ZERO)
	rig.end_orbit()
	if org_before.distance_to(org_after) > 1.0:
		return _fail("origin moved %.1f px during empty-document orbit (%s -> %s) — it orbited the window centre"
			% [org_before.distance_to(org_after), str(org_before), str(org_after)])

	# --- pivot modes -------------------------------------------------------
	# Build a body away from the origin so body-center is distinguishable
	# from view-center.
	var sid := _root.create_sketch("XY")
	var sk: Sketch = _root.doc.sketch_feature(sid).sketch
	_rect(sk, Vector2(100, 100), Vector2(200, 160))
	_root.finish_sketch()
	_root.extrude(sid, Vector2(150, 130), 40.0)
	_root.world.rebuild_sketches(_root.doc)

	var bounds := _root.world.model_bounds()
	if bounds.size.length_squared() <= 1e-12:
		return _fail("model_bounds empty after extrude")
	var center := bounds.get_center()
	if center.length() < 1.0:
		return _fail("body center should be away from the origin, got %s" % str(center))
	# The extrude runs along +Z (the XY plane normal), so the body sits above
	# the ground plane — proof the Z-up normal reached the feature math.
	if center.z <= 0.0:
		return _fail("extrude on XY did not rise along +Z (center.z=%f)" % center.z)

	# BODY_CENTER: pivot is the body's center regardless of where the view is.
	rig.pivot_mode = OrbitCamera.PivotMode.BODY_CENTER
	rig.target = Vector3(900, -400, 250)
	var p := rig.resolve_pivot(Vector2(640, 400))
	if p.distance_to(center) > 1e-3:
		return _fail("BODY_CENTER pivot %s != body center %s" % [str(p), str(center)])

	# Orbiting about the body keeps it fixed on screen even when the view is
	# centred somewhere else entirely — the regression that made all three
	# modes look identical (each spun about the window centre instead).
	# unproject_position reads the node's global transform, which Godot only
	# refreshes on the next frame, so settle a frame before each reading.
	rig.frame_view(Vector3(0.5, -0.7, 0.5), Vector3(0, 0, 1), Vector3.ZERO,
		900.0, false)
	await _idle()
	rig.begin_orbit(rig.camera.unproject_position(center))
	await _idle()
	var scr_before := rig.camera.unproject_position(center)
	for i in 8:
		rig.orbit(20.0, 6.0)
	await _idle()
	var scr_after := rig.camera.unproject_position(center)
	rig.end_orbit()
	# The body must hold its screen position WITHOUT being yanked to the
	# middle of the window — orbiting moves the camera around it in place.
	var mid := rig.camera.get_viewport().get_visible_rect().size * 0.5
	if scr_after.distance_to(mid) < 40.0:
		return _fail("body was pulled to the window centre (%s ~ %s)"
			% [str(scr_after), str(mid)])
	if scr_before.distance_to(scr_after) > 1.0:
		return _fail("body moved on screen during body-center orbit: %s -> %s (%.1f px)"
			% [str(scr_before), str(scr_after), scr_before.distance_to(scr_after)])

	# View-center orbit must NOT hold the off-centre body still — otherwise
	# the modes are indistinguishable and the pivot setting does nothing.
	rig.pivot_mode = OrbitCamera.PivotMode.VIEW_CENTER
	rig.frame_view(Vector3(0.5, -0.7, 0.5), Vector3(0, 0, 1), Vector3.ZERO,
		900.0, false)
	await _idle()
	rig.begin_orbit()
	await _idle()
	var vc_before := rig.camera.unproject_position(center)
	for i in 8:
		rig.orbit(20.0, 6.0)
	await _idle()
	var vc_after := rig.camera.unproject_position(center)
	rig.end_orbit()
	if vc_before.distance_to(vc_after) < 20.0:
		return _fail("view-center orbit held the body still (%.1f px) — pivot modes are not distinct"
			% vc_before.distance_to(vc_after))

	# VIEW_CENTER: pivot is the current target, untouched by the body.
	rig.pivot_mode = OrbitCamera.PivotMode.VIEW_CENTER
	rig.target = Vector3(10, 20, 30)
	if rig.resolve_pivot().distance_to(Vector3(10, 20, 30)) > 1e-6:
		return _fail("VIEW_CENTER pivot is not the view target")

	# ORBIT_POINT: pivot is the surface point under the cursor. Aim the
	# camera at the body and pick through the viewport center.
	rig.pivot_mode = OrbitCamera.PivotMode.ORBIT_POINT
	rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0), center, 700.0, false)
	_root.get_viewport().size = Vector2i(1280, 800)
	var vp_center := Vector2(rig.camera.get_viewport().get_visible_rect().size) * 0.5
	var ray := rig.pixel_ray(vp_center)
	var hit := _root.world.pick_point(ray[0], ray[1])
	if not bool(hit["ok"]):
		return _fail("pick_point missed the body under the cursor")
	var hp: Vector3 = hit["pos"]
	# Looking straight down at the solid, the nearest hit must be its top
	# face — i.e. the solid's own triangles, not the ground plane behind it.
	if absf(hp.z - bounds.end.z) > 1e-3:
		return _fail("top-down pick should land on the body's top face (z=%f), got %s"
			% [bounds.end.z, str(hp)])
	var op := rig.resolve_pivot(vp_center)
	if op.distance_to(hp) > 1e-3:
		return _fail("ORBIT_POINT pivot %s != picked point %s" % [str(op), str(hp)])
	# A miss falls back to the world origin (Blender's behaviour when its ray
	# hits nothing), not the view centre — same reasoning as the empty case.
	rig.target = Vector3(5, 6, 7)
	var far_corner := Vector2(2, 2)
	var miss_ray := rig.pixel_ray(far_corner)
	if not bool(_root.world.pick_point(miss_ray[0], miss_ray[1])["ok"]):
		if rig.resolve_pivot(far_corner) != Vector3.ZERO:
			return _fail("ORBIT_POINT miss should fall back to the origin, got %s"
				% str(rig.resolve_pivot(far_corner)))

	print("M13 OK: Z-up axes, sticky orbit gesture, 3 pivot modes")
	return true


## --- helpers ----------------------------------------------------------------

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


func _press_mmb(pos: Vector2, shift: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.pressed = true
	e.position = pos
	e.shift_pressed = shift
	_root._on_viewport_input(e)


func _release_mmb() -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.pressed = false
	_root._on_viewport_input(e)


func _drag(to: Vector2, shift: bool) -> void:
	var e := InputEventMouseMotion.new()
	e.position = to
	e.relative = Vector2(20, 0)
	e.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	e.shift_pressed = shift
	_root._on_viewport_input(e)
