extends SceneTree

# M27: viewing — ortho/perspective toggle (size-preserving), Look At, Fit,
# display-unit switch, named views (save/apply/serialize), Measure math.

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
	push_error("m27_viewing: " + msg)
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
	var rig: OrbitCamera = _root.rig
	var initial_ortho := ThemeService.model_ortho

	# --- projection toggle preserves apparent size ------------------------
	if rig.is_orthographic():
		return _fail("model mode should start perspective by default")
	var vh_before := rig.view_height_mm()
	_root.set_model_projection(true)
	if not rig.is_orthographic():
		return _fail("ortho toggle did not switch projection")
	if absf(rig.view_height_mm() - vh_before) > vh_before * 0.01:
		return _fail("ortho switch jumped apparent size")
	if not ThemeService.model_ortho:
		return _fail("ortho preference not recorded")
	_root.set_model_projection(false)
	if rig.is_orthographic():
		return _fail("perspective toggle did not switch back")
	if absf(rig.view_height_mm() - vh_before) > vh_before * 0.01:
		return _fail("perspective switch jumped apparent size")

	# --- Look At squares the camera to a normal ---------------------------
	_root.look_at_normal(Vector3(0, 0, 1))
	await _idle()
	var fwd := -rig.camera.global_transform.basis.z
	if fwd.dot(Vector3(0, 0, -1)) < 0.999:
		return _fail("look_at +Z did not aim the camera down the normal")
	var xz := _root._plane_transform_for("XZ")
	_root.look_at_normal(xz.basis.z, xz.basis.y)
	await _idle()
	fwd = -rig.camera.global_transform.basis.z
	if fwd.dot(-xz.basis.z) < 0.999:
		return _fail("look_at XZ plane did not square up")

	# --- a body to frame and measure against ------------------------------
	var f1 := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	var sk: Sketch = _root.active_sketch()
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	# Measure needs known ids: find a line + its points + add a circle.
	_root.tools.set_active("circle")
	_click(Vector2(100, 0))
	_click(Vector2(112, 0))

	# --- Measure math ------------------------------------------------------
	var line_id := ""
	for e in sk.entities():
		if e.kind() == "line":
			line_id = e.id
			break
	var circle_id := ""
	for e in sk.entities():
		if e.kind() == "circle":
			circle_id = e.id
	var m := Measure.analyze(sk, [line_id])
	if m.get("kind") != "line_length":
		return _fail("line measure kind wrong: %s" % str(m))
	var ln := sk.entity(line_id) as SketchLine
	var want: float = sk.point(ln.p0).pos.distance_to(sk.point(ln.p1).pos)
	if absf(float(m["mm"]) - want) > 1e-6:
		return _fail("line length wrong: %f vs %f" % [m["mm"], want])
	m = Measure.analyze(sk, [circle_id])
	if m.get("kind") != "radius" or absf(float(m["mm"]) - 12.0) > 1e-6:
		return _fail("circle radius measure wrong: %s" % str(m))
	m = Measure.analyze(sk, [ln.p0, ln.p1])
	if m.get("kind") != "point_distance" \
			or absf(float(m["mm"]) - want) > 1e-6:
		return _fail("point distance wrong: %s" % str(m))
	m = Measure.analyze(sk, [ln.p0, circle_id])
	if not m.is_empty():
		return _fail("point+circle should measure nothing (got %s)" % str(m))
	# Two rect edges: perpendicular neighbours -> 90°; opposite -> parallel.
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line":
			lines.append(e)
	m = Measure.analyze(sk, [lines[0].id, lines[1].id])
	if m.get("kind") != "angle" or absf(float(m["deg"]) - 90.0) > 0.01:
		return _fail("neighbour edges angle wrong: %s" % str(m))
	m = Measure.analyze(sk, [lines[0].id, lines[2].id])
	if m.get("kind") != "parallel_distance" \
			or absf(float(m["mm"]) - 30.0) > 1e-6:
		return _fail("opposite edges parallel distance wrong: %s" % str(m))
	# Point to opposite edge: perpendicular distance 30.
	m = Measure.analyze(sk, [lines[2].id, ln.p0])
	if m.get("kind") != "point_line" or absf(float(m["mm"]) - 30.0) > 1e-6:
		return _fail("point-line distance wrong: %s" % str(m))
	# The status readout formats the same numbers.
	_root.set_selection([line_id])
	if _root._status_measure.text == "":
		return _fail("status measure readout empty for a line selection")
	_root.set_selection([])
	_root.finish_sketch()
	await _idle()

	var eid := _root.extrude(f1, Vector2(20, 15), 20.0)
	if eid == "":
		return _fail("extrude refused")
	await _idle()

	# --- Fit frames the body ----------------------------------------------
	rig.distance = 5000.0
	rig.target = Vector3(400, 400, 400)
	_root.fit_view()
	var bounds := _root.world.model_bounds()
	if rig.target.distance_to(bounds.get_center()) > 1.0:
		return _fail("fit did not center the model")
	var radius := bounds.size.length() * 0.5
	var vh := rig.view_height_mm()
	if vh < radius * 2.0 or vh > radius * 2.0 * 1.6:
		return _fail("fit view height off: %f for radius %f" % [vh, radius])

	# --- display unit: UI boundary only -----------------------------------
	_root.set_display_unit(UnitConverter.Unit.MM)
	if _root.doc.display_unit != UnitConverter.Unit.MM:
		return _fail("display unit did not switch")
	if _root.sketch_view.grid_unit != UnitConverter.Unit.MM:
		return _fail("sketch grid unit did not follow")
	var round_trip := CadDocument.from_dict(_root.doc.to_dict())
	if round_trip.display_unit != UnitConverter.Unit.MM:
		return _fail("display unit lost in serialization")

	# --- named views -------------------------------------------------------
	rig.yaw = 1.1
	rig.pitch = -0.7
	rig.distance = 900.0
	rig.target = Vector3(10, 20, 30)
	var saved := _root.save_named_view("QA")
	if _root.doc.named_views.size() != 1 or saved["name"] != "QA":
		return _fail("named view not saved")
	rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0))
	await _idle()
	_root.apply_named_view(_root.doc.named_views[0])
	await _idle()
	if absf(rig.yaw - 1.1) > 1e-3 or absf(rig.pitch + 0.7) > 1e-3 \
			or absf(rig.distance - 900.0) > 1.0 \
			or rig.target.distance_to(Vector3(10, 20, 30)) > 0.01:
		return _fail("named view did not restore the exact camera")
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	if doc2.named_views.size() != 1 \
			or String(doc2.named_views[0]["name"]) != "QA":
		return _fail("named views lost in serialization")

	# Leave settings as found.
	_root.set_model_projection(initial_ortho)
	ThemeService.model_ortho = initial_ortho
	ThemeService.save_settings()

	print("M27_VIEWING OK: projection toggle, look-at, fit, units, ",
		"named views, measure")
	return true
