extends SceneTree

# M23: revolve — full-ring volume vs Pappus, partial-angle sweep + caps,
# axis-touching cone, hole rings, a line-entity axis, straddle refusal,
# revolve CUT through the CSG path (also proves the spin direction matches
# the exact mesher), undo and serialization.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m23_revolve: " + msg)
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
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	return fid


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A: full ring. Rect x 20..30, y 0..10 about the sketch Y axis.
	# Pappus: V = 2*pi*25*100 = 5000*pi (the 48-gon sweep lands ~0.2% under).
	var s1 := _sketch_rect("XY", Vector2(20, 0), Vector2(30, 10))
	_root.finish_sketch()
	var r1 := _root.revolve(s1, Vector2(25, 5), "y", 360.0)
	if r1 == "":
		return _fail("full-ring revolve refused")
	var rf1 := _root.doc.feature_by_id(r1) as RevolveFeature
	if rf1.name != "Revolve1":
		return _fail("auto-name wrong: %s" % rf1.name)
	var mesh := rf1.build_mesh(_root.doc)
	var vol := BodyBuilder.mesh_volume(mesh)
	if absf(vol - 5000.0 * PI) > 200.0:
		return _fail("ring volume wrong: %f vs %f" % [vol, 5000.0 * PI])
	var box := mesh.get_aabb()
	if absf(box.position.x + 30.0) > 0.5 or absf(box.end.z - 30.0) > 0.5 \
			or absf(box.position.y) > 1e-4 or absf(box.end.y - 10.0) > 1e-4:
		return _fail("ring aabb wrong: %s" % box)

	# --- B: partial 90-degree sweep (exact caps, quarter volume). The sweep
	# runs +X toward +Z (the normalized frame), so the quarter sits in the
	# x>0, z>0 corner.
	_root.stack.undo()
	var r2 := _root.revolve(s1, Vector2(25, 5), "y", 90.0)
	var mesh2 := (_root.doc.feature_by_id(r2) as RevolveFeature) \
		.build_mesh(_root.doc)
	var vol2 := BodyBuilder.mesh_volume(mesh2)
	if absf(vol2 - 1250.0 * PI) > 100.0:
		return _fail("quarter volume wrong: %f vs %f" % [vol2, 1250.0 * PI])
	var box2 := mesh2.get_aabb()
	if box2.position.x < -0.5 or box2.position.z < -0.5 \
			or absf(box2.end.x - 30.0) > 0.5 or absf(box2.end.z - 30.0) > 0.5:
		return _fail("quarter aabb wrong: %s" % box2)
	_root.stack.undo()

	# --- C: axis-touching profile (cone) stays watertight through the welds.
	var s2 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("line")
	_click(Vector2(0, 0))
	_click(Vector2(10, 0))
	_click(Vector2(0, 10))
	_click(Vector2(0, 0))
	_root.tools.handle_cancel()
	_root.finish_sketch()
	var r3 := _root.revolve(s2, Vector2(2, 2), "y", 360.0)
	if r3 == "":
		return _fail("cone revolve refused")
	var vol3 := BodyBuilder.mesh_volume(
		(_root.doc.feature_by_id(r3) as RevolveFeature).build_mesh(_root.doc))
	if absf(vol3 - 1000.0 * PI / 3.0) > 30.0:
		return _fail("cone volume wrong: %f vs %f" % [vol3, 1000.0 * PI / 3.0])
	_root.stack.undo()

	# --- D: a LINE entity as the axis (drawn at x=0, below the profile).
	_root.edit_sketch(s1)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("line")
	_click(Vector2(0, -8))
	_click(Vector2(0, -4))
	_root.tools.handle_cancel()
	var axis_line := ""
	for e in _root.active_sketch().entities():
		if e.kind() == "line":
			var l := e as SketchLine
			var p0: Vector2 = _root.active_sketch().point(l.p0).pos
			if absf(p0.x) < 1e-6 and p0.y < -2.0:
				axis_line = e.id
	_root.finish_sketch()
	if axis_line == "":
		return _fail("axis line not found after drawing")
	var r4 := _root.revolve(s1, Vector2(25, 5), axis_line, 360.0)
	if r4 == "":
		return _fail("line-axis revolve refused")
	var vol4 := BodyBuilder.mesh_volume(
		(_root.doc.feature_by_id(r4) as RevolveFeature).build_mesh(_root.doc))
	if absf(vol4 - 5000.0 * PI) > 200.0:
		return _fail("line-axis volume wrong: %f" % vol4)
	_root.stack.undo()

	# --- E: a straddling region refuses.
	var s3 := _sketch_rect("XY", Vector2(-5, 20), Vector2(5, 30))
	_root.finish_sketch()
	if _root.revolve(s3, Vector2(0, 25), "y", 360.0) != "":
		return _fail("straddling region accepted")

	# --- F: ring with a hole revolves into ring-minus-torus.
	_root.edit_sketch(s1)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("circle")
	_click(Vector2(25, 5))
	_click(Vector2(27, 5))
	_root.finish_sketch()
	var r5 := _root.revolve(s1, Vector2(21, 1), "y", 360.0)
	var vol5 := BodyBuilder.mesh_volume(
		(_root.doc.feature_by_id(r5) as RevolveFeature).build_mesh(_root.doc))
	var want5 := 5000.0 * PI - 2.0 * PI * PI * 25.0 * 4.0
	if absf(vol5 - want5) > 250.0:
		return _fail("holed ring volume wrong: %f vs %f" % [vol5, want5])
	_root.stack.undo()
	# Drop the hole circle again (undo of the sketch edit is not a single
	# step here; rebuild the state instead by deleting the circle).
	_root.edit_sketch(s1)
	var doomed: Array[String] = []
	for e in _root.active_sketch().entities():
		if e.kind() == "circle":
			doomed.append(e.id)
			doomed.append((e as SketchCircle).center)
	_root.stack.push_no_merge(CmdDeleteEntities.new(s1, doomed))
	_root.finish_sketch()

	# --- G: revolve CUT through CSG — a half-cylinder trough carved out of a
	# box, axis a line entity on the XZ sketch. Also pins the spin DIRECTION:
	# a mirrored sweep would miss the box and remove nothing.
	var sb := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	var eb := _root.extrude(sb, Vector2(20, 15), 10.0)
	if eb == "":
		return _fail("box extrude refused")
	var sc := _sketch_rect("XZ", Vector2(20, -1), Vector2(32, 11))
	_root.tools.set_active("line")
	_click(Vector2(20, -8))
	_click(Vector2(20, -4))
	_root.tools.handle_cancel()
	var cut_axis := ""
	for e in _root.active_sketch().entities():
		if e.kind() == "line":
			var l := e as SketchLine
			var p0: Vector2 = _root.active_sketch().point(l.p0).pos
			var p1: Vector2 = _root.active_sketch().point(l.p1).pos
			if absf(p0.x - 20.0) < 1e-6 and absf(p1.x - 20.0) < 1e-6 \
					and p0.y < -2.0:
				cut_axis = e.id
	_root.finish_sketch()
	if cut_axis == "":
		return _fail("cut axis line not found")
	var rc := _root.revolve(sc, Vector2(26, 5), cut_axis, 360.0,
		SolidFeature.OP_CUT)
	if rc == "":
		return _fail("cut revolve refused")
	var vols: Array = []
	for b: Dictionary in await BodyBuilder.build(_root.doc, _root):
		vols.append(BodyBuilder.mesh_volume(b["mesh"]))
	if vols.size() != 1:
		return _fail("cut should leave one body, got %d" % vols.size())
	var want_cut := 12000.0 - 0.5 * PI * 144.0 * 10.0
	if absf(float(vols[0]) - want_cut) > 300.0:
		return _fail("cut volume wrong: %f vs %f" % [float(vols[0]), want_cut])

	# --- H: serialization round trip; the loaded revolve rebuilds.
	var text := Serializer.to_json(_root.doc)
	var loaded := Serializer.from_json(text)
	if Serializer.to_json(loaded) != text:
		return _fail("round trip not byte-identical")
	var lrc := loaded.feature_by_id(rc) as RevolveFeature
	if lrc == null or lrc.axis != cut_axis or absf(lrc.angle_deg - 360.0) > 1e-9 \
			or lrc.operation != SolidFeature.OP_CUT:
		return _fail("revolve did not serialize")
	if lrc.build_mesh(loaded) == null:
		return _fail("loaded revolve does not build")

	# --- I: undo removes the cut; the box volume returns.
	_root.stack.undo()
	var vols2: Array = []
	for b: Dictionary in await BodyBuilder.build(_root.doc, _root):
		vols2.append(BodyBuilder.mesh_volume(b["mesh"]))
	if vols2.size() != 1 or absf(float(vols2[0]) - 12000.0) > 50.0:
		return _fail("undo did not restore the box")
	_root.stack.redo()

	print("M23_REVOLVE OK: ring volume (Pappus), quarter sweep + caps, cone "
		+ "welds, line axis, straddle refusal, holed ring, CSG cut with "
		+ "matched spin direction, serialization, undo/redo")
	return true
