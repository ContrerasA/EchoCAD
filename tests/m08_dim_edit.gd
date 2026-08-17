extends SceneTree

# M8 QA step 5 regression: editing an EXISTING dimension by selecting its label
# and typing. This whole path was dead — Enter was intercepted by AppRoot and
# routed to the tool's `commit` instead of its `key_input`, so the typed digits
# were collected and then silently thrown away. Also covers unit suffixes and
# expression math in the field, both of which were filtered out before reaching
# the parser.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m08_dim_edit: " + msg)
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


## Type `text` then Enter, through AppRoot's key routing — the same path the
## real keyboard takes, which is where the bug lived.
func _type_enter(text: String) -> void:
	for ch in text:
		var k := InputEventKey.new()
		k.unicode = ch.unicode_at(0)
		k.pressed = true
		_root.handle_app_key(k)
	var e := InputEventKey.new()
	e.keycode = KEY_ENTER
	e.pressed = true
	_root.handle_app_key(e)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# A 3 in line, dimensioned with the real tool.
	_root.tools.set_active("line")
	_click(Vector2(0, 40))
	_click(Vector2(76.2, 40))
	_root.tools.handle_cancel()
	var line: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e
	_root.tools.set_active("dimension")
	_click(Vector2(38, 40))
	_click(Vector2(38, 65))

	var di := -1
	for i in sk.constraints.size():
		if sk.constraints[i].is_dimensional():
			di = i
	if di < 0:
		return _fail("smart dimension created no dimensional constraint")
	if absf(sk.constraints[di].value - 76.2) > 0.01:
		return _fail("dimension did not measure the line: %f"
			% sk.constraints[di].value)

	# Select the dimension and drive it by typing. Selecting via the app's own
	# field rather than a synthetic label click keeps this test about the KEY
	# routing, which is what broke.
	_root.tools.set_active("select")
	_root.selected_constraint = di

	var cases := [
		["2.5", 63.5],        # bare number reads in the display unit (inch)
		["10mm", 10.0],       # explicit unit suffix
		["1.5in", 38.1],      # the other suffix
		["2*1.25", 63.5],     # expression math, in display units
	]
	for case: Array in cases:
		var text: String = case[0]
		var want: float = case[1]
		_type_enter(text)
		var got: float = sk.constraints[di].value
		if absf(got - want) > 0.01:
			return _fail("typing '%s' gave %f mm, want %f" % [text, got, want])
		# The geometry must actually follow the dimension, not just the label.
		var length: float = sk.point(line.p0).pos.distance_to(sk.point(line.p1).pos)
		if absf(length - want) > 0.05:
			return _fail("'%s' drove the label but not the line (%f vs %f)"
				% [text, length, want])

	print("M08_DIM_EDIT OK: label edit drives geometry, units and expressions "
		+ "accepted")
	return true
