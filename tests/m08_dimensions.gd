extends SceneTree

# M8: smart dimension inference/park/type, dimension editing, expressions +
# parameters driving geometry, driven dimensions.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m08_dimensions: " + msg)
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


func _type_commit(text: String) -> void:
	var tool := _root.tools.get_tool(_root.tools.active_id())
	for ch in text:
		var e := InputEventKey.new()
		e.unicode = ch.unicode_at(0)
		tool.key_input(e)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	tool.key_input(enter)


func _last_dim(sk: Sketch) -> SketchConstraint:
	for i in range(sk.constraints.size() - 1, -1, -1):
		if sk.constraints[i].is_dimensional():
			return sk.constraints[i]
	return null


func _run() -> bool:
	var T := SketchConstraint.Type
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false

	# Fixture: a line and a circle.
	_root.tools.set_active("line")
	_click(Vector2(0, 0))
	_click(Vector2(40, 0))
	_root.tools.handle_cancel()
	var line: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e
	_root.tools.set_active("circle")
	_click(Vector2(80, 40))
	_click(Vector2(95, 40))
	var circle: SketchCircle = null
	for e in sk.entities():
		if e.kind() == "circle":
			circle = e

	# --- smart dimension on the line: pick, park, type 2in.
	var json_before := JSON.stringify(_root.doc.to_dict())
	_root.tools.set_active("dimension")
	_click(Vector2(20, 0.5))        # pick the line
	_click(Vector2(20, 15))         # park above
	var dim := _last_dim(sk)
	if dim == null or dim.type != T.DISTANCE:
		return _fail("line pick did not infer DISTANCE")
	if absf(dim.value - 40.0) > 0.001:
		return _fail("parked value not measured: %f" % dim.value)
	if dim.label_offset == Vector2.ZERO:
		return _fail("label_offset not parked")
	_type_commit("2")
	if absf(sk.point(line.p0).pos.distance_to(sk.point(line.p1).pos) - 50.8) > 0.01:
		return _fail("typed 2in did not drive the line")
	# Whole flow = ONE undo step.
	_root.stack.undo()
	if JSON.stringify(_root.doc.to_dict()) != json_before:
		return _fail("dimension pick+park+type not one undo step")
	_root.stack.redo()

	# --- circle -> DIAMETER.
	_click(Vector2(95, 40))         # pick circle (on rim)
	_click(Vector2(110, 60))        # park
	var ddim := _last_dim(sk)
	if ddim.type != T.DIAMETER:
		return _fail("circle pick did not infer DIAMETER")
	if absf(ddim.value - 30.0) > 0.01:
		return _fail("diameter measured wrong: %f" % ddim.value)
	_root.tools.handle_cancel()

	# --- two angled lines -> ANGLE.
	_root.tools.set_active("line")
	_click(Vector2(-80, -40))
	_click(Vector2(-40, -40))
	_root.tools.handle_cancel()
	_click(Vector2(-80, -40))
	_click(Vector2(-50, -10))
	_root.tools.handle_cancel()
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line":
			lines.append(e)
	_root.tools.set_active("dimension")
	_click(Vector2(-60, -40))          # first line
	_click(Vector2(-65, -25.5))        # second line (45deg-ish)
	_click(Vector2(-30, -30))          # park
	var adim := _last_dim(sk)
	if adim.type != T.ANGLE:
		return _fail("two angled lines did not infer ANGLE: %s"
			% SketchConstraint.Type.keys()[adim.type])
	if absf(adim.value - 45.0) > 1.0:
		return _fail("angle measured wrong: %f" % adim.value)
	_root.tools.handle_cancel()

	# --- parameters + expressions.
	var width := CadParameter.make("width", "2", UnitConverter.Unit.IN)
	var resolved := CadExpression.evaluate_params([width])
	width.value = resolved["values"]["width"]
	_root.set_parameters([width])
	# Drive the line dimension by an expression. (Editing replaced the
	# original object, so re-find it by shape.)
	var dim_index := -1
	for i in sk.constraints.size():
		var cc := sk.constraints[i]
		if cc.type == T.DISTANCE and cc.operands.has(line.p0):
			dim_index = i
	var batch := CmdMergeBatch.new("edit", [])
	_root.stack.push_no_merge(batch)
	var err := _root.set_dimension_value(dim_index, "width / 2")
	batch.seal()
	if err != "":
		return _fail("expression rejected: " + err)
	if absf(_last_len(sk, line) - 25.4) > 0.01:
		return _fail("expression did not drive: %f" % _last_len(sk, line))
	# Changing the parameter re-values the dimension AND moves geometry,
	# all one undo step.
	var snap_before := JSON.stringify(_root.doc.to_dict())
	var w2 := width.duplicate_parameter()
	w2.expr = "3"
	var resolved2 := CadExpression.evaluate_params([w2])
	w2.value = resolved2["values"]["width"]
	_root.set_parameters([w2])
	if absf(_last_len(sk, line) - 38.1) > 0.01:
		return _fail("parameter change did not re-drive: %f" % _last_len(sk, line))
	_root.stack.undo()
	if JSON.stringify(_root.doc.to_dict()) != snap_before:
		return _fail("parameter change not one undo step")
	_root.stack.redo()

	# --- bad expression rejected with a message, model untouched.
	var before_bad := JSON.stringify(_root.doc.to_dict())
	var bad := _root.set_dimension_value(dim_index, "wdth / 2")
	if bad == "" or JSON.stringify(_root.doc.to_dict()) != before_bad:
		return _fail("bad expression not rejected cleanly")

	# --- driven: measures, never moves geometry.
	_root.set_dimension_driven(dim_index, true)
	var len_before := _last_len(sk, line)
	var batch2 := CmdMergeBatch.new("edit", [])
	_root.stack.push_no_merge(batch2)
	_root.set_dimension_value(dim_index, "9")
	batch2.seal()
	if absf(_last_len(sk, line) - len_before) > 0.001:
		return _fail("driven dimension moved geometry")

	# --- Dimension to an ORIGIN AXIS: a vertical line, then the Y axis ->
	# LINE_DIST (the line's distance from x=0) on a pinned construction axis
	# line minted in the same undo step; typing drives the line there.
	_root.set_dimension_driven(dim_index, false)
	_root.tools.set_active("line")
	_click(Vector2(30, 60))
	_click(Vector2(30, 90))
	_root.tools.handle_cancel()
	var vline: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			vline = e
	var ents_before := sk.entities().size()
	var cons_before := sk.constraints.size()
	var snap_axis := _snap_no_ids()
	_root.tools.set_active("dimension")
	_click(Vector2(30, 75))            # the line
	_click(Vector2(0, 120))            # empty spot ON the Y axis
	_click(Vector2(15, 110))           # park
	var ad := _last_dim(sk)
	if ad == null or ad.type != T.LINE_DIST:
		return _fail("line + Y axis should infer LINE_DIST")
	if absf(ad.value - 30.0) > 0.01:
		return _fail("axis gap measured %f, want 30" % ad.value)
	if sk.entities().size() != ents_before + 2:
		return _fail("axis pick should mint one construction line + far point")
	var axis_line := sk.entity(ad.operands[1]) as SketchLine
	if axis_line == null or not axis_line.construction 			or (axis_line.p0 != sk.origin_id() and axis_line.p1 != sk.origin_id()):
		return _fail("axis operand is not a construction line from the origin")
	_type_commit("0.5")                # display unit is inch -> 12.7 mm
	var vx := sk.point(vline.p0).pos.x
	if absf(absf(vx) - 12.7) > 0.01:
		return _fail("axis gap did not drive the line: x=%f" % vx)
	_root.stack.undo()
	if _snap_no_ids() != snap_axis:
		return _fail("axis pick + park + type should be ONE undo step")
	_root.stack.redo()
	# A second axis dimension REUSES the same axis line.
	var ents_mid := sk.entities().size()
	_root.tools.set_active("dimension")
	_click(Vector2(0, 150))            # Y axis first
	_click(sk.point(vline.p1).pos)     # then the line's top point -> POINT_LINE_DIST
	_click(Vector2(10, 130))
	var pd := _last_dim(sk)
	if pd == null or pd.type != T.POINT_LINE_DIST:
		return _fail("axis + point should infer POINT_LINE_DIST")
	if sk.entities().size() != ents_mid:
		return _fail("second axis pick should reuse the existing axis line")
	_root.tools.handle_cancel()
	# Cancelling after an axis pick (before parking) leaves no stray geometry.
	var ents_c := sk.entities().size()
	_root.tools.set_active("dimension")
	_click(Vector2(-150, 0))           # X axis -> mints a new axis line
	if sk.entities().size() != ents_c + 2:
		return _fail("X axis pick should mint its line")
	_root.tools.handle_cancel()
	if sk.entities().size() != ents_c:
		return _fail("cancel after axis pick left stray construction")

	print("M08_DIMENSIONS OK: infer line/circle/angle, park+type one step, "
		+ "expressions, parameter re-drive, driven, origin-axis picks")
	return true


## Document snapshot minus id_counter (minted ids are never rewound by undo).
func _snap_no_ids() -> String:
	var d: Dictionary = _root.doc.to_dict()
	for f in d["features"]:
		if f.has("sketch"):
			(f["sketch"] as Dictionary).erase("id_counter")
	return JSON.stringify(d)


func _last_len(sk: Sketch, line: SketchLine) -> float:
	return sk.point(line.p0).pos.distance_to(sk.point(line.p1).pos)
