extends SceneTree

# M2: instantiate the real main scene headless; enter/exit sketch mode,
# camera framing, world<->screen round trips, adaptive grid, undo of sketch
# creation, plane picking math.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m02_shell: " + msg)
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	if _root.mode != AppRoot.Mode.MODEL:
		return _fail("did not start in model mode")

	# Create a sketch on XZ: mode flips, feature exists, camera looks along
	# the plane normal (headless -> instant, no animation).
	var fid := _root.create_sketch("XZ")
	if _root.mode != AppRoot.Mode.SKETCH:
		return _fail("not in sketch mode after create")
	var feat := _root.doc.sketch_feature(fid)
	if feat == null or feat.plane != "XZ" or feat.name != "Sketch1":
		return _fail("feature wrong after create")
	var basis := SketchFeature.plane_basis("XZ")
	var cam_basis := Basis.from_euler(_root.rig.rotation)
	# Camera -Z must point along -normal (looking AT the plane).
	if (cam_basis * Vector3(0, 0, -1)).distance_to(-basis.z) > 0.001:
		return _fail("camera does not face the sketch plane")
	if (cam_basis * Vector3(0, 1, 0)).distance_to(basis.y) > 0.001:
		return _fail("camera up is not the plane's +v")
	if not _root.sketch_view.visible:
		return _fail("sketch view hidden in sketch mode")

	# World<->screen round trips at several zooms, and Y-up orientation.
	_root.sketch_view.size = Vector2(1000, 700)
	for z: float in [0.5, 4.0, 60.0]:
		_root.sketch_view.set_view(Vector2(10.0, -5.0), z)
		for p: Vector2 in [Vector2.ZERO, Vector2(25.4, -12.7), Vector2(-40, 33.3)]:
			var rt := _root.sketch_view.screen_to_world(
				_root.sketch_view.world_to_screen(p))
			if rt.distance_to(p) > 0.0001:
				return _fail("round trip failed at zoom %f for %s" % [z, str(p)])
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var above := _root.sketch_view.world_to_screen(Vector2(0, 10))
	var origin := _root.sketch_view.world_to_screen(Vector2.ZERO)
	if above.y >= origin.y:
		return _fail("sketch view is not Y-up")

	# Cursor-anchored zoom keeps the point under the cursor fixed.
	var anchor := Vector2(200, 150)
	var before := _root.sketch_view.screen_to_world(anchor)
	_root.sketch_view.zoom_at(2.0, anchor)
	if _root.sketch_view.screen_to_world(anchor).distance_to(before) > 0.0001:
		return _fail("zoom_at moved the anchor point")

	# Grid adapts: spacing in screen px stays within a sane band across zooms.
	for z: float in [0.1, 1.0, 10.0, 100.0]:
		_root.sketch_view.set_view(Vector2.ZERO, z)
		var px := _root.sketch_view.grid_step_mm() * z
		if px < 20.0 or px > 500.0:
			return _fail("grid spacing %f px unreasonable at zoom %f" % [px, z])

	# Finish: back to model mode, feature persists, sketch meshes rebuilt.
	_root.finish_sketch()
	if _root.mode != AppRoot.Mode.MODEL or _root.active_sketch_id != "":
		return _fail("finish did not return to model mode")
	if _root.doc.features.size() != 1:
		return _fail("feature lost on finish")

	# Undo removes the sketch feature entirely.
	_root.stack.undo()
	if _root.doc.features.size() != 0:
		return _fail("undo did not remove the sketch feature")
	_root.stack.redo()
	if _root.doc.features.size() != 1:
		return _fail("redo did not restore the sketch feature")

	# Plane pick math: a ray straight down hits XZ; one along -X hits YZ.
	if _root.world.pick_plane(Vector3(10, 200, -10), Vector3(0, -1, 0)) != "XZ":
		return _fail("down-ray should pick XZ")
	if _root.world.pick_plane(Vector3(200, 10, 10), Vector3(-1, 0, 0)) != "YZ":
		return _fail("x-ray should pick YZ")
	if _root.world.pick_plane(Vector3(0, 200, 0), Vector3(0, 1, 0)) != "":
		return _fail("ray pointing away should miss")
	# A ray through a corner region picks the NEAREST plane.
	if _root.world.pick_plane(Vector3(1000, 3, 5), Vector3(-1, 0, 0)) != "YZ":
		return _fail("near-axis ray should still pick YZ")

	# Second sketch auto-names Sketch2 and lands after Sketch1 (marker insert).
	var fid2 := _root.create_sketch("XY")
	if _root.doc.sketch_feature(fid2).name != "Sketch2":
		return _fail("auto-name wrong for second sketch")
	if _root.doc.features[1].id != fid2 or _root.doc.timeline_marker != 2:
		return _fail("timeline insert position wrong")
	_root.finish_sketch()

	print("M02_SHELL OK: modes, camera framing, view math, grid, undo, plane pick")
	return true
