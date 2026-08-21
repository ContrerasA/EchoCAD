extends SceneTree

# QA fix round for volume-3 §M38.2 (2026-08-21) — the camera notes:
#  A. A fresh document frames a 200 mm working volume through a 35 deg lens,
#     not the 1.2 m span the old 800 mm / 75 deg default worked out to.
#  B. The wheel zooms TOWARDS THE CURSOR: the world point under the pointer
#     keeps its pixel, so zooming in converges on the part instead of walking
#     it out of frame.
#  C. Entering a sketch frames what the sketch is ABOUT — its own geometry, or
#     the face it sits on — instead of wherever the model camera was pointing.
#  D. Finish Sketch: still square-on to the plane, the pre-sketch view comes
#     back; having ORBITED off it, the user's own view stands. A document's
#     FIRST geometry frames itself, at the orientation the user left.
#  E. A dimension that moves the sketch off screen (or shrinks it to a speck)
#     re-frames the canvas; one that leaves it legible does not.
#  F. Construction geometry (the origin axes the dimension tool mints) is not
#     what a fit frames.
#  G. Picking a sketch plane takes the BODY FACE under the cursor, not the
#     origin-plane quad hanging in front of it — which is what the 3/4 view
#     made the common case.

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
	push_error("m38_camera_qa: " + msg)
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


## Four lines into a bare sketch (no app, no solver) — a fixture for the
## bounds rule.
func _rect_into(sk: Sketch, a: Vector2, b: Vector2) -> void:
	var corners := [a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)]
	var ids: Array[String] = []
	for c: Vector2 in corners:
		var p := SketchPoint.make(c)
		p.id = sk.next_id()
		sk.add(p)
		ids.append(p.id)
	for i in 4:
		var l := SketchLine.make(ids[i], ids[(i + 1) % 4])
		l.id = sk.next_id()
		sk.add(l)


