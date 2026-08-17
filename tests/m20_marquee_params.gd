extends SceneTree

# M20: marquee selection (window L->R = fully-contained, crossing R->L =
# touching, additive with Ctrl, plain empty click still deselects) and the
# Parameters dialog backend (upsert/remove with reference protection).

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
	push_error("m20_marquee_params: " + msg)
	return false


func _pt(world: Vector2) -> Vector2:
	return _root.sketch_view.world_to_screen(world)


func _band(from: Vector2, to: Vector2, ctrl := false) -> void:
	var tool: SketchTool = _root.tools.get_tool("select")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.ctrl_pressed = ctrl
	tool.pointer_down(from, _pt(from), down)
	var mid := (from + to) * 0.5
	for w in [mid, to]:
		tool.pointer_move(w, _pt(w), InputEventMouseMotion.new())
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	tool.pointer_up(to, _pt(to), up)


func _click_world(world: Vector2) -> void:
	var tool: SketchTool = _root.tools.get_tool("select")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	tool.pointer_down(world, _pt(world), down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	tool.pointer_up(world, _pt(world), up)


func _rect(a: Vector2, b: Vector2) -> void:
	var tool: SketchTool = _root.tools.get_tool("rect")
	for w in [a, b]:
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		tool.pointer_move(w, _pt(w), InputEventMouseMotion.new())
		tool.pointer_down(w, _pt(w), down)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2(30, 8), 4.0)
	_root.snap.grid_enabled = false

	# Two rectangles: A (0,0)-(20,15), B (40,0)-(60,15).
	_root.tools.set_active("rect")
	_rect(Vector2(0, 0), Vector2(20, 15))
	_rect(Vector2(40, 0), Vector2(60, 15))
	var a_ids := {}
	var b_ids := {}
	for e in sk.entities():
		if e.id == sk.origin_id():
			continue
		var probe: Vector2
		if e.kind() == "point":
			probe = (e as SketchPoint).pos
		elif e.kind() == "line":
			probe = (sk.point((e as SketchLine).p0).pos
				+ sk.point((e as SketchLine).p1).pos) * 0.5
		if probe.x <= 25.0:
			a_ids[e.id] = true
		else:
			b_ids[e.id] = true
	if a_ids.size() != 8 or b_ids.size() != 8:
		return _fail("fixture census wrong: %d/%d" % [a_ids.size(), b_ids.size()])

	_root.tools.set_active("select")

	# --- window select (L->R) fully around A: all of A, none of B.
	_band(Vector2(-5, -5), Vector2(25, 20))
	var sel: Array = _root.selection
	if sel.size() != 8:
		return _fail("window band should select all 8 of A, got %d" % sel.size())
	for id in sel:
		if not a_ids.has(id):
			return _fail("window band leaked outside A: %s" % id)

	# --- window select partially over B: only the fully-contained left edge
	# (its two corner points + the vertical line); the horizontals poke out.
	_band(Vector2(35, -5), Vector2(50, 20))
	sel = _root.selection
	if sel.size() != 3:
		return _fail("partial window should select 3 (edge+2 pts), got %d"
			% sel.size())

	# --- crossing select (R->L) over B's right side: touching counts.
	_band(Vector2(70, 8), Vector2(55, -5))
	sel = _root.selection
	if sel.size() < 3:
		return _fail("crossing band too small a catch: %d" % sel.size())
	for id in sel:
		if a_ids.has(id):
			return _fail("crossing band reached A")

	# --- Ctrl-band adds to the selection instead of replacing it.
	_band(Vector2(-5, -5), Vector2(25, 20))
	var before := _root.selection.size()
	_band(Vector2(35, -5), Vector2(65, 20), true)
	if _root.selection.size() != before + 8:
		return _fail("additive band should add all of B, got %d"
			% _root.selection.size())

	# --- plain empty click still deselects.
	_click_world(Vector2(30, -10))
	if not _root.selection.is_empty():
		return _fail("empty click should clear the selection")

	# --- Parameters: upsert, drive a dimension, reference-protected delete.
	var why := _root.upsert_parameter("width", "2", UnitConverter.Unit.IN)
	if why != "":
		return _fail("upsert refused: " + why)
	if _root.doc.parameters.size() != 1 \
			or absf((_root.doc.parameters[0] as CadParameter).value - 50.8) > 1e-6:
		return _fail("parameter value wrong")
	# Dimension a line of rect A with the parameter.
	var line_id := ""
	for e in sk.entities():
		if e.kind() == "line" and a_ids.has(e.id):
			line_id = e.id
			break
	var l := sk.entity(line_id) as SketchLine
	var ops: Array[String] = [l.p0, l.p1]
	_root.add_constraint(SketchConstraint.make(
		SketchConstraint.Type.DISTANCE, ops, 20.0))
	var dim_idx := sk.constraints.size() - 1
	var why2 := _root.set_dimension_value(dim_idx, "width")
	if why2 != "":
		return _fail("expression dimension refused: " + why2)
	await _idle()
	if absf(sk.point(l.p0).pos.distance_to(sk.point(l.p1).pos) - 50.8) > 0.01:
		return _fail("dimension did not drive to width")
	# Editing the parameter re-drives the geometry.
	_root.upsert_parameter("width", "3", UnitConverter.Unit.IN)
	await _idle()
	if absf(sk.point(l.p0).pos.distance_to(sk.point(l.p1).pos) - 76.2) > 0.01:
		return _fail("parameter edit did not re-drive")
	# Delete refused while referenced; allowed after the dimension goes.
	if _root.remove_parameter("width") == "":
		return _fail("delete of a referenced parameter should refuse")
	_root.delete_constraint(dim_idx)
	if _root.remove_parameter("width") != "":
		return _fail("delete should succeed once unreferenced")
	if not _root.doc.parameters.is_empty():
		return _fail("parameter not removed")
	# Bad expression reports, does not apply.
	if _root.upsert_parameter("bad", "nope + 1", UnitConverter.Unit.MM) == "":
		return _fail("bad expression should refuse")

	# --- dialog exists and populates.
	_root._open_params_dialog()
	await _idle()
	if _root._params_dialog == null or not _root._params_dialog.visible:
		return _fail("parameters dialog did not open")
	_root._param_name.text = "depth"
	_root._param_expr.text = "12"
	_root._param_unit.selected = 1   # mm
	_root._commit_param()
	if _root._param_err.text != "" or _root.doc.parameters.size() != 1:
		return _fail("dialog commit failed: '%s'" % _root._param_err.text)
	_root._param_expr.text = "depth + "   # malformed
	_root._commit_param()
	if _root._param_err.text == "":
		return _fail("dialog should surface expression errors")

	print("M20_MARQUEE_PARAMS OK: window/crossing/additive bands, empty-"
		+ "click deselect, parameter upsert/drive/protected delete, dialog")
	return true
