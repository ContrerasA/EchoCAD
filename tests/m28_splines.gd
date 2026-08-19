extends SceneTree

# M28: sketch splines — tool commit (one undo step), interpolation, G1
# continuity, tessellation accuracy, handle overrides (+ undo), closed
# splines as profiles -> extrude, DXF export, serialization.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m28_splines: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


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


func _dist_to_poly(poly: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	for i in poly.size() - 1:
		var q := SketchGeometry.closest_on_segment(p, poly[i], poly[i + 1])
		best = minf(best, q.distance_to(p))
	return best


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false

	# --- draw an open spline through 4 fit points, Enter to finish --------
	# Away from the origin: a click at (0,0) would weld onto the origin point
	# and change the entity census this test counts.
	var fits: Array = [Vector2(5, 3), Vector2(25, 21), Vector2(50, -2),
		Vector2(75, 13)]
	_root.tools.set_active("spline")
	for f in fits:
		_click(f)
	if not _root.tools.handle_commit():
		return _fail("Enter did not commit the spline")
	var sp: SketchSpline = null
	for e in sk.entities():
		if e.kind() == "spline":
			sp = e
	if sp == null:
		return _fail("no spline entity after commit")
	if sp.points.size() != 4 or sp.closed:
		return _fail("spline has wrong fit points / closed flag")

	# One undo step removes the whole curve (points + entity).
	var n := sk.size()
	_root.stack.undo()
	if sk.size() != n - 5:
		return _fail("undo did not remove spline + its 4 points in one step")
	_root.stack.redo()
	sp = null
	for e in sk.entities():
		if e.kind() == "spline":
			sp = e
	if sp == null:
		return _fail("redo did not restore the spline")

	# --- interpolation + tessellation ------------------------------------
	var poly := sp.polyline(sk)
	if poly.size() < 8:
		return _fail("tessellation suspiciously coarse (%d)" % poly.size())
	if poly[0].distance_to(fits[0]) > 1e-6 \
			or poly[poly.size() - 1].distance_to(fits[3]) > 1e-6:
		return _fail("polyline does not start/end at the end fit points")
	for f in fits:
		if _dist_to_poly(poly, f) > 0.02:
			return _fail("curve does not pass through fit point %s" % str(f))
	# Chord error: midpoints of the exact bezier lie within tolerance.
	for i in sp.span_count():
		var cp := sp.span(sk, i)
		var mid: Vector2 = cp[0] * 0.125 + cp[1] * 0.375 + cp[2] * 0.375 \
			+ cp[3] * 0.125
		if _dist_to_poly(poly, mid) > SketchSpline.FLAT_TOL * 1.5:
			return _fail("tessellation misses the curve at span %d" % i)

	# --- G1 continuity at interior fit points ------------------------------
	for i in range(0, sp.span_count() - 1):
		var a := sp.span(sk, i)
		var b := sp.span(sk, i + 1)
		if (a[3] as Vector2).distance_to(b[0]) > 1e-9:
			return _fail("spans disconnected at joint %d" % i)
		var din: Vector2 = (a[3] - a[2]).normalized()
		var dout: Vector2 = (b[1] - b[0]).normalized()
		if din.dot(dout) < 0.9999:
			return _fail("tangent break at joint %d" % i)

	# --- fit points are real solver points --------------------------------
	var fp1 := String(sp.points[1])
	var err := _root.apply_constraint(SketchConstraint.Type.FIX)   # none sel
	_root.set_selection([fp1])
	err = _root.apply_constraint(SketchConstraint.Type.FIX)
	if err != "":
		return _fail("FIX on a fit point refused: " + err)
	_root.set_selection([])

	# --- handle override + undo -------------------------------------------
	var before := sp.polyline(sk)
	_root.stack.push_no_merge(CmdSetSplineHandle.new(_root.active_sketch_id,
		sp.id, 1, Vector2(30, 0)))
	var after := sp.polyline(sk)
	if before == after:
		return _fail("handle override did not change the curve")
	if not (sp.handles[1] is Vector2):
		return _fail("handle override not stored")
	_root.stack.undo()
	if sp.handles[1] is Vector2:
		return _fail("undo did not clear the handle override")

	# --- serialization round trip -----------------------------------------
	_root.stack.push_no_merge(CmdSetSplineHandle.new(_root.active_sketch_id,
		sp.id, 2, Vector2(-8, 12)))
	var d := sk.to_dict()
	var sk2 := Sketch.from_dict(d)
	var sp2: SketchSpline = null
	for e in sk2.entities():
		if e.kind() == "spline":
			sp2 = e
	if sp2 == null or sp2.points != sp.points or sp2.closed != sp.closed:
		return _fail("spline lost in serialization")
	if not (sp2.handles[2] is Vector2) \
			or (sp2.handles[2] as Vector2).distance_to(Vector2(-8, 12)) > 1e-9:
		return _fail("handle override lost in serialization")

	# --- DXF export writes the tessellation as a polyline ------------------
	var dxf := DxfExporter.to_dxf(sk)
	if not dxf.contains("POLYLINE"):
		return _fail("DXF export has no POLYLINE for the spline")

	# --- closed spline is a profile; extrude it ---------------------------
	_root.finish_sketch()
	await _idle()
	var f2 := _root.create_sketch("XY")
	var sk3: Sketch = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("spline")
	var ring: Array = [Vector2(120, 0), Vector2(150, 8), Vector2(160, 35),
		Vector2(130, 42), Vector2(110, 25)]
	for f in ring:
		_click(f)
	_click(ring[0])   # close onto the first fit point
	var sp3: SketchSpline = null
	for e in sk3.entities():
		if e.kind() == "spline":
			sp3 = e
	if sp3 == null or not sp3.closed:
		return _fail("clicking the first point did not close the spline")
	var profs := ProfileFinder.profiles(sk3)
	if profs.size() != 1:
		return _fail("closed spline did not yield one profile (%d)"
			% profs.size())
	var area: float = profs[0]["area"]
	if area <= 0.0:
		return _fail("profile area not positive")
	_root.finish_sketch()
	await _idle()
	var eid := _root.extrude(f2, Vector2(135, 20), 10.0)
	if eid == "":
		return _fail("extrude refused the spline profile")
	await _idle()
	var ef := _root.doc.feature_by_id(eid) as ExtrudeFeature
	var vol := ExtrudeFeature.mesh_volume(ef.build_mesh(_root.doc))
	if absf(vol - area * 10.0) > area * 10.0 * 0.02:
		return _fail("extrude volume %f vs area*depth %f" % [vol, area * 10.0])

	print("M28_SPLINES OK: tool commit/undo, interpolation, G1, handles, ",
		"serialization, DXF, closed-spline extrude")
	return true