## Draw a rectangle with the rect tool, then leave the sketch.
func _draw_rect(a: Vector2, b: Vector2) -> void:
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	_root.tools.handle_cancel()


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	var rig: OrbitCamera = _root.rig

	# --- A: the empty-document framing ---------------------------------------
	if absf(rig.view_height_mm() - OrbitCamera.HOME_VIEW_MM) > 1.0:
		return _fail("A: empty document shows %.1f mm, want %.1f"
			% [rig.view_height_mm(), OrbitCamera.HOME_VIEW_MM])

	# The model-mode angle the first sketch is entered from: Finish Sketch must
	# hand it back, framing only where the camera looks from there.
	var yaw_before := rig.yaw
	var pitch_before := rig.pitch

	# --- F: construction geometry is not what a fit frames -------------------
	# On a bare Sketch, so the assertion is about the bounds rule alone.
	var scratch := Sketch.new()
	_rect_into(scratch, Vector2(0, 0), Vector2(40, 30))
	var far := SketchPoint.make(Vector2(0, 400))
	far.id = scratch.next_id()
	scratch.add(far)
	var axis := SketchLine.make(scratch.origin_id(), far.id)
	axis.id = scratch.next_id()
	axis.construction = true
	scratch.add(axis)
	var b := SketchGeometry.bounds(scratch)
	if not bool(b["ok"]) or absf((b["rect"] as Rect2).size.y - 30.0) > 0.01:
		return _fail("F: bounds followed the construction axis: %s"
			% str(b.get("rect")))
	var ball := SketchGeometry.bounds(scratch, [], true)
	if absf((ball["rect"] as Rect2).size.y - 400.0) > 0.01:
		return _fail("F: include_construction did not reach the axis")

	var sid := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_draw_rect(Vector2(0, 0), Vector2(40, 30))

	# --- E: a dimension that loses the sketch re-frames the canvas -----------
	# At 60 px/mm the 1000x700 canvas shows 16.7 x 11.7 mm — the 40x30 rect
	# is nearly three times too big to read.
	_root.sketch_view.set_view(Vector2(20, 15), 60.0)
	_root.reframe_sketch_if_lost()
	var zoom_fit := _root.sketch_view.zoom()
	if zoom_fit >= 60.0 or _root.sketch_view.pan().distance_to(Vector2(20, 15)) > 0.01:
		return _fail("E: an over-sized sketch did not re-frame (zoom %f @ %s)"
			% [zoom_fit, str(_root.sketch_view.pan())])
	_root.sketch_view.set_view(Vector2(20, 15), zoom_fit)
	_root.reframe_sketch_if_lost()
	if absf(_root.sketch_view.zoom() - zoom_fit) > 1e-6:
		return _fail("E: a sketch that already reads was re-framed anyway")

	# --- D: the first geometry frames itself, at the model orientation -------
	_root.finish_sketch()
	await _idle()
	if absf(rig.yaw - yaw_before) > 1e-4 or absf(rig.pitch - pitch_before) > 1e-4:
		return _fail("D: the first fit kept the sketch's square-on angle")
	# 40x30 sketch => bounding sphere 50 * 1.15 = 57.5 mm.
	if absf(rig.view_height_mm() - 57.5) > 2.0:
		return _fail("D: first geometry not framed (%.1f mm)" % rig.view_height_mm())
	var body := _root.extrude(sid, Vector2(20, 15), 10.0)
	await _idle()
	await _idle()
	if body == "":
		return _fail("D: extrude failed")

	# --- B: the wheel zooms towards the cursor -------------------------------
	var probe := Vector3(40, 30, 10)               # the plate's far top corner
	var px_before := rig.camera.unproject_position(probe)
	var vh_before := rig.view_height_mm()
	rig.zoom_at(1.0 / 1.1, px_before)
	rig.zoom_at(1.0 / 1.1, px_before)
	if rig.view_height_mm() >= vh_before:
		return _fail("B: zoom_at did not zoom in")
	var px_after := rig.camera.unproject_position(probe)
	if px_after.distance_to(px_before) > 1.0:
		return _fail("B: the point under the cursor moved %.2f px"
			% px_after.distance_to(px_before))
	_root.fit_view()

	# --- C: a sketch on a face opens looking at that face --------------------
	var model_view := rig.capture_view()
	var face := _root.world.pick_face(Vector3(20, 15, 400), Vector3(0, 0, -1))
	if face.is_empty():
		return _fail("C: no top face to sketch on")
	var fsid := _root.create_sketch_on_face(face["point"], face["normal"],
		String(face["body"]), int(face["face"]))
	await _idle()
	if _root.mode != AppRoot.Mode.SKETCH:
		return _fail("C: sketch on face did not enter sketch mode")
	# The face spans 0..40 x 0..30 and the plane's origin sits over the world
	# origin, so its centre is (20, 15) in sketch coordinates.
	if _root.sketch_view.pan().distance_to(Vector2(20, 15)) > 0.5:
		return _fail("C: canvas opened at %s, not on the face's centre"
			% str(_root.sketch_view.pan()))
	var vr := _root.sketch_view.view_rect()
	if not vr.encloses(Rect2(0, 0, 40, 30)):
		return _fail("C: the face does not fit the opening view (%s)" % str(vr))
	if vr.size.y > 30.0 * 8.0:
		return _fail("C: the face is a speck in the opening view (%s)" % str(vr))

	# --- D: square-on exit restores, orbited exit stays ----------------------
	_root.finish_sketch()
	await _idle()
	if rig.target.distance_to(model_view["target"] as Vector3) > 0.01 			or absf(rig.yaw - float(model_view["yaw"])) > 1e-4:
		return _fail("D: a square-on finish did not restore the model view "
			+ "(%s -> %s)" % [str(model_view["target"]), str(rig.target)])
	_root.edit_sketch(fsid)
	await _idle()
	_root._on_sketch_orbit_request(Vector2(500, 350))
	rig.orbit(30.0, 20.0)
	var orbited := rig.capture_view()
	_root.finish_sketch()
	await _idle()
	if rig.target.distance_to(orbited["target"] as Vector3) > 0.01 \
			or absf(rig.yaw - float(orbited["yaw"])) > 1e-4:
		return _fail("D: finishing after an orbit threw the user's view away")

	# --- G: a body face beats the origin quad in front of it ----------------
	# This ray reaches the plate's top face at (20, 15, 10) THROUGH the XZ
	# quad (it crosses y = 0 at x 22, z 16, well inside the 120 mm quad).
	var o := Vector3(25, -20, 25)
	var d := (Vector3(20, 15, 10) - o).normalized()
	if _root.world.pick_plane(o, d) != "XZ":
		return _fail("G: the probe ray does not cross the XZ quad — bad fixture")
	var pick := _root._plane_or_face_under([o, d])
	if String(pick["plane"]) != "" or (pick["face"] as Dictionary).is_empty():
		return _fail("G: the origin quad won the pick over the body face")
	if String((pick["face"] as Dictionary)["body"]) != body:
		return _fail("G: picked some other body")

	print("M38_CAMERA_QA OK: home framing, zoom-to-cursor, face framing, "
		+ "sketch-exit view rules, dimension re-frame, face-over-quad picks")
	return true
