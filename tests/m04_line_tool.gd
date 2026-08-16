extends SceneTree

# M4: line tool chains, snapping, and Fusion-style inference — driven through
# the ToolManager exactly as the input layer drives it.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m04_line_tool: " + msg)
	return false


func _click(world: Vector2) -> void:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	var move := InputEventMouseMotion.new()
	_root.tools.handle_pointer_move(world, screen, move)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(world, screen, down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(world, screen, up)


func _kinds(sk: Sketch) -> Dictionary:
	var out := {}
	for e in sk.entities():
		out[e.kind()] = out.get(e.kind(), 0) + 1
	return out


func _last_line(sk: Sketch) -> SketchLine:
	var out: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			out = e
	return out


func _con_types(sk: Sketch) -> Array:
	var out: Array = []
	for c in sk.constraints:
		out.append(SketchConstraint.Type.keys()[c.type])
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	# Grid off for exact-coordinate cases; snap tol at zoom 4 = 2 mm.
	_root.snap.grid_enabled = false

	# --- 3-segment chain: 4 points, 3 lines, interior points SHARED.
	# Deliberately started clear of (0,0): the sketch origin is a real point
	# there now, and a click on it would (correctly) weld to it, which is a
	# different case than the chain census being measured here.
	_root.tools.set_active("line")
	_click(Vector2(0, 100))
	_click(Vector2(50, 101))      # near-horizontal -> inferred H, y snaps to 100
	_click(Vector2(50.5, 140))    # near-vertical -> inferred V, x snaps to 50
	_click(Vector2(80, 170))      # oblique -> no axis constraint
	_root.tools.handle_cancel()   # end chain

	var kinds := _kinds(sk)
	# +1 point: every sketch owns an origin point at (0,0).
	if kinds.get("line", 0) != 3 or kinds.get("point", 0) != 5:
		return _fail("chain census wrong: %s" % str(kinds))
	var cons := _con_types(sk)
	if cons != ["HORIZONTAL", "VERTICAL"]:
		return _fail("inferred constraints wrong: %s" % str(cons))
	# Inference snapped the actual geometry too.
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line":
			lines.append(e)
	var l0 := lines[0] as SketchLine
	if sk.point(l0.p1).pos != Vector2(50, 100):
		return _fail("H inference did not snap y: %s" % str(sk.point(l0.p1).pos))
	var l1 := lines[1] as SketchLine
	if sk.point(l1.p1).pos.x != 50.0:
		return _fail("V inference did not snap x")
	# Interior points shared: line0.p1 == line1.p0.
	if l0.p1 != l1.p0:
		return _fail("chain did not share interior point")

	# --- undo granularity: one step per segment.
	var before := sk.size()
	_root.stack.undo()
	if sk.size() != before - 2:   # last segment = 1 point + 1 line
		return _fail("undo did not remove exactly one segment")
	_root.stack.redo()

	# --- WELDING. A click on an existing point does not make a twin point
	# tied by a Coincident constraint — it REUSES that point, so both lines
	# genuinely share one solver variable and a later drag moves both. (The
	# old behaviour asserted a COINCIDENT here; it was the bug: two points
	# that merely tended to agree came apart under a drag.)
	var target_id := l0.p1
	var target: SketchPoint = sk.point(target_id)
	var target_pos := target.pos
	var cons_before := _con_types(sk).count("COINCIDENT")
	var pts_before: int = _kinds(sk).get("point", 0)

	# Chain STARTING on an existing point welds too.
	_click(target_pos + Vector2(0.5, 0.5))   # within tol -> point snap
	_click(target_pos + Vector2(30, 25))
	_root.tools.handle_cancel()
	var started: SketchLine = _last_line(sk)
	if started.p0 != target_id:
		return _fail("chain start did not weld onto the snapped point")

	# Chain ENDING on an existing point welds as well.
	_click(Vector2(-20, -20))
	_click(target_pos + Vector2(0.4, -0.4))
	_root.tools.handle_cancel()
	var ended: SketchLine = _last_line(sk)
	if ended.p1 != target_id:
		return _fail("chain end did not weld onto the snapped point")
	# Welding shares a point; it must NOT invent constraints to fake it.
	if _con_types(sk).count("COINCIDENT") != cons_before:
		return _fail("welding created a Coincident instead of sharing the point")
	# Two 2-click chains = 4 endpoints, of which 2 welded onto the existing
	# point. So exactly 2 new points, not 4 — that difference IS the weld.
	if _kinds(sk).get("point", 0) != pts_before + 2:
		return _fail("welding minted duplicate points")
	# The shared point is untouched — welding must not move existing geometry.
	if sk.point(target_id).pos != target_pos:
		return _fail("welding moved the point it welded onto")

	# --- Esc mid-gesture leaves the model unchanged.
	var census_before := sk.size()
	_click(Vector2(200, 200))     # first click arms the chain, nothing committed
	_root.tools.handle_cancel()
	if sk.size() != census_before:
		return _fail("Esc after first click left debris")

	# --- grid snap: with grid on, a lone click lands on a grid intersection.
	_root.snap.grid_enabled = true
	var step: float = _root.sketch_view.grid_step_mm()
	_root.tools.set_active("point")
	_click(Vector2(step * 2.3, step * 0.6))
	var pts: Array = []
	for e in sk.entities():
		if e.kind() == "point":
			pts.append(e)
	var placed: SketchPoint = pts[pts.size() - 1]
	var expected := Vector2(roundf(2.3) * step, roundf(0.6) * step)
	if placed.pos.distance_to(expected) > 1e-6:
		return _fail("grid snap wrong: %s expected %s" % [placed.pos, expected])

	# --- inference toggle off: no axis constraint inferred.
	_root.prefs["inference"] = false
	_root.snap.grid_enabled = false
	var ncons_before := sk.constraints.size()
	_root.tools.set_active("line")
	_click(Vector2(300, 300))
	_click(Vector2(350, 300.8))   # near-horizontal
	_root.tools.handle_cancel()
	if sk.constraints.size() != ncons_before:
		return _fail("inference ran while disabled")

	# --- select tool: click selects, drag moves a point.
	_root.prefs["inference"] = true
	_root.tools.set_active("select")
	_click(placed.pos)
	if not _root.selection.has(placed.id):
		return _fail("click did not select point")
	var screen0: Vector2 = _root.sketch_view.world_to_screen(placed.pos)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(placed.pos, screen0, down)
	var mm := InputEventMouseMotion.new()
	var target2 := placed.pos + Vector2(10, 6)
	_root.tools.handle_pointer_move(target2,
		_root.sketch_view.world_to_screen(target2), mm)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(target2,
		_root.sketch_view.world_to_screen(target2), up)
	if placed.pos.distance_to(target2) > 1e-6:
		return _fail("drag did not move point: %s" % str(placed.pos))
	_root.stack.undo()
	if placed.pos.distance_to(Vector2(roundf(2.3) * step, roundf(0.6) * step)) > 1e-6:
		return _fail("drag undo wrong")

	print("M04_LINE_TOOL OK: chain, inference H/V/coincident, grid, esc, select-drag")
	return true
