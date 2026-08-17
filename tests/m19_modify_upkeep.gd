extends SceneTree

# M19: modify-tool constraint upkeep.
# - Offset: one click offsets the whole connected chain; the copies carry
#   PARALLEL constraints to their sources plus one driving gap dimension.
# - Trim: directional constraints (H/parallel/...) move onto the kept
#   pieces instead of dying with the trimmed entity; radial constraints on
#   a trimmed circle move to the kept arc.
# - Center rectangle: emits a construction center point held at the
#   diagonal's midpoint, so the center survives corner drags.

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
	push_error("m19_modify_upkeep: " + msg)
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


func _count(sk: Sketch, kind: String) -> int:
	var n := 0
	for e in sk.entities():
		if e.kind() == kind and e.id != sk.origin_id():
			n += 1
	return n


func _cons_of(sk: Sketch, t: SketchConstraint.Type) -> Array:
	var out: Array = []
	for c in sk.constraints:
		if c.type == t:
			out.append(c)
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	var T := SketchConstraint.Type

	# --- OFFSET: one click on a rect edge offsets the whole rectangle -------
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	var lines_before := _count(sk, "line")
	_root.tools.set_active("offset")
	_click(Vector2(20, 0.2))          # pick the bottom edge -> whole chain
	_click(Vector2(20, -5))           # outside, 5mm below -> apply
	if _count(sk, "line") != lines_before + 4:
		return _fail("chain offset should copy all 4 edges, lines now %d"
			% _count(sk, "line"))
	var pars := _cons_of(sk, T.PARALLEL)
	if pars.size() != 4:
		return _fail("offset lines should be PARALLEL to sources, got %d"
			% pars.size())
	var gaps := _cons_of(sk, T.POINT_LINE_DIST)
	if gaps.size() != 1:
		return _fail("offset should carry ONE gap dimension, got %d" % gaps.size())
	if absf(float((gaps[0] as SketchConstraint).value) - 5.0) > 0.2:
		return _fail("gap dimension value wrong: %f"
			% float((gaps[0] as SketchConstraint).value))
	var a := DofAnalyzer.analyze(sk)
	if not (a["conflicts"] as Array).is_empty():
		return _fail("offset constraints conflict: %s" % str(a["conflicts"]))
	# One undo removes the whole offset (copy + constraints).
	_root.stack.undo()
	if _count(sk, "line") != lines_before or not _cons_of(sk, T.PARALLEL).is_empty():
		return _fail("offset was not one undo step")
	_root.stack.redo()

	# Driving the gap dimension re-solves the offset copy.
	var gap_idx := sk.constraints.find(_cons_of(sk, T.POINT_LINE_DIST)[0])
	_root.set_dimension_value(gap_idx, "8mm")
	await _idle()
	var gap_c: SketchConstraint = sk.constraints[gap_idx]
	if absf(ConstraintSolver.error_of(sk, gap_c)) > 0.01:
		return _fail("gap dimension did not drive after edit")

	# --- TRIM: H constraint survives onto both kept pieces ------------------
	_root.load_document(CadDocument.new())
	_root.create_sketch("XY")
	sk = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var pa := SketchPoint.make(Vector2(-40, 0))
	var pb := SketchPoint.make(Vector2(40, 0))
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var hline := SketchLine.make(pa.id, pb.id)
	hline.id = sk.next_id()
	var cons: Array = [SketchConstraint.make(T.HORIZONTAL, [hline.id])]
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pa, pb, hline], cons))
	# Two vertical cutters at x=-10 and x=10.
	for x in [-10.0, 10.0]:
		var qa := SketchPoint.make(Vector2(x, -20))
		var qb := SketchPoint.make(Vector2(x, 20))
		qa.id = sk.next_id()
		qb.id = sk.next_id()
		var vl := SketchLine.make(qa.id, qb.id)
		vl.id = sk.next_id()
		_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
			[qa, qb, vl]))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	# x=5, not 0: the sketch origin point sits at (0,0) and would win the
	# hover, which trim ignores.
	_click(Vector2(5, 0.3))     # middle span between the cutters
	var hcons := _cons_of(sk, T.HORIZONTAL)
	if hcons.size() != 2:
		return _fail("H should survive onto both kept pieces, got %d" % hcons.size())
	for c: SketchConstraint in hcons:
		if not sk.has(String(c.operands[0])):
			return _fail("retargeted H references a dead entity")
	var a2 := DofAnalyzer.analyze(sk)
	if not (a2["conflicts"] as Array).is_empty():
		return _fail("trim retarget created conflicts")

	# --- TRIM circle: RADIUS dimension survives onto the kept arc -----------
	var cc := SketchPoint.make(Vector2(0, -50))
	cc.id = sk.next_id()
	var circ := SketchCircle.make(cc.id, 15.0)
	circ.id = sk.next_id()
	var rdim: Array = [SketchConstraint.make(T.RADIUS, [circ.id], 15.0)]
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[cc, circ], rdim))
	# A cutter crossing the circle so trim has intersections to cut between.
	var ka := SketchPoint.make(Vector2(-30, -50))
	var kb := SketchPoint.make(Vector2(30, -50))
	ka.id = sk.next_id()
	kb.id = sk.next_id()
	var kl := SketchLine.make(ka.id, kb.id)
	kl.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[ka, kb, kl]))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	_click(Vector2(0, -35.2))    # top of the circle (above the cutter)
	if _count(sk, "circle") != 0 or _count(sk, "arc") != 1:
		return _fail("circle trim census wrong")
	var rads := _cons_of(sk, T.RADIUS)
	if rads.size() != 1:
		return _fail("RADIUS dim should survive the trim, got %d" % rads.size())
	var arc_id := String((rads[0] as SketchConstraint).operands[0])
	var kept := sk.entity(arc_id)
	if kept == null or kept.kind() != "arc":
		return _fail("RADIUS dim should now reference the kept arc")

	# --- CENTER RECT: construction center point rides the diagonal ----------
	_root.load_document(CadDocument.new())
	_root.create_sketch("XY")
	sk = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("center_rect")
	_click(Vector2(20, 15))
	_click(Vector2(30, 20))      # corner -> rect (10,10)..(30,20)
	if _count(sk, "line") != 5:
		return _fail("center rect should add 4 edges + construction diagonal")
	var mids := _cons_of(sk, T.MIDPOINT)
	if mids.size() != 1:
		return _fail("center rect should carry one MIDPOINT, got %d" % mids.size())
	var center_id := String((mids[0] as SketchConstraint).operands[0])
	var center := sk.point(center_id)
	if center == null or not center.construction:
		return _fail("center point missing or not construction")
	if center.pos.distance_to(Vector2(20, 15)) > 0.01:
		return _fail("center point not at the center: %s" % str(center.pos))
	var a3 := DofAnalyzer.analyze(sk)
	if not (a3["conflicts"] as Array).is_empty() \
			or not (a3["redundant"] as Array).is_empty():
		return _fail("center rect scaffolding is redundant/conflicting")
	# Drive the rect wider; the center must stay the diagonal's midpoint.
	var corner11 := Vector2(30, 20)
	var p11id := ""
	var p00id := ""
	for e in sk.entities():
		if e.kind() == "point":
			if (e as SketchPoint).pos.distance_to(corner11) < 0.01:
				p11id = e.id
			elif (e as SketchPoint).pos.distance_to(Vector2(10, 10)) < 0.01:
				p00id = e.id
	if p11id == "" or p00id == "":
		return _fail("could not find rect corners")
	_root.stack.push_no_merge(CmdMovePoints.new(_root.active_sketch_id,
		{p11id: Vector2(40, 24)}))
	_root.solve_followers([p11id])
	await _idle()
	var want: Vector2 = (sk.point(p00id).pos + sk.point(p11id).pos) * 0.5
	if sk.point(center_id).pos.distance_to(want) > 0.05:
		return _fail("center did not follow the corner drag: %s vs %s"
			% [str(sk.point(center_id).pos), str(want)])

	print("M19_MODIFY_UPKEEP OK: chain offset + parallels + gap dim, trim "
		+ "retargets H and RADIUS, center-rect center point holds")
	return true
