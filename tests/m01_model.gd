extends SceneTree

# M1: entity CRUD, stable never-reused ids, constraint pruning on delete.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m01_model: " + msg)
	return false


func _run() -> bool:
	var sk := Sketch.new()

	# Every sketch is born with an origin point at (0,0) — the datum geometry
	# is dimensioned from. It occupies the first id, so nothing below may
	# assume a particular absolute id; they are asserted as relationships.
	var origin := sk.origin_id()
	if origin == "" or not sk.has(origin) or sk.size() != 1:
		return _fail("sketch did not start with exactly an origin")
	if sk.point(origin).pos != Vector2.ZERO:
		return _fail("origin is not at (0,0)")
	if sk.remove(origin) != null or not sk.has(origin):
		return _fail("origin must not be removable")

	# Ids mint sequentially and never repeat, even after deletion.
	var a := SketchPoint.make(Vector2(0, 0)); a.id = sk.next_id()
	var b := SketchPoint.make(Vector2(10, 0)); b.id = sk.next_id()
	if a.id == b.id or a.id == origin or b.id == origin:
		return _fail("ids collided: %s %s (origin %s)" % [a.id, b.id, origin])
	sk.add(a)
	sk.add(b)
	var line := SketchLine.make(a.id, b.id); line.id = sk.next_id()
	sk.add(line)
	if sk.size() != 4 or sk.entity_ids() != [origin, a.id, b.id, line.id]:
		return _fail("store contents wrong: %s" % str(sk.entity_ids()))
	if line.point_refs() != [a.id, b.id]:
		return _fail("line refs wrong")

	sk.remove(b.id)
	var c := SketchPoint.make(Vector2(5, 5)); c.id = sk.next_id()
	sk.add(c)
	if c.id == b.id:
		return _fail("id %s was reused" % b.id)
	if sk.has(b.id):
		return _fail("removed entity still present")

	# Insert-at restores original position (undo path). Index 2 = just after
	# the origin and `a`, which is where `b` was.
	sk.add(b, 2)
	if sk.entity_ids() != [origin, a.id, b.id, line.id, c.id]:
		return _fail("insert-at order wrong: %s" % str(sk.entity_ids()))

	# Constraint pruning: only constraints touching the deleted ids go.
	var c1 := SketchConstraint.make(SketchConstraint.Type.HORIZONTAL, [line.id])
	var c2 := SketchConstraint.make(SketchConstraint.Type.COINCIDENT, [a.id, c.id])
	var c3 := SketchConstraint.make(SketchConstraint.Type.DISTANCE, [a.id, b.id], 25.4)
	sk.constraints = [c1, c2, c3]
	var removed := sk.prune_constraints_for([b.id])
	if removed.size() != 1 or removed[0] != c3:
		return _fail("prune removed wrong constraints")
	if sk.constraints != [c1, c2]:
		return _fail("surviving constraints wrong")

	# Dimensional flag + serialization round-trip of a constraint.
	if not c3.is_dimensional() or c1.is_dimensional():
		return _fail("is_dimensional wrong")
	var rt := SketchConstraint.from_dict(c3.to_dict())
	if rt.type != c3.type or rt.operands != c3.operands or rt.value != c3.value:
		return _fail("constraint round-trip mismatch")

	# Entity round-trip through dicts (all four kinds).
	var arc := SketchArc.make(a.id, b.id, c.id, false); arc.id = sk.next_id()
	var circle := SketchCircle.make(a.id, 12.7); circle.id = sk.next_id()
	circle.construction = true
	for e: SketchEntity in [a, line, arc, circle]:
		var back := Sketch.entity_from_dict(e.to_dict())
		if back.to_dict() != e.to_dict():
			return _fail("entity round-trip mismatch for %s" % e.kind())

	print("M01_MODEL OK: CRUD, stable ids, constraint prune, dict round-trips")
	return true
