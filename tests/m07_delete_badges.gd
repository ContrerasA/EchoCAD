extends SceneTree

# M7 QA steps 2 and 6.
#
# Step 6: deleting a line left its endpoints behind as loose dots AND left any
# dimension on it alive — a distance dimension references the POINTS, not the
# line, so pruning by the line's id never reached it. The user was left tidying
# debris and holding a dimension that measured geometry which no longer existed.
#
# Step 2: a constraint drew ONE badge at the mean of its operands, so a Parallel
# between two lines put a single glyph in the space between them, belonging to
# neither. Fusion marks every operand.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m07_delete_badges: " + msg)
	return false


func _add_line(sk: Sketch, a: Vector2, b: Vector2) -> SketchLine:
	var pa := SketchPoint.make(a)
	pa.id = sk.next_id()
	var pb := SketchPoint.make(b)
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(
		_root.active_sketch_id, [pa, pb, l], []))
	return l


func _press_delete() -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_DELETE
	k.pressed = true
	_root.handle_app_key(k)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)

	# --- step 6: a dimensioned line deletes cleanly, debris and all.
	var line := _add_line(sk, Vector2(0, 40), Vector2(76.2, 40))
	var ops: Array[String] = [line.p0, line.p1]
	_root.add_constraint(SketchConstraint.make(
		SketchConstraint.Type.DISTANCE, ops, 76.2))
	if sk.constraints.is_empty():
		return _fail("no dimension was created")
	var before := sk.size()
	_root.set_selection([line.id])
	_press_delete()
	if sk.has(line.p0) or sk.has(line.p1):
		return _fail("deleting the line left its endpoints behind")
	if sk.has(line.id):
		return _fail("the line itself survived deletion")
	if not sk.constraints.is_empty():
		return _fail("the dimension outlived the geometry it measured: %d left"
			% sk.constraints.size())
	# One undo puts every bit of it back — deletion is still ONE step.
	_root.stack.undo()
	if sk.size() != before or sk.constraints.size() != 1:
		return _fail("undo did not restore the line, its points and its dimension")
	_root.stack.redo()

	# --- a SHARED point is not debris: it must survive if anything still uses it.
	var l1 := _add_line(sk, Vector2(0, 0), Vector2(50, 0))
	var l2id := sk.next_id()
	var far := SketchPoint.make(Vector2(50, 60))
	far.id = sk.next_id()
	var l2 := SketchLine.make(l1.p1, far.id)     # welded onto l1's end
	l2.id = l2id
	_root.stack.push_no_merge(CmdAddEntities.new(
		_root.active_sketch_id, [far, l2], []))
	_root.set_selection([l2.id])
	_press_delete()
	if not sk.has(l1.p1):
		return _fail("deleting a line took a point that another line still uses")
	if sk.has(far.id):
		return _fail("the deleted line's own free endpoint was left behind")

	# --- step 2: one badge PER OPERAND.
	_root.set_selection([])
	var lp1 := _add_line(sk, Vector2(-60, -40), Vector2(-10, -30))
	var lp2 := _add_line(sk, Vector2(-60, -70), Vector2(-10, -55))
	var pops: Array[String] = [lp1.id, lp2.id]
	var par := SketchConstraint.make(SketchConstraint.Type.PARALLEL, pops)
	var anchors := ConstraintOverlay.anchors_of(sk, par)
	if anchors.size() != 2:
		return _fail("Parallel produced %d badge anchors, want one per line"
			% anchors.size())
	# Each anchor must sit on ITS OWN line, not between the two.
	for i in 2:
		var l: SketchLine = lp1 if i == 0 else lp2
		var mid: Vector2 = (sk.point(l.p0).pos + sk.point(l.p1).pos) * 0.5
		var nearest := INF
		for a: Vector2 in anchors:
			nearest = minf(nearest, a.distance_to(mid))
		if nearest > 0.001:
			return _fail("no badge anchor sits on line %d" % i)

	print("M07_DELETE_BADGES OK: delete removes debris and stale dimensions, "
		+ "shared points survive, one badge per operand")
	return true
