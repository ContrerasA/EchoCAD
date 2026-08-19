extends SceneTree

# M29: rectangular + circular sketch patterns (constraint cloning, one undo
# step), sketch chamfer (corner surgery like fillet), polygon tool
# (constrained regular n-gon), partial-angle step math.

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
	push_error("m29_sketch_patterns: " + msg)
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


func _kinds(sk: Sketch, kind: String) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e.kind() == kind:
			out.append(e)
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2(60, 20), 3.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false

	# --- source rect -------------------------------------------------------
	_root.tools.set_active("rect")
	_click(Vector2(5, 5))
	_click(Vector2(25, 20))
	var src_lines := _kinds(sk, "line")
	if src_lines.size() != 4:
		return _fail("rect did not make 4 lines")
	var n_cons_src := sk.constraints.size()
	if n_cons_src < 4:
		return _fail("rect has too few constraints (%d)" % n_cons_src)

	# --- rectangular pattern: 3 cols x 2 rows via typed fields -------------
	var ids: Array = []
	for l in src_lines:
		ids.append(l.id)
	_root.set_selection(ids)
	_root.tools.set_active("rect_pattern")
	var rp := _root.tools.get_tool("rect_pattern") as RectPatternTool
	rp._fields.texts[0] = "3"
	rp._fields.texts[1] = "2"
	rp._fields.texts[2] = "30mm"
	rp._fields.texts[3] = "25mm"
	_click(Vector2(60, 40))   # click position irrelevant once fields are set
	var lines_now := _kinds(sk, "line").size()
	if lines_now != 4 * 6:
		return _fail("3x2 pattern should yield 24 lines, got %d" % lines_now)
	# Copies land at i*30 / j*25 offsets: look for a point at (5+60, 5+25).
	var found := false
	for e in _kinds(sk, "point"):
		if (e as SketchPoint).pos.distance_to(Vector2(65, 30)) < 1e-4:
			found = true
	if not found:
		return _fail("pattern copy not at the expected offset")
	# Internal H/V constraints cloned per copy: 5 extra copies * 4 = +20.
	if sk.constraints.size() < n_cons_src + 5 * 4:
		return _fail("pattern did not clone internal constraints (%d -> %d)"
			% [n_cons_src, sk.constraints.size()])
	# ONE undo step removes the whole pattern.
	_root.stack.undo()
	if _kinds(sk, "line").size() != 4:
		return _fail("undo did not remove the whole pattern in one step")
	if sk.constraints.size() != n_cons_src:
		return _fail("undo left cloned constraints behind")

	# --- circular pattern: circle patterned 4x around the origin ----------
	_root.tools.set_active("circle")
	_click(Vector2(60, 0))
	_click(Vector2(65, 0))
	var circ := _kinds(sk, "circle")[0] as SketchCircle
	_root.set_selection([circ.id])
	_root.tools.set_active("circ_pattern")
	_click(Vector2.ZERO)   # center; N defaults to 4, A to 360
	var circles := _kinds(sk, "circle")
	if circles.size() != 4:
		return _fail("circular pattern should yield 4 circles, got %d"
			% circles.size())
	var hit90 := false
	for c in circles:
		var cc := (sk.point((c as SketchCircle).center)).pos
		if cc.distance_to(Vector2(0, 60)) < 1e-4:
			hit90 = true
		if absf((c as SketchCircle).radius - 5.0) > 1e-6:
			return _fail("copy radius drifted")
	if not hit90:
		return _fail("no copy at 90 degrees")
	# Partial-angle math: 3 copies over 180 -> last lands ON 180.
	if absf(CircPatternTool.step_deg(3, 180.0) - 90.0) > 1e-9:
		return _fail("partial-angle step wrong")
	if absf(CircPatternTool.step_deg(4, 360.0) - 90.0) > 1e-9:
		return _fail("full-circle step wrong")
	_root.stack.undo()

	# --- chamfer -----------------------------------------------------------
	# Corner of the source rect at (5,5): chamfer with default distance.
	var corner_id := ""
	for e in _kinds(sk, "point"):
		if (e as SketchPoint).pos.distance_to(Vector2(5, 5)) < 1e-4:
			corner_id = e.id
	if corner_id == "":
		return _fail("rect corner point not found")
	var n_before := sk.size()
	_root.tools.set_active("chamfer")
	_click(Vector2(5, 5))
	if sk.has(corner_id):
		return _fail("chamfer did not delete the corner point")
	# +2 points +1 line -1 corner = +2 entities.
	if sk.size() != n_before + 2:
		return _fail("chamfer entity census wrong (%d vs %d)"
			% [sk.size(), n_before + 2])
	var chamfer_edge: SketchLine = null
	for e in _kinds(sk, "line"):
		var a := sk.point((e as SketchLine).p0).pos
		var b := sk.point((e as SketchLine).p1).pos
		if a.distance_to(Vector2(5, 5 + 6.35)) < 1e-3 \
				and b.distance_to(Vector2(5 + 6.35, 5)) < 1e-3 \
				or b.distance_to(Vector2(5, 5 + 6.35)) < 1e-3 \
				and a.distance_to(Vector2(5 + 6.35, 5)) < 1e-3:
			chamfer_edge = e
	if chamfer_edge == null:
		return _fail("chamfer edge not at the default 0.25in legs")
	_root.stack.undo()
	if not sk.has(corner_id):
		return _fail("chamfer undo did not restore the corner in one step")

	# --- polygon -----------------------------------------------------------
	var n_ents := sk.size()
	var n_cons := sk.constraints.size()
	_root.tools.set_active("polygon")
	_click(Vector2(100, 50))       # center
	_click(Vector2(110, 50))       # vertex -> R 10, N default 6
	# + center + circle + 6 verts + 6 sides = 14 entities.
	if sk.size() != n_ents + 14:
		return _fail("polygon census wrong (%d vs %d)"
			% [sk.size(), n_ents + 14])
	if sk.constraints.size() != n_cons + 6 + 5:
		return _fail("polygon constraints wrong (%d vs %d)"
			% [sk.constraints.size(), n_cons + 11])
	# All six sides equal length 2*R*sin(pi/6) = R.
	var sides := 0
	for e in _kinds(sk, "line"):
		var a := sk.point((e as SketchLine).p0).pos
		var b := sk.point((e as SketchLine).p1).pos
		if absf(a.distance_to(b) - 10.0) < 1e-4 \
				and a.distance_to(Vector2(100, 50)) < 10.0 + 1e-3:
			sides += 1
	if sides != 6:
		return _fail("hexagon sides wrong (found %d of length R)" % sides)
	_root.stack.undo()
	if sk.size() != n_ents:
		return _fail("polygon undo not a single step")

	print("M29_SKETCH_PATTERNS OK: rect/circ patterns + cloned constraints, ",
		"chamfer surgery, polygon, one-step undo everywhere")
	return true
