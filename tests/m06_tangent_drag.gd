extends SceneTree

# M6 QA step 4 regression: build a tangent arc off a line end THROUGH THE REAL
# TOOLS, then drag the line's free end. The arc must follow while keeping its
# radius and its tangency; the solve must converge rather than run out of
# rounds. Before the fix a 5 mm drag sent the arc's centre 1.7 m away and left
# tangency WORSE than it started.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m06_tangent_drag: " + msg)
	return false


func _click(w: Vector2) -> void:
	var s: Vector2 = _root.sketch_view.world_to_screen(w)
	_root.tools.handle_pointer_move(w, s, InputEventMouseMotion.new())
	var d := InputEventMouseButton.new()
	d.button_index = MOUSE_BUTTON_LEFT
	d.pressed = true
	_root.tools.handle_pointer_down(w, s, d)
	var u := InputEventMouseButton.new()
	u.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(w, s, u)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	_root.tools.set_active("line")
	_click(Vector2(-60, 40))
	_click(Vector2(0, 20))
	_root.tools.handle_cancel()
	_root.tools.set_active("tangent_arc")
	_click(Vector2(0, 20))
	_click(Vector2(-40, 80))

	var line: SketchLine = null
	var arc: SketchArc = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e
		elif e.kind() == "arc":
			arc = e
	if line == null or arc == null:
		return _fail("tangent arc was not built")
	# Welded, not twinned: one point serves as both the line end and arc start.
	if arc.start != line.p1:
		return _fail("arc start not welded to the line endpoint")
	var tangent: SketchConstraint = null
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.TANGENT:
			tangent = c
	if tangent == null:
		return _fail("no TANGENT constraint")
	if ConstraintSolver.error_of(sk, tangent) > 1e-4:
		return _fail("not tangent as built")

	var r0: float = sk.point(arc.center).pos.distance_to(sk.point(arc.start).pos)
	var free_id := line.p0
	# Drag the free end down 1 mm at a time, as a real gesture's per-frame
	# solves do, and check the invariants after EVERY step.
	for i in range(1, 9):
		sk.point(free_id).pos = Vector2(-60, 40.0 - float(i))
		var res := ConstraintSolver.solve(sk, [free_id])
		if bool(res.get("diverged", false)):
			return _fail("solve diverged at step %d" % i)
		var pts: Dictionary = res["points"]
		for id: String in pts:
			sk.point(id).pos = pts[id]
		# Converged, rather than burning every round without settling.
		if int(res["rounds"]) >= ConstraintSolver.MAX_ROUNDS:
			return _fail("step %d did not converge (%d rounds)"
				% [i, int(res["rounds"])])
		var err := ConstraintSolver.error_of(sk, tangent)
		if err > 0.01:
			return _fail("tangency lost at step %d: err %f" % [i, err])
		var r: float = sk.point(arc.center).pos.distance_to(sk.point(arc.start).pos)
		if absf(r - r0) > 0.5:
			return _fail("radius drifted at step %d: %f (was %f)" % [i, r, r0])
		# The centre must track the line, not fly off. Its true position is on
		# the line's normal through the weld point, one radius out.
		var c: Vector2 = sk.point(arc.center).pos
		if c.length() > 500.0:
			return _fail("arc centre ran away at step %d: %s" % [i, str(c)])

	print("M06_TANGENT_DRAG OK: welded start, tangency and radius hold under "
		+ "drag, solve converges")
	return true
