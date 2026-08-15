extends SceneTree

# M12: profile detection (loops, circles, open chains, coincident closure)
# and extrusion (volume, replay after sketch edit, timeline integration).

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m12_extrude: " + msg)
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


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- profiles: rectangle -> one ccw loop of the right area.
	var f1 := _root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	var profs := ProfileFinder.profiles(sk)
	if profs.size() != 1:
		return _fail("rect profiles wrong: %d" % profs.size())
	if absf(float(profs[0]["area"]) - 1200.0) > 1.0:
		return _fail("rect area wrong: %f" % float(profs[0]["area"]))

	# --- open chain -> no profile; closing it via coincident -> one.
	_root.tools.set_active("line")
	_click(Vector2(100, 0))
	_click(Vector2(140, 0))
	_click(Vector2(120, 30))
	_root.tools.handle_cancel()
	profs = ProfileFinder.profiles(sk)
	if profs.size() != 1:
		return _fail("open chain created a profile")
	# Close the triangle: draw the last edge snapping both ends.
	_click(Vector2(120, 30))
	_click(Vector2(100, 0))
	_root.tools.handle_cancel()
	profs = ProfileFinder.profiles(sk)
	if profs.size() != 2:
		return _fail("closed triangle not found: %d" % profs.size())

	# --- circle is its own profile.
	_root.tools.set_active("circle")
	_click(Vector2(-60, -60))
	_click(Vector2(-45, -60))
	profs = ProfileFinder.profiles(sk)
	if profs.size() != 3:
		return _fail("circle profile missing")
	_root.finish_sketch()

	# --- extrude the rectangle: volume = 1200 * 25.4.
	var eid := _root.extrude(f1, Vector2(20, 15), 25.4)
	if eid == "":
		return _fail("extrude refused a valid profile")
	var ef := _root.doc.feature_by_id(eid) as ExtrudeFeature
	if ef.name != "Extrude1":
		return _fail("extrude auto-name wrong: %s" % ef.name)
	var mesh := ef.build_mesh(_root.doc)
	var vol := ExtrudeFeature.mesh_volume(mesh)
	if absf(vol - 1200.0 * 25.4) > 30.0:
		return _fail("extrude volume wrong: %f vs %f" % [vol, 1200.0 * 25.4])
	# World shows a solid.
	var solids := 0
	for c in _root.world._sketch_root.get_children():
		if not c.is_queued_for_deletion() and (c as MeshInstance3D).mesh is ArrayMesh:
			solids += 1
	if solids < 1:
		return _fail("no solid in the world")

	# --- extrude a point OUTSIDE any profile refuses.
	if _root.extrude(f1, Vector2(400, 400), 10.0) != "":
		return _fail("extrude accepted empty space")

	# --- replay: edit the sketch, drive the rect width; the solid follows.
	_root.edit_sketch(f1)
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line" and sk.index_of(e.id) < 8:
			lines.append(e)
	var bottom := lines[0] as SketchLine
	var ops: Array[String] = [bottom.p0, bottom.p1]
	_root.add_constraint(SketchConstraint.make(
		SketchConstraint.Type.DISTANCE, ops, 80.0))
	_root.finish_sketch()
	var vol2 := ExtrudeFeature.mesh_volume(ef.build_mesh(_root.doc))
	if absf(vol2 - 80.0 * 30.0 * 25.4) > 100.0:
		return _fail("extrude did not replay after edit: %f" % vol2)

	# --- rollback before the extrude hides the solid; undo of the extrude
	# feature works.
	_root.stack.push_no_merge(CmdSetMarker.new(_root.doc.timeline_marker, 1))
	var still := 0
	for c in _root.world._sketch_root.get_children():
		if not c.is_queued_for_deletion() and (c as MeshInstance3D).mesh is ArrayMesh:
			still += 1
	if still != 0:
		return _fail("rolled-back solid still visible")
	_root.stack.undo()

	# --- serialization round-trip keeps the extrude live.
	var text := Serializer.to_json(_root.doc)
	var loaded := Serializer.from_json(text)
	var lf := loaded.feature_by_id(eid) as ExtrudeFeature
	if lf == null or absf(lf.distance - 25.4) > 1e-6:
		return _fail("extrude did not serialize")
	var vol3 := ExtrudeFeature.mesh_volume(lf.build_mesh(loaded))
	if absf(vol3 - vol2) > 1.0:
		return _fail("loaded extrude volume mismatch")

	print("M12_EXTRUDE OK: profiles (rect/triangle/circle/open), volume, "
		+ "replay-on-edit, rollback, serialization")
	return true
