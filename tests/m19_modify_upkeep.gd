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
	# Every offset line carries a grouped LINE_DIST (parallel + gap in one
	# constraint); one dimension shows for the group.
	var gaps := _cons_of(sk, T.LINE_DIST)
	if gaps.size() != 4:
		return _fail("offset should carry 4 grouped gaps, got %d" % gaps.size())
	var grp := (gaps[0] as SketchConstraint).group
	if grp == "":
		return _fail("offset gaps should share a dimension group")
	for g: SketchConstraint in gaps:
		if g.group != grp:
			return _fail("offset gaps not all in one group")
		if absf(float(g.value) - 5.0) > 0.2:
			return _fail("gap dimension value wrong: %f" % float(g.value))
	var a := DofAnalyzer.analyze(sk)
	if not (a["conflicts"] as Array).is_empty():
		return _fail("offset constraints conflict: %s" % str(a["conflicts"]))
	# One undo removes the whole offset (copy + constraints).
	_root.stack.undo()
	if _count(sk, "line") != lines_before or not _cons_of(sk, T.LINE_DIST).is_empty():
		return _fail("offset was not one undo step")
	_root.stack.redo()

	# Driving the ONE shown gap dimension re-drives the WHOLE ring: every
	# offset edge lands at the new gap from its source (QA §M19.2).
	var gap_idx := sk.constraints.find(_cons_of(sk, T.LINE_DIST)[0])
	_root.set_dimension_value(gap_idx, "8mm")
	await _idle()
	for g: SketchConstraint in _cons_of(sk, T.LINE_DIST):
		if absf(float(g.value) - 8.0) > 1e-6:
			return _fail("group edit did not propagate: %f" % float(g.value))
		if absf(ConstraintSolver.error_of(sk, g)) > 0.02:
			return _fail("an offset edge did not re-drive to the new gap: err %f"
				% ConstraintSolver.error_of(sk, g))

	# Dragging a SOURCE corner pulls the offset copy along (QA §M19.3): the
	# ring is rigid against its source, so the gaps must still hold.
	# Nearest point to the original corner: the free re-solve above may have
	# shared a little of the gap correction with the source rectangle.
	var corner_id := ""
	var best_cd := 5.0
	for e in sk.entities():
		if e.kind() == "point":
			var cd := (e as SketchPoint).pos.distance_to(Vector2(40, 30))
			if cd < best_cd:
				best_cd = cd
				corner_id = e.id
	if corner_id == "":
		return _fail("source corner not found")
	var batch := CmdMergeBatch.new("Drag", [])
	_root.stack.push_no_merge(batch)
	_root.stack.push(CmdMovePoints.new(_root.active_sketch_id,
		{corner_id: sk.point(corner_id).pos + Vector2(10, 6)}))
	_root.solve_followers([corner_id])
	batch.seal()
	await _idle()
	for g: SketchConstraint in _cons_of(sk, T.LINE_DIST):
		if absf(ConstraintSolver.error_of(sk, g)) > 0.05:
			return _fail("offset did not follow the source drag: err %f"
				% ConstraintSolver.error_of(sk, g))

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

	# --- TRIM: tangency survives onto the kept arc (QA §M19.6) --------------
	_root.load_document(CadDocument.new())
	_root.create_sketch("XY")
	sk = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var tc := SketchPoint.make(Vector2(0, -40))
	tc.id = sk.next_id()
	var tcirc := SketchCircle.make(tc.id, 15.0)
	tcirc.id = sk.next_id()
	var ta := SketchPoint.make(Vector2(-25, -25))
	var tb := SketchPoint.make(Vector2(25, -25))
	ta.id = sk.next_id()
	tb.id = sk.next_id()
	var tl := SketchLine.make(ta.id, tb.id)
	tl.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[tc, tcirc, ta, tb, tl],
		[SketchConstraint.make(T.TANGENT, [tl.id, tcirc.id])]))
	var ua := SketchPoint.make(Vector2(-25, -40))
	var ub := SketchPoint.make(Vector2(25, -40))
	ua.id = sk.next_id()
	ub.id = sk.next_id()
	var ul := SketchLine.make(ua.id, ub.id)
	ul.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[ua, ub, ul]))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	_click(Vector2(0, -55.2))    # bottom of the circle, far from the tangency
	var tans := _cons_of(sk, T.TANGENT)
	if tans.size() != 1:
		return _fail("TANGENT should survive the circle trim, got %d" % tans.size())
	var tkept := sk.entity(String((tans[0] as SketchConstraint).operands[1]))
	if tkept == null or tkept.kind() != "arc":
		return _fail("TANGENT should retarget onto the kept arc")
	if ConstraintSolver.error_of(sk, tans[0]) > 0.01:
		return _fail("retargeted tangency not satisfied: %f"
			% ConstraintSolver.error_of(sk, tans[0]))
	# Drag the tangent line's midpoint; the arc must follow (tangency holds).
	_root.tools.set_active("select")
	var mid_pts := {ta.id: Vector2(-25, -20), tb.id: Vector2(25, -20)}
	var tbatch := CmdMergeBatch.new("Drag", [])
	_root.stack.push_no_merge(tbatch)
	_root.stack.push(CmdMovePoints.new(_root.active_sketch_id, mid_pts))
	_root.solve_followers([ta.id, tb.id])
	tbatch.seal()
	await _idle()
	if ConstraintSolver.error_of(sk, tans[0]) > 0.02:
		return _fail("tangency broke when the line moved: %f"
			% ConstraintSolver.error_of(sk, tans[0]))

	# Singular-config false alarm (QA §M19.6 screenshot): H + point-on +
	# tangent at an EXACT tangency is rank-deficient right there, and the
	# analyzer used to paint the tangent amber as "redundant". The jittered
	# second-opinion pass must clear it.
	var s2 := Sketch.new()
	var sc := SketchPoint.make(Vector2(0, 0))
	sc.id = s2.next_id()
	s2.add(sc)
	var scirc := SketchCircle.make(sc.id, 15.0)
	scirc.id = s2.next_id()
	s2.add(scirc)
	var sa := SketchPoint.make(Vector2(-40, 15))
	sa.id = s2.next_id()
	s2.add(sa)
	var sb := SketchPoint.make(Vector2(0, 15))
	sb.id = s2.next_id()
	s2.add(sb)
	var sl := SketchLine.make(sa.id, sb.id)
	sl.id = s2.next_id()
	s2.add(sl)
	s2.constraints.append(SketchConstraint.make(T.HORIZONTAL, [sl.id]))
	s2.constraints.append(SketchConstraint.make(T.POINT_ON, [sb.id, scirc.id]))
	s2.constraints.append(SketchConstraint.make(T.TANGENT, [sl.id, scirc.id]))
	var an2 := DofAnalyzer.analyze(s2)
	if not (an2["redundant"] as Array).is_empty():
		return _fail("singular tangency wrongly flagged redundant: %s"
			% str(an2["redundant"]))

	# Tangency points ARE cuts (QA §M19.6 round 3): a circle whose only
	# contacts are two tangent lines (endpoints OFF the circle — no touch
	# cuts, and the grazing intersection is a numeric coin flip) must still
	# trim between the tangencies.
	_root.load_document(CadDocument.new())
	_root.create_sketch("XY")
	sk = _root.active_sketch()
	_root.sketch_view.set_view(Vector2(0, -40), 4.0)
	var gc := SketchPoint.make(Vector2(0, -40))
	gc.id = sk.next_id()
	var gcirc := SketchCircle.make(gc.id, 15.0)
	gcirc.id = sk.next_id()
	var g0 := SketchPoint.make(Vector2(-60, -25))
	var g1 := SketchPoint.make(Vector2(25, -25))
	var g2 := SketchPoint.make(Vector2(-60, -55))
	var g3 := SketchPoint.make(Vector2(20, -55))
	for p: SketchPoint in [g0, g1, g2, g3]:
		p.id = sk.next_id()
	var gl := SketchLine.make(g0.id, g1.id)
	var hl := SketchLine.make(g2.id, g3.id)
	gl.id = sk.next_id()
	hl.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[gc, gcirc, g0, g1, g2, g3, gl, hl], [
			SketchConstraint.make(T.HORIZONTAL, [gl.id]),
			SketchConstraint.make(T.HORIZONTAL, [hl.id]),
			SketchConstraint.make(T.TANGENT, [gl.id, gcirc.id]),
			SketchConstraint.make(T.TANGENT, [hl.id, gcirc.id]),
		]))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	_click(Vector2(-15.2, -40))
	if _count(sk, "circle") != 0 or _count(sk, "arc") != 1:
		return _fail("tangency-cut trim failed: circle=%d arc=%d"
			% [_count(sk, "circle"), _count(sk, "arc")])
	var gtans := _cons_of(sk, T.TANGENT)
	if gtans.size() != 2:
		return _fail("both tangents should survive tangency-cut trim, got %d"
			% gtans.size())
	for gt: SketchConstraint in gtans:
		if ConstraintSolver.error_of(sk, gt) > 0.01:
			return _fail("tangency-cut trim left a violated tangent: %f"
				% ConstraintSolver.error_of(sk, gt))
	var an3 := DofAnalyzer.analyze(sk)
	if not (an3["redundant"] as Array).is_empty() \
			or not (an3["conflicts"] as Array).is_empty():
		return _fail("tangency-cut trim left redundant/conflicting rows")

	# Solver ratchet (QA §M19 follow-up): line -> tangent arc -> line, then a
	# driven dimension re-driven many times. The arc's radius must NOT creep —
	# it used to grow on every single edit (15.4 mm -> 17.3 mm over ten).
	_root.load_document(CadDocument.new())
	_root.create_sketch("XY")
	sk = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("line")
	_click(Vector2(-60, 20))
	_click(Vector2(0, 20))
	_root.tools.handle_cancel()
	_root.tools.set_active("tangent_arc")
	_click(Vector2(0, 20))
	_click(Vector2(5, -10))
	_root.tools.handle_cancel()
	_root.tools.set_active("line")
	_click(Vector2(5, -10))
	_click(Vector2(-55, -10))
	_root.tools.handle_cancel()
	var chain_arc: SketchArc = null
	for e in sk.entities():
		if e.kind() == "arc":
			chain_arc = e
	if chain_arc == null:
		return _fail("tangent-arc chain build failed")
	var r_entry: float = sk.point(chain_arc.center).pos \
		.distance_to(sk.point(chain_arc.start).pos)
	var top_line: SketchLine = null
	for e in sk.entities():
		if e is SketchLine and sk.point((e as SketchLine).p0) != null \
				and absf(sk.point((e as SketchLine).p0).pos.y - 20.0) < 1.0:
			top_line = e
			break
	if top_line == null:
		return _fail("chain top line not found")
	var ddim := SketchConstraint.make(T.DISTANCE,
		[top_line.p0, top_line.p1], 50.0)
	_root.add_constraint(ddim)
	var didx := sk.constraints.find(ddim)
	for v: String in ["60", "45", "70", "50", "65", "55", "60", "50"]:
		_root.set_dimension_value(didx, v + "mm")
	var r_after: float = sk.point(chain_arc.center).pos \
		.distance_to(sk.point(chain_arc.start).pos)
	if absf(r_after - r_entry) > 0.5:
		return _fail("arc radius ratcheted across edits: %.3f -> %.3f"
			% [r_entry, r_after])

	# Component isolation (QA §M19 follow-up): editing a dimension on an
	# UNRELATED line must not move the tangent-arc chain AT ALL — the solve
	# is scoped to the edited constraint's connected component.
	var x0 := SketchPoint.make(Vector2(120, -40))
	var x1 := SketchPoint.make(Vector2(145, -40))
	x0.id = sk.next_id()
	x1.id = sk.next_id()
	var xl := SketchLine.make(x0.id, x1.id)
	xl.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[x0, x1, xl]))
	var udim := SketchConstraint.make(T.DISTANCE, [x0.id, x1.id], 25.4)
	_root.add_constraint(udim)
	var chain_snapshot := {}
	for pid: String in [chain_arc.center, chain_arc.start, chain_arc.end]:
		chain_snapshot[pid] = sk.point(pid).pos
	var uidx := sk.constraints.find(udim)
	for v: String in ["50.8", "25.4", "50.8"]:
		_root.set_dimension_value(uidx, v + "mm")
	for pid: String in chain_snapshot:
		if sk.point(pid).pos != (chain_snapshot[pid] as Vector2):
			return _fail("unrelated dimension edit moved the arc chain: %s"
				% pid)

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

	print("M19_MODIFY_UPKEEP OK: chain offset + grouped gaps drive/follow, "
		+ "trim retargets H, RADIUS and TANGENT, center-rect center holds")
	return true
