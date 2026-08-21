extends SceneTree
## CHANGES #6: every operand-taking tool can be ARMED FIRST and have its
## operands picked afterwards (hover + click), while select-first still works.

var _root: AppRoot


func _init() -> void:
	_root = AppRoot.new()
	root.add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m37_arm_then_pick: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _click(world: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	_root.tools.handle_pointer_move(world, screen, InputEventMouseMotion.new())
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	_root.tools.handle_pointer_down(world, screen, down)
	var up := InputEventMouseButton.new()
	up.button_index = button
	_root.tools.handle_pointer_up(world, screen, up)


func _hover(world: Vector2) -> String:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	_root.tools.handle_pointer_move(world, screen, InputEventMouseMotion.new())
	return _root.tools.get_tool(_root.tools.active_id()).hover_id


func _line(sk: Sketch, a: Vector2, b: Vector2) -> String:
	var p0 := SketchPoint.make(a)
	p0.id = sk.next_id()
	var p1 := SketchPoint.make(b)
	p1.id = sk.next_id()
	var l := SketchLine.make(p0.id, p1.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[p0, p1, l], []))
	return l.id


func _count(sk: Sketch, kind: String) -> int:
	var n := 0
	for e in sk.entities():
		if e.kind() == kind:
			n += 1
	return n


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var fid := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2(20, 10), 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	var sk: Sketch = _root.doc.sketch_feature(fid).sketch
	var l1 := _line(sk, Vector2(0, 0), Vector2(40, 5))
	var l2 := _line(sk, Vector2(0, 20), Vector2(40, 28))
	await _idle()

	# --- A: constraint ARMED FIRST, operands picked after -------------------
	_root.set_selection([])
	_root.arm_constraint(SketchConstraint.Type.PARALLEL, "Parallel")
	if _root.tools.active_id() != "constraint":
		return _fail("A: constraint button did not arm the constraint tool")
	var ct := _root.tools.get_tool("constraint") as ConstraintTool
	if ct.type != SketchConstraint.Type.PARALLEL:
		return _fail("A: wrong constraint type armed")
	if _hover(Vector2(20, 2.5)) != l1:
		return _fail("A: no hover pre-highlight on the operand")
	var before := sk.constraints.size()
	_click(Vector2(20, 2.5))
	if _root.selection != [l1] or sk.constraints.size() != before:
		return _fail("A: first pick should wait for the second operand")
	_click(Vector2(20, 24))
	if sk.constraints.size() != before + 1 \
			or sk.constraints[-1].type != SketchConstraint.Type.PARALLEL:
		return _fail("A: constraint not applied once the picks validated")
	if not _root.selection.is_empty() or _root.tools.active_id() != "constraint":
		return _fail("A: tool should stay armed with an empty selection")
	# Wrong operand kinds restart the pick set instead of jamming.
	_root.arm_constraint(SketchConstraint.Type.COINCIDENT, "Coincident")
	_click(Vector2(20, 2.5))   # a line — not a point
	_click(Vector2(20, 24))
	if sk.constraints.size() != before + 1:
		return _fail("A: invalid picks must not apply")
	_click(Vector2(0, 0))    # a point: starts over
	if _root.selection.size() != 1:
		return _fail("A: a full invalid set should restart with the new pick")
	# Esc: clear picks, then leave the tool.
	_root.tools.handle_cancel()
	if not _root.selection.is_empty():
		return _fail("A: Esc should clear the picks")

	# --- B: select-first still applies at once -----------------------------
	_root.tools.set_active("select")
	_root.set_selection([l1, l2])
	before = sk.constraints.size()
	_root.arm_constraint(SketchConstraint.Type.EQUAL, "Equal")
	if sk.constraints.size() != before + 1 or _root.tools.active_id() != "select":
		return _fail("B: a valid selection should apply immediately, tool unchanged")

	# --- C: mirror armed with nothing selected: gather, confirm, axis ------
	_root.stack.undo()   # drop the EQUAL so the mirror solves freely
	_root.stack.undo()   # and the PARALLEL
	var axis := _line(sk, Vector2(-10, -20), Vector2(-10, 40))
	_root.set_selection([])
	_root.tools.set_active("mirror")
	var mt := _root.tools.get_tool("mirror") as MirrorTool
	if not mt.gathering:
		return _fail("C: mirror with no selection should gather")
	if _hover(Vector2(20, 2.5)) != l1:
		return _fail("C: no hover while gathering")
	_click(Vector2(20, 2.5))
	if _root.selection != [l1]:
		return _fail("C: gather click did not select the entity")
	_click(Vector2(20, 2.5))
	if not _root.selection.is_empty():
		return _fail("C: gather click should toggle")
	_click(Vector2(20, 2.5))
	_click(Vector2(30, 24), MOUSE_BUTTON_RIGHT)   # confirm
	if mt.gathering:
		return _fail("C: right-click did not confirm the gather stage")
	var lines_before := _count(sk, "line")
	_click(Vector2(-10, 10))   # the axis
	if _count(sk, "line") != lines_before + 1:
		return _fail("C: mirror did not run after the armed pick")

	# --- D: rect pattern armed first, Enter confirms ------------------------
	_root.set_selection([])
	_root.tools.set_active("rect_pattern")
	var rt := _root.tools.get_tool("rect_pattern") as RectPatternTool
	if not rt.gathering:
		return _fail("D: pattern with no selection should gather")
	_click(Vector2(20, 24))   # l2
	if not _root.tools.handle_commit() or rt.gathering:
		return _fail("D: Enter did not confirm the gather stage")
	lines_before = _count(sk, "line")
	_click(Vector2(20, 60))   # spacing click commits the default 2x1
	if _count(sk, "line") <= lines_before:
		return _fail("D: pattern did not run after the armed pick")
	# Esc while gathering clears first, then leaves.
	_root.set_selection([])
	_root.tools.set_active("circ_pattern")
	_click(Vector2(20, 24))
	if not _root.tools.handle_cancel() or _root.selection.size() != 0:
		return _fail("D: Esc should clear gathered picks")

	# --- E: body commands arm a body pick ---------------------------------
	_root.finish_sketch()
	var bx := _root.create_sketch("XZ")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(20, 20))
	_root.finish_sketch()
	var body := _root.extrude(bx, Vector2(10, 10), 10.0)
	await _idle()
	await _idle()
	_root.select_body("")
	_root.open_move_dialog("")
	if not _root.picking_body:
		return _fail("E: Move Body with no body selected should arm a body pick")
	# Hover then click the body through the viewport input path.
	# Aim at the body's own centre: a hand-written probe point only lands on
	# the body for one particular camera framing, and the framing is not what
	# this test is about.
	var at := _root.rig.camera.unproject_position(
		_root.world.feature_bounds(body).get_center())
	var mm := InputEventMouseMotion.new()
	mm.position = at
	_root._on_viewport_input(mm)
	if _root.world._hover_body != body:
		return _fail("E: body pick has no hover pre-highlight")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = at
	_root._on_viewport_input(mb)
	if _root.picking_body or _root.world.selected_body() != body:
		return _fail("E: body click did not select the body")
	if _root._move_dialog == null or not _root._move_dialog.visible:
		return _fail("E: the armed command did not run after the pick")
	_root._move_dialog.hide()
	# Esc cancels an armed body pick.
	_root.select_body("")
	# M39: Mirror opens its dialog with the SOURCE pick armed (body or
	# feature-by-face); hover tints bodies, Esc drops the pick.
	_root._on_mirror_body_pressed()
	if _root.picking_source != "body":
		return _fail("E: Mirror with nothing selected should arm the source pick")
	_root._on_viewport_input(mm)
	if _root.world._hover_body != body:
		return _fail("E: source pick has no hover pre-highlight")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_root.handle_app_key(esc)
	if _root.picking_source != "":
		return _fail("E: Esc did not cancel the source pick")
	# Re-arm and click: the body lands in the dialog as the source.
	(_root._mirror_dialog.find_child("MirrorSourceBtn", true, false) as Button).button_pressed = true
	_root._on_viewport_input(mm)
	_root._on_viewport_input(mb)
	if _root._mirror_dialog.source_id("source") != body:
		return _fail("E: body click did not land as the mirror source")
	_root._mirror_dialog.cancel()

	print("M37_ARM_THEN_PICK OK: constraints, mirror, patterns and body ",
		"commands all accept operands after arming")
	return true
