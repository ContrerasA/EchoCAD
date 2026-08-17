extends SceneTree

# QA §M17-5 follow-ups. Applying a constraint should move POINTS onto it,
# not resize circles: the free solve split a Point-On residual between the
# point and the circle's radius, visibly inflating the circle on apply.
# The apply-time solve now pins radii first and only frees them when the
# system genuinely needs a radius (a driving RADIUS dimension still works).

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
	push_error("m17_apply_prefer_points: " + msg)
	return false


func _pt(sk: Sketch, p: Vector2) -> String:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	sk.add(e)
	return e.id


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var sid := _root.create_sketch("XY")
	var sk: Sketch = _root.doc.sketch_feature(sid).sketch
	_root.snap.grid_enabled = false

	# --- Point-On applied to a free point moves the POINT, never the circle.
	var cc := _pt(sk, Vector2(5, 5))
	var circ := SketchCircle.make(cc, 20.0)
	circ.id = sk.next_id()
	sk.add(circ)
	var rider := _pt(sk, Vector2(40, 30))
	_root.set_selection([rider, circ.id])
	var why := _root.apply_constraint(SketchConstraint.Type.POINT_ON)
	if why != "":
		return _fail("point-on refused: " + why)
	await _idle()
	if absf((sk.entity(circ.id) as SketchCircle).radius - 20.0) > 1e-6:
		return _fail("apply inflated the circle: r=%f"
			% (sk.entity(circ.id) as SketchCircle).radius)
	var d := sk.point(rider).pos.distance_to(sk.point(cc).pos)
	if absf(d - 20.0) > 0.01:
		return _fail("rider not moved onto the circle (dist %f)" % d)
	# The center stays put: only the under-constrained rider absorbs it.
	if sk.point(cc).pos.distance_to(Vector2(5, 5)) > 0.01:
		return _fail("circle center moved on apply: %s" % str(sk.point(cc).pos))

	# --- A driving RADIUS dimension still resizes the circle (the fallback
	# path: pinning every radius cannot satisfy it, so the free solve runs).
	_root.set_selection([circ.id])
	why = _root.apply_constraint(SketchConstraint.Type.RADIUS, 30.0)
	if why != "":
		return _fail("radius dim refused: " + why)
	await _idle()
	if absf((sk.entity(circ.id) as SketchCircle).radius - 30.0) > 0.01:
		return _fail("radius dimension did not drive the circle: r=%f"
			% (sk.entity(circ.id) as SketchCircle).radius)
	# The rider follows its circle outward.
	d = sk.point(rider).pos.distance_to(sk.point(cc).pos)
	if absf(d - 30.0) > 0.01:
		return _fail("rider left the circle after radius drive (dist %f)" % d)

	# --- One undo step per apply, and undo restores the radius.
	_root.stack.undo()
	await _idle()
	if absf((sk.entity(circ.id) as SketchCircle).radius - 20.0) > 0.01:
		return _fail("undo did not restore the radius: r=%f"
			% (sk.entity(circ.id) as SketchCircle).radius)

	print("M17_APPLY_PREFER_POINTS OK: point-on moves the point, radius "
		+ "dims still drive, one undo step per apply")
	return true
