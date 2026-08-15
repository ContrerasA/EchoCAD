extends SceneTree

# M7: constraint palette — validation table, apply-to-selection with solve
# in one undo step, delete restores DOF, conflict surfacing, constrained
# coloring inputs.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m07_constraints: " + msg)
	return false


func _add_pt(sk: Sketch, p: Vector2) -> SketchPoint:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id, [e]))
	return e


func _add_line(sk: Sketch, a: Vector2, b: Vector2) -> SketchLine:
	var pa := SketchPoint.make(a)
	var pb := SketchPoint.make(b)
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id, [pa, pb, l]))
	return l


func _run() -> bool:
	var T := SketchConstraint.Type
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()

	# --- validation table refuses wrong operand kinds.
	var l1 := _add_line(sk, Vector2(0, 0), Vector2(40, 5))
	var l2 := _add_line(sk, Vector2(0, 20), Vector2(40, 30))
	var p1 := _add_pt(sk, Vector2(10, 10))
	_root.set_selection([l1.id])
	if _root.apply_constraint(T.PARALLEL) == "":
		return _fail("parallel accepted one line")
	_root.set_selection([l1.id, p1.id])
	if _root.apply_constraint(T.PARALLEL) == "":
		return _fail("parallel accepted line+point")

	# --- parallel applies + solves + is one undo step.
	var json_before := JSON.stringify(_root.doc.to_dict())
	_root.set_selection([l1.id, l2.id])
	if _root.apply_constraint(T.PARALLEL) != "":
		return _fail("parallel refused two lines")
	var d1: Vector2 = (sk.point(l1.p1).pos - sk.point(l1.p0).pos).normalized()
	var d2: Vector2 = (sk.point(l2.p1).pos - sk.point(l2.p0).pos).normalized()
	if absf(d1.cross(d2)) > 0.001:
		return _fail("parallel did not solve")
	_root.stack.undo()
	if JSON.stringify(_root.doc.to_dict()) != json_before:
		return _fail("constraint apply was not one undo step")
	_root.stack.redo()

	# --- DOF drops when constraints land; delete restores it.
	var dof_with: int = _root.dof["dof"]
	_root.delete_constraint(0)
	var dof_without: int = _root.dof["dof"]
	if dof_without != dof_with + 1:
		return _fail("delete did not restore DOF (%d -> %d)"
			% [dof_with, dof_without])
	_root.stack.undo()   # constraint back

	# --- dimensional constraint defaults to the measured value.
	_root.set_selection([sk.point(l1.p0).id, sk.point(l1.p1).id])
	var measured: float = sk.point(l1.p0).pos.distance_to(sk.point(l1.p1).pos)
	if _root.apply_constraint(T.DISTANCE) != "":
		return _fail("distance refused two points")
	var dc: SketchConstraint = sk.constraints[sk.constraints.size() - 1]
	if absf(dc.value - measured) > 0.001:
		return _fail("distance default not measured value")

	# --- conflict: contradictory distance flags red, summary reports it.
	var ops: Array[String] = [sk.point(l1.p0).id, sk.point(l1.p1).id]
	_root.add_constraint(SketchConstraint.make(T.DISTANCE, ops, measured * 2.0))
	if (_root.dof.get("conflicts", []) as Array).is_empty():
		return _fail("conflict not detected")
	if DofAnalyzer.summary(sk) != "Conflicting constraints":
		return _fail("conflict summary wrong")
	_root.delete_constraint(sk.constraints.size() - 1)

	# --- fully constrain a line; constrained sets feed the bridge.
	var l3 := _add_line(sk, Vector2(100, 100), Vector2(120, 100))
	_root.set_selection([sk.point(l3.p0).id])
	if _root.apply_constraint(T.FIX) != "":
		return _fail("fix refused a point")
	_root.set_selection([l3.id])
	if _root.apply_constraint(T.HORIZONTAL) != "":
		return _fail("H refused a line")
	var ops2: Array[String] = [sk.point(l3.p0).id, sk.point(l3.p1).id]
	_root.add_constraint(SketchConstraint.make(T.DISTANCE, ops2, 20.0))
	var cpts: Array = _root.dof.get("constrained_points", [])
	if not (cpts.has(sk.point(l3.p0).id) and cpts.has(sk.point(l3.p1).id)):
		return _fail("fully constrained line's points not detected: %s" % str(cpts))
	if not _root.bridge._is_constrained(l3):
		return _fail("bridge does not see l3 as constrained")
	if _root.bridge._is_constrained(l1):
		return _fail("bridge wrongly sees l1 as constrained")

	# --- symmetry via palette (two points + axis line).
	var s1 := _add_pt(sk, Vector2(-30, 60))
	var s2 := _add_pt(sk, Vector2(35, 60))
	var axis := _add_line(sk, Vector2(0, 40), Vector2(0, 90))
	_root.set_selection([s1.id, s2.id, axis.id])
	if _root.apply_constraint(T.SYMMETRY) != "":
		return _fail("symmetry refused pts+axis")
	# Operand order normalized: axis last.
	var sym: SketchConstraint = sk.constraints[sk.constraints.size() - 1]
	if sym.operands[2] != axis.id:
		return _fail("symmetry operands not normalized")

	print("M07_CONSTRAINTS OK: validation, apply+solve one step, delete, "
		+ "conflicts, constrained sets, symmetry")
	return true
