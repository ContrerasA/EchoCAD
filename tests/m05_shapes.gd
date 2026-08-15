extends SceneTree

# M5: rectangle (2-pt + center), circle (center-radius + 3-point), type-in
# dimension fields, undo granularity.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m05_shapes: " + msg)
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


func _type(text: String) -> void:
	var tool := _root.tools.get_tool(_root.tools.active_id())
	for ch in text:
		var e := InputEventKey.new()
		if ch == "\t":
			e.keycode = KEY_TAB
		else:
			e.unicode = ch.unicode_at(0)
		tool.key_input(e)


func _press_enter() -> void:
	var tool := _root.tools.get_tool(_root.tools.active_id())
	var e := InputEventKey.new()
	e.keycode = KEY_ENTER
	tool.key_input(e)


func _census(sk: Sketch) -> Dictionary:
	var out := {}
	for e in sk.entities():
		out[e.kind()] = out.get(e.kind(), 0) + 1
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# --- 2-point rect by clicks: census + H/V + geometry.
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 25))
	var c := _census(sk)
	if c.get("point", 0) != 4 or c.get("line", 0) != 4:
		return _fail("rect census wrong: %s" % str(c))
	var types: Array = []
	for con in sk.constraints:
		types.append(SketchConstraint.Type.keys()[con.type])
	types.sort()
	if types != ["HORIZONTAL", "HORIZONTAL", "VERTICAL", "VERTICAL"]:
		return _fail("rect constraints wrong: %s" % str(types))
	# Corners share points: exactly 4 points, each line endpoint reused twice.
	var refcount := {}
	for e in sk.entities():
		for pid in e.point_refs():
			refcount[pid] = refcount.get(pid, 0) + 1
	for pid: String in refcount:
		if refcount[pid] != 2:
			return _fail("corner sharing wrong: %s" % str(refcount))
	# One undo step removes the whole rect.
	_root.stack.undo()
	if sk.size() != 0:
		return _fail("rect not one undo step")
	_root.stack.redo()

	# --- typed rect: 2in x 1in exactly (Fusion type-in, Tab between).
	_root.tools.set_active("rect")
	_click(Vector2(100, 100))
	_root.tools.handle_pointer_move(Vector2(120, 115),
		_root.sketch_view.world_to_screen(Vector2(120, 115)),
		InputEventMouseMotion.new())
	_type("2")
	_type("\t")
	_type("1")
	_press_enter()
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line" and sk.index_of(e.id) >= 8:
			lines.append(e)
	if lines.size() != 4:
		return _fail("typed rect missing")
	var bottom := lines[0] as SketchLine
	var w := sk.point(bottom.p1).pos.x - sk.point(bottom.p0).pos.x
	var right := lines[1] as SketchLine
	var h := sk.point(right.p1).pos.y - sk.point(right.p0).pos.y
	if absf(w - 50.8) > 1e-4 or absf(h - 25.4) > 1e-4:
		return _fail("typed rect size wrong: %f x %f" % [w, h])

	# --- center rect: 30 wide, 20 tall around (0, -50) by clicks.
	_root.tools.set_active("center_rect")
	_click(Vector2(0, -50))
	_click(Vector2(15, -40))
	var xs: Array = []
	var ys: Array = []
	for e in sk.entities():
		if e.kind() == "point" and sk.index_of(e.id) >= 16:
			xs.append((e as SketchPoint).pos.x)
			ys.append((e as SketchPoint).pos.y)
	xs.sort()
	ys.sort()
	if xs[0] != -15.0 or xs[3] != 15.0 or ys[0] != -60.0 or ys[3] != -40.0:
		return _fail("center rect corners wrong: %s %s" % [str(xs), str(ys)])

	# --- circle: click center + typed radius.
	_root.tools.set_active("circle")
	_click(Vector2(80, -30))
	_type("0.5")
	_press_enter()
	var circles: Array = []
	for e in sk.entities():
		if e.kind() == "circle":
			circles.append(e)
	if circles.size() != 1:
		return _fail("circle missing")
	var ci := circles[0] as SketchCircle
	if absf(ci.radius - 12.7) > 1e-4:
		return _fail("typed radius wrong: %f" % ci.radius)
	if sk.point(ci.center).pos != Vector2(80, -30):
		return _fail("circle center wrong")

	# --- 3-point circle through (0,0), (20,0), (10,10) -> center (10,0) r=10...
	# circumcircle of those: center (10, 0)? |(10,0)-(0,0)|=10, |(10,0)-(10,10)|=10. yes.
	_root.tools.set_active("circle3")
	_click(Vector2(200, 0))
	_click(Vector2(220, 0))
	_click(Vector2(210, 10))
	circles.clear()
	for e in sk.entities():
		if e.kind() == "circle":
			circles.append(e)
	if circles.size() != 2:
		return _fail("3pt circle missing")
	var c3 := circles[1] as SketchCircle
	if sk.point(c3.center).pos.distance_to(Vector2(210, 0)) > 1e-4 \
			or absf(c3.radius - 10.0) > 1e-4:
		return _fail("3pt circle wrong: c=%s r=%f"
			% [sk.point(c3.center).pos, c3.radius])

	# --- Esc cancels an armed shape without debris.
	var n := sk.size()
	_root.tools.set_active("circle")
	_click(Vector2(300, 300))
	_root.tools.handle_cancel()
	if sk.size() != n:
		return _fail("Esc left debris")

	print("M05_SHAPES OK: rect 2pt/center/typed, circle typed/3pt, undo, esc")
	return true
