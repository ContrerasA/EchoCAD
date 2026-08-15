extends SceneTree

# M6: DOF analysis — counts match hand-computed values, redundancy and
# conflicts detected, arcs contribute their implicit coupling.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m06_dof: " + msg)
	return false


func _pt(sk: Sketch, p: Vector2) -> SketchPoint:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	sk.add(e)
	return e


func _con(sk: Sketch, t: SketchConstraint.Type, ops: Array, v := 0.0) -> SketchConstraint:
	var typed: Array[String] = []
	for o in ops:
		typed.append(String(o))
	var c := SketchConstraint.make(t, typed, v)
	sk.constraints.append(c)
	return c


func _run() -> bool:
	var T := SketchConstraint.Type

	# Bare line: 4 vars, no constraints -> dof 4.
	var sk := Sketch.new()
	var a := _pt(sk, Vector2(0, 0))
	var b := _pt(sk, Vector2(30, 0))
	var l := SketchLine.make(a.id, b.id)
	l.id = sk.next_id()
	sk.add(l)
	var r := DofAnalyzer.analyze(sk)
	if r["vars"] != 4 or r["dof"] != 4:
		return _fail("bare line dof wrong: %s" % str(r))

	# + HORIZONTAL -> dof 3; + DISTANCE -> dof 2 (free translation).
	_con(sk, T.HORIZONTAL, [l.id])
	r = DofAnalyzer.analyze(sk)
	if r["dof"] != 3:
		return _fail("H dof wrong: %d" % int(r["dof"]))
	_con(sk, T.DISTANCE, [a.id, b.id], 30.0)
	r = DofAnalyzer.analyze(sk)
	if r["dof"] != 2:
		return _fail("H+dist dof wrong: %d" % int(r["dof"]))

	# + FIX(a) -> fully constrained (a's vars removed, b pinned by H+dist).
	_con(sk, T.FIX, [a.id])
	r = DofAnalyzer.analyze(sk)
	if not r["fully_constrained"] or int(r["dof"]) != 0:
		return _fail("fix did not fully constrain: %s" % str(r))
	if DofAnalyzer.summary(sk) != "Fully constrained":
		return _fail("summary wrong: %s" % DofAnalyzer.summary(sk))

	# Duplicate HORIZONTAL -> redundant but NOT a conflict.
	var dup := _con(sk, T.HORIZONTAL, [l.id])
	r = DofAnalyzer.analyze(sk)
	var dup_idx := sk.constraints.find(dup)
	if not (r["redundant"] as Array).has(dup_idx):
		return _fail("duplicate H not flagged redundant: %s" % str(r))
	if not (r["conflicts"] as Array).is_empty():
		return _fail("satisfied duplicate flagged as conflict")
	sk.constraints.erase(dup)

	# Contradictory second DISTANCE -> redundant AND conflicting.
	var bad := _con(sk, T.DISTANCE, [a.id, b.id], 60.0)
	r = DofAnalyzer.analyze(sk)
	var bad_idx := sk.constraints.find(bad)
	if not (r["conflicts"] as Array).has(bad_idx):
		return _fail("contradictory distance not flagged: %s" % str(r))
	if DofAnalyzer.summary(sk) != "Conflicting constraints":
		return _fail("conflict summary wrong")
	sk.constraints.erase(bad)

	# Circle: center 2 + radius 1 = 3 vars; RADIUS removes 1, FIX center
	# removes 2 -> fully constrained.
	sk = Sketch.new()
	var cp := _pt(sk, Vector2(0, 0))
	var ci := SketchCircle.make(cp.id, 10.0)
	ci.id = sk.next_id()
	sk.add(ci)
	r = DofAnalyzer.analyze(sk)
	if r["vars"] != 3 or r["dof"] != 3:
		return _fail("circle dof wrong: %s" % str(r))
	_con(sk, T.RADIUS, [ci.id], 10.0)
	_con(sk, T.FIX, [cp.id])
	r = DofAnalyzer.analyze(sk)
	if not r["fully_constrained"]:
		return _fail("circle not fully constrained: %s" % str(r))

	# Arc: 6 point vars - 1 implicit equal-radius = 5 dof (Fusion's arc DOF).
	sk = Sketch.new()
	var ac := _pt(sk, Vector2(0, 0))
	var as_ := _pt(sk, Vector2(20, 0))
	var ae := _pt(sk, Vector2(0, 20))
	var arc := SketchArc.make(ac.id, as_.id, ae.id, true)
	arc.id = sk.next_id()
	sk.add(arc)
	r = DofAnalyzer.analyze(sk)
	if r["vars"] != 6 or r["dof"] != 5:
		return _fail("arc dof wrong: %s" % str(r))

	print("M06_DOF OK: counts, redundancy, conflicts, circle, arc implicit")
	return true
