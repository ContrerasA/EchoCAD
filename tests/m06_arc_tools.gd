extends SceneTree

# M6: arc tools driven through the ToolManager, and the drag+solve loop —
# dragging a line endpoint drags the tangent arc along, in ONE undo step.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m06_arc_tools: " + msg)
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


func _drag(from: Vector2, to: Vector2, steps := 6) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(from,
		_root.sketch_view.world_to_screen(from), down)
	for i in range(1, steps + 1):
		var w := from.lerp(to, float(i) / steps)
		_root.tools.handle_pointer_move(w,
			_root.sketch_view.world_to_screen(w), InputEventMouseMotion.new())
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(to, _root.sketch_view.world_to_screen(to), up)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# --- 3-point arc: start (0,-30), end (30,0), through (21.2,-21.2).
	_root.tools.set_active("arc3")
	_click(Vector2(0, -30))
	_click(Vector2(30, 0))
	_click(Vector2(21.2132034, -21.2132034))
	var arcs: Array = []
	for e in sk.entities():
		if e.kind() == "arc":
			arcs.append(e)
	if arcs.size() != 1:
		return _fail("3pt arc missing")
	var arc := arcs[0] as SketchArc
	if sk.point(arc.center).pos.distance_to(Vector2.ZERO) > 0.05:
		return _fail("3pt arc center wrong: %s" % sk.point(arc.center).pos)
	if not arc.ccw:
		return _fail("3pt arc winding wrong (through lower-right = ccw)")
	# One undo step.
	_root.stack.undo()
	# Back to a bare sketch: only its origin point remains.
	if sk.size() != 1:
		return _fail("3pt arc not one undo step")
	_root.stack.redo()

	# --- center arc: center (100,0), start (120,0), sweep upward to ~90deg.
	_root.tools.set_active("center_arc")
	_click(Vector2(100, 0))
	_click(Vector2(120, 0))
	# Move the cursor through a quarter turn so the sweep accumulates.
	for ang in [PI / 6.0, PI / 3.0, PI / 2.0]:
		var w := Vector2(100, 0) + Vector2(cos(ang), sin(ang)) * 20.0
		_root.tools.handle_pointer_move(w,
			_root.sketch_view.world_to_screen(w), InputEventMouseMotion.new())
	_click(Vector2(100, 0) + Vector2(cos(PI / 2.0), sin(PI / 2.0)) * 20.0)
	arcs.clear()
	for e in sk.entities():
		if e.kind() == "arc":
			arcs.append(e)
	if arcs.size() != 2:
		return _fail("center arc missing")
	var ca := arcs[1] as SketchArc
	if sk.point(ca.end).pos.distance_to(Vector2(100, 20)) > 0.05:
		return _fail("center arc end wrong: %s" % sk.point(ca.end).pos)
	if not ca.ccw:
		return _fail("center arc winding wrong")

	# --- tangent arc off a line end + drag follows.
	_root.tools.set_active("line")
	_click(Vector2(-100, 50))
	_click(Vector2(-60, 50))
	_root.tools.handle_cancel()
	var line: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e
	_root.tools.set_active("tangent_arc")
	_click(Vector2(-60, 50))          # snaps to the line's end point
	_click(Vector2(-40, 70))          # arc end
	arcs.clear()
	for e in sk.entities():
		if e.kind() == "arc":
			arcs.append(e)
	if arcs.size() != 3:
		return _fail("tangent arc missing")
	var ta := arcs[2] as SketchArc
	var con_types: Array = []
	for c in sk.constraints:
		con_types.append(SketchConstraint.Type.keys()[c.type])
	if not con_types.has("TANGENT"):
		return _fail("tangent arc constraints missing: %s" % str(con_types))
	# The arc's start is WELDED to the line's endpoint — one shared point, not
	# a twin held by a Coincident. The twin was what made this case unstable:
	# the rigid ride-along, the tangency projection and the Coincident each
	# undid the others, so the solve never converged and a few mm of drag threw
	# the arc's centre metres away. Sharing the point removes the contradiction.
	if ta.start != line.p0 and ta.start != line.p1:
		return _fail("tangent arc start not welded to the line endpoint")
	# Geometry: center must sit on the normal of the line at the start point
	# (tangency), i.e. center.x == start.x for a horizontal line.
	var t_center: Vector2 = sk.point(ta.center).pos
	if absf(t_center.x - (-60.0)) > 0.01:
		return _fail("tangent arc center not on normal: %s" % t_center)

	# --- drag the line's free end: the tangent arc's start follows the
	# coincident constraint, tangency re-solves, all ONE undo step.
	var snap_json := JSON.stringify(_root.doc.to_dict())
	_root.tools.set_active("select")
	var free_end := sk.point(line.p0)   # (-100, 50)
	_drag(free_end.pos, Vector2(-100, 30), 8)
	var arc_start := sk.point(ta.start).pos
	var line_end := sk.point(line.p1).pos
	if arc_start.distance_to(line_end) > 0.01:
		return _fail("coincident broke under drag: %s vs %s"
			% [arc_start, line_end])
	# Tangency still holds: distance from center to the line == radius.
	var la2 := sk.point(line.p0).pos
	var lb2 := sk.point(line.p1).pos
	var d := (lb2 - la2).normalized()
	var n := Vector2(-d.y, d.x)
	var center2 := sk.point(ta.center).pos
	var r2 := center2.distance_to(sk.point(ta.start).pos)
	if absf(absf(n.dot(center2 - la2)) - r2) > 0.05:
		return _fail("tangency broke under drag")
	# One undo step returns the document to the pre-drag snapshot.
	_root.stack.undo()
	if JSON.stringify(_root.doc.to_dict()) != snap_json:
		return _fail("drag + solve was not one undo step")

	print("M06_ARC_TOOLS OK: 3pt/center/tangent arcs, drag re-solve, one-step undo")
	return true
