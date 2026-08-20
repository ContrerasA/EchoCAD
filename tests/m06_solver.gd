extends SceneTree

# M6: constraint solver unit tests — convergence per type, pinning, arc
# implicit coupling, over-constraint stability.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m06_solver: " + msg)
	return false


func _pt(sk: Sketch, p: Vector2) -> SketchPoint:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	sk.add(e)
	return e


func _line(sk: Sketch, a: SketchPoint, b: SketchPoint) -> SketchLine:
	var l := SketchLine.make(a.id, b.id)
	l.id = sk.next_id()
	sk.add(l)
	return l


func _apply(sk: Sketch, res: Dictionary) -> void:
	for id: String in res["points"]:
		sk.point(id).pos = res["points"][id]
	for id: String in res["radii"]:
		(sk.entity(id) as SketchCircle).radius = res["radii"][id]


func _con(sk: Sketch, t: SketchConstraint.Type, ops: Array, v := 0.0) -> SketchConstraint:
	var typed: Array[String] = []
	for o in ops:
		typed.append(String(o))
	var c := SketchConstraint.make(t, typed, v)
	sk.constraints.append(c)
	return c


func _run() -> bool:
	var T := SketchConstraint.Type

	# --- DISTANCE with a pinned end: only the free end moves.
	var sk := Sketch.new()
	var a := _pt(sk, Vector2(0, 0))
	var b := _pt(sk, Vector2(30, 0))
	_con(sk, T.DISTANCE, [a.id, b.id], 50.8)
	var res := ConstraintSolver.solve(sk, [a.id])
	_apply(sk, res)
	if a.pos != Vector2.ZERO:
		return _fail("pinned point moved")
	if absf(b.pos.distance_to(a.pos) - 50.8) > 0.001:
		return _fail("distance not driven: %f" % b.pos.distance_to(a.pos))

	# --- COINCIDENT + HORIZONTAL chain converges.
	sk = Sketch.new()
	var p1 := _pt(sk, Vector2(0, 0))
	var p2 := _pt(sk, Vector2(20, 5))
	var p3 := _pt(sk, Vector2(21, 6))
	var l1 := _line(sk, p1, p2)
	_con(sk, T.HORIZONTAL, [l1.id])
	_con(sk, T.COINCIDENT, [p2.id, p3.id])
	res = ConstraintSolver.solve(sk, [p1.id])
	_apply(sk, res)
	if absf(p2.pos.y) > 0.001 or p2.pos.distance_to(p3.pos) > 0.001:
		return _fail("H+coincident did not converge: %s %s" % [p2.pos, p3.pos])

	# --- TANGENT line-circle: gap closes.
	sk = Sketch.new()
	var la := _pt(sk, Vector2(-40, 0))
	var lb := _pt(sk, Vector2(40, 0))
	var l := _line(sk, la, lb)
	var cc := _pt(sk, Vector2(0, 30))
	var circle := SketchCircle.make(cc.id, 12.0)
	circle.id = sk.next_id()
	sk.add(circle)
	_con(sk, T.TANGENT, [l.id, circle.id])
	res = ConstraintSolver.solve(sk, [la.id, lb.id])
	_apply(sk, res)
	if absf(absf(cc.pos.y) - 12.0) > 0.001:
		return _fail("tangent not converged: center y=%f" % cc.pos.y)

	# --- EQUAL radius circles meet in the middle.
	sk = Sketch.new()
	var c1p := _pt(sk, Vector2(0, 0))
	var c2p := _pt(sk, Vector2(50, 0))
	var c1 := SketchCircle.make(c1p.id, 10.0)
	c1.id = sk.next_id()
	sk.add(c1)
	var c2 := SketchCircle.make(c2p.id, 20.0)
	c2.id = sk.next_id()
	sk.add(c2)
	_con(sk, T.EQUAL, [c1.id, c2.id])
	res = ConstraintSolver.solve(sk)
	_apply(sk, res)
	if absf(c1.radius - 15.0) > 0.001 or absf(c2.radius - 15.0) > 0.001:
		return _fail("equal radii wrong: %f %f" % [c1.radius, c2.radius])

	# --- Arc implicit coupling: dragging start keeps radii equal.
	sk = Sketch.new()
	var ac := _pt(sk, Vector2(0, 0))
	var as_ := _pt(sk, Vector2(20, 0))
	var ae := _pt(sk, Vector2(0, 20))
	var arc := SketchArc.make(ac.id, as_.id, ae.id, true)
	arc.id = sk.next_id()
	sk.add(arc)
	as_.pos = Vector2(30, 0)   # user dragged the start outward
	res = ConstraintSolver.solve(sk, [as_.id, ac.id])
	_apply(sk, res)
	if absf(ae.pos.distance_to(ac.pos) - 30.0) > 0.001:
		return _fail("arc end radius did not follow: %f"
			% ae.pos.distance_to(ac.pos))

	# --- RADIUS on an arc drives both rim points.
	_con(sk, T.RADIUS, [arc.id], 25.0)
	res = ConstraintSolver.solve(sk, [ac.id])
	_apply(sk, res)
	if absf(as_.pos.distance_to(ac.pos) - 25.0) > 0.001 \
			or absf(ae.pos.distance_to(ac.pos) - 25.0) > 0.001:
		return _fail("arc radius constraint failed")

	# --- PERPENDICULAR + PARALLEL.
	sk = Sketch.new()
	var q1 := _pt(sk, Vector2(0, 0))
	var q2 := _pt(sk, Vector2(30, 2))
	var q3 := _pt(sk, Vector2(0, 10))
	var q4 := _pt(sk, Vector2(5, 40))
	var m1 := _line(sk, q1, q2)
	var m2 := _line(sk, q3, q4)
	_con(sk, T.PERPENDICULAR, [m1.id, m2.id])
	res = ConstraintSolver.solve(sk)
	_apply(sk, res)
	var d1 := (q2.pos - q1.pos).normalized()
	var d2 := (q4.pos - q3.pos).normalized()
	if absf(d1.dot(d2)) > 0.001:
		return _fail("perpendicular not converged: dot=%f" % d1.dot(d2))

	# --- ANGLE 45deg between lines.
	sk = Sketch.new()
	var r1 := _pt(sk, Vector2(0, 0))
	var r2 := _pt(sk, Vector2(40, 0))
	var r3 := _pt(sk, Vector2(0, 0))
	var r4 := _pt(sk, Vector2(40, 10))
	var n1 := _line(sk, r1, r2)
	var n2 := _line(sk, r3, r4)
	_con(sk, T.ANGLE, [n1.id, n2.id], 45.0)
	res = ConstraintSolver.solve(sk, [r1.id, r2.id])
	_apply(sk, res)
	var ang := absf(rad_to_deg(wrapf((r4.pos - r3.pos).angle()
		- (r2.pos - r1.pos).angle(), -PI, PI)))
	if absf(ang - 45.0) > 0.1:
		return _fail("angle not converged: %f" % ang)

	# --- SYMMETRY about a vertical axis.
	sk = Sketch.new()
	var s1 := _pt(sk, Vector2(-20, 10))
	var s2 := _pt(sk, Vector2(15, 12))
	var x1 := _pt(sk, Vector2(0, -50))
	var x2 := _pt(sk, Vector2(0, 50))
	var axis := _line(sk, x1, x2)
	_con(sk, T.SYMMETRY, [s1.id, s2.id, axis.id])
	res = ConstraintSolver.solve(sk, [s1.id, x1.id, x2.id])
	_apply(sk, res)
	if s2.pos.distance_to(Vector2(20, 10)) > 0.001:
		return _fail("symmetry wrong: %s" % s2.pos)

	# --- Over-constrained conflict: solver stays bounded, no explosion.
	sk = Sketch.new()
	var o1 := _pt(sk, Vector2(0, 0))
	var o2 := _pt(sk, Vector2(30, 0))
	_con(sk, T.DISTANCE, [o1.id, o2.id], 20.0)
	_con(sk, T.DISTANCE, [o1.id, o2.id], 40.0)
	res = ConstraintSolver.solve(sk)
	_apply(sk, res)
	var got := o1.pos.distance_to(o2.pos)
	if not is_finite(got) or got < 15.0 or got > 45.0:
		return _fail("conflict exploded: %f" % got)

	# --- Driven dimension never moves geometry.
	sk = Sketch.new()
	var dd1 := _pt(sk, Vector2(0, 0))
	var dd2 := _pt(sk, Vector2(30, 0))
	var dc := _con(sk, T.DISTANCE, [dd1.id, dd2.id], 99.0)
	dc.driven = true
	res = ConstraintSolver.solve(sk)
	if not (res["points"] as Dictionary).is_empty():
		return _fail("driven dimension moved geometry")

	# --- ANGLE measures the visible corner, not p0->p1 directions. A 60°
	# corner where one line is drawn "backwards" through the apex must read 60
	# (the old direction-based measure said 120), and must solve to the typed
	# value in the same sector the arc is drawn in.
	sk = Sketch.new()
	var ka := _pt(sk, Vector2(10, 0))
	var kb := _pt(sk, Vector2(0, 0))
	var kc := _pt(sk, Vector2(5, 8.660254))
	var kl1 := _line(sk, ka, kb)      # points INTO the apex (kb)
	var kl2 := _line(sk, kb, kc)      # points OUT of the apex
	var kang := _con(sk, T.ANGLE, [kl1.id, kl2.id], 0.0)
	var kmeas := ConstraintRules.measured_value(sk, T.ANGLE, kang.operands)
	if absf(kmeas - 60.0) > 0.01:
		return _fail("angle should measure the 60° corner, got %f" % kmeas)
	kang.value = 45.0
	res = ConstraintSolver.solve(sk, [ka.id, kb.id])
	_apply(sk, res)
	kmeas = ConstraintRules.measured_value(sk, T.ANGLE, kang.operands)
	if absf(kmeas - 45.0) > 0.05:
		return _fail("angle should solve to 45° corner, got %f" % kmeas)
	if kc.pos.y < 0.0 or kc.pos.x < 0.0:
		return _fail("angle solve left its sector: %s" % kc.pos)

	print("M06_SOLVER OK: distance/H/coincident/tangent/equal/arc/radius/"
		+ "perpendicular/angle/symmetry/conflict/driven")
	return true
