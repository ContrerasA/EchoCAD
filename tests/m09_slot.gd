extends SceneTree

# M9: slot tool — all three variants: census, key measures, typed width,
# one undo step, and slot-stays-a-slot under dimension driving.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m09_slot: " + msg)
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


func _type_commit(text: String) -> void:
	var tool := _root.tools.get_tool(_root.tools.active_id())
	for ch in text:
		var e := InputEventKey.new()
		e.unicode = ch.unicode_at(0)
		tool.key_input(e)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	tool.key_input(enter)


## Counts AUTHORED geometry: the sketch's own origin point is scaffolding
## every sketch has, not something a tool produced, so it is excluded here.
func _census(sk: Sketch, from_index: int) -> Dictionary:
	var out := {}
	for e in sk.entities():
		if sk.is_origin(e.id):
			continue
		if sk.index_of(e.id) >= from_index:
			out[e.kind()] = out.get(e.kind(), 0) + 1
	return out


## The slot committed after entity index `from`: {centers: [a, b], r: float}
func _slot_measures(sk: Sketch, from_index: int) -> Dictionary:
	var arcs: Array = []
	for e in sk.entities():
		if e.kind() == "arc" and sk.index_of(e.id) >= from_index:
			arcs.append(e)
	var a := arcs[0] as SketchArc
	var b := arcs[1] as SketchArc
	var ca: Vector2 = sk.point(a.center).pos
	var cb: Vector2 = sk.point(b.center).pos
	return {"a": ca, "b": cb,
		"r": ca.distance_to(sk.point(a.start).pos)}


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# --- center-to-center by clicks: A(-30,0) B(30,0), width from cursor 10
	# above the axis -> width 20.
	_root.tools.set_active("slot")
	_click(Vector2(-30, 0))
	_click(Vector2(30, 0))
	_click(Vector2(0, 10))
	var c := _census(sk, 0)
	if c.get("point", 0) != 6 or c.get("line", 0) != 2 or c.get("arc", 0) != 2:
		return _fail("slot census wrong: %s" % str(c))
	var types: Array = []
	for con in sk.constraints:
		types.append(SketchConstraint.Type.keys()[con.type])
	types.sort()
	if types != ["EQUAL", "TANGENT", "TANGENT", "TANGENT", "TANGENT"]:
		return _fail("slot constraints wrong: %s" % str(types))
	var m := _slot_measures(sk, 0)
	if (m["a"] as Vector2).distance_to(Vector2(-30, 0)) > 0.001 \
			or (m["b"] as Vector2).distance_to(Vector2(30, 0)) > 0.001:
		return _fail("slot centers wrong")
	if absf(float(m["r"]) - 10.0) > 0.001:
		return _fail("slot radius wrong: %f" % float(m["r"]))
	# One undo step.
	_root.stack.undo()
	# Back to a bare sketch: only its origin point remains.
	if sk.size() != 1:
		return _fail("slot not one undo step")
	_root.stack.redo()
	var n0 := sk.size()

	# --- overall variant with TYPED width: ends at x=-80/-20 -> centers
	# inset by w/2 (w=0.5in=12.7 -> centers -73.65 / -26.35).
	_root.tools.set_active("slot_overall")
	_click(Vector2(-80, 40))
	_click(Vector2(-20, 40))
	_root.tools.handle_pointer_move(Vector2(-50, 45),
		_root.sketch_view.world_to_screen(Vector2(-50, 45)),
		InputEventMouseMotion.new())
	_type_commit("0.5")
	var m2 := _slot_measures(sk, n0)
	if absf(float(m2["r"]) - 6.35) > 0.001:
		return _fail("overall typed width wrong: %f" % float(m2["r"]))
	if (m2["a"] as Vector2).distance_to(Vector2(-73.65, 40)) > 0.001 \
			or (m2["b"] as Vector2).distance_to(Vector2(-26.35, 40)) > 0.001:
		return _fail("overall centers wrong: %s %s" % [m2["a"], m2["b"]])
	var n1 := sk.size()

	# --- center-point variant: midpoint (60,-40), end center (80,-40) ->
	# other center mirrored to (40,-40).
	_root.tools.set_active("slot_center")
	_click(Vector2(60, -40))
	_click(Vector2(80, -40))
	_click(Vector2(70, -34))     # width 12
	var m3 := _slot_measures(sk, n1)
	var got := [m3["a"], m3["b"]]
	var want_a := Vector2(80, -40)
	var want_b := Vector2(40, -40)
	if (got[0] as Vector2).distance_to(want_a) > 0.001 \
			or (got[1] as Vector2).distance_to(want_b) > 0.001:
		return _fail("center-point centers wrong: %s" % str(got))
	if absf(float(m3["r"]) - 6.0) > 0.001:
		return _fail("center-point width wrong: %f" % float(m3["r"]))

	# --- slot deforms as a slot: drive the first slot's center distance.
	var arcs: Array = []
	for e in sk.entities():
		if e.kind() == "arc" and sk.index_of(e.id) < n0:
			arcs.append(e)
	var arc_a := arcs[0] as SketchArc
	var arc_b := arcs[1] as SketchArc
	var ops: Array[String] = [arc_a.center, arc_b.center]
	_root.add_constraint(SketchConstraint.make(
		SketchConstraint.Type.DISTANCE, ops, 80.0))
	var m4 := _slot_measures(sk, 0)
	if absf((m4["a"] as Vector2).distance_to(m4["b"]) - 80.0) > 0.01:
		return _fail("center distance did not drive")
	# Tangency held: side lines still touch both arcs.
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line" and sk.index_of(e.id) < n0:
			lines.append(e)
	for l: SketchLine in lines:
		var a: Vector2 = sk.point(l.p0).pos
		var b: Vector2 = sk.point(l.p1).pos
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		for arc: SketchArc in [arc_a, arc_b]:
			var cc: Vector2 = sk.point(arc.center).pos
			var rr := cc.distance_to(sk.point(arc.start).pos)
			if absf(absf(nrm.dot(cc - a)) - rr) > 0.05:
				return _fail("tangency broke when driving the slot")
	# Equal radii held.
	var ra := (sk.point(arc_a.center).pos).distance_to(sk.point(arc_a.start).pos)
	var rb := (sk.point(arc_b.center).pos).distance_to(sk.point(arc_b.start).pos)
	if absf(ra - rb) > 0.01:
		return _fail("equal radii broke")

	print("M09_SLOT OK: 3 variants, typed width, one-step undo, drives as a slot")
	return true
