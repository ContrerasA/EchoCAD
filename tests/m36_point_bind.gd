extends SceneTree

# M36 QA: the Point tool honours the snap it SHOWED.
#  A. dropped on a curve -> POINT_ON (and it survives the line moving)
#  B. dropped on a line's midpoint -> MIDPOINT (tracks the middle)
#  C. dropped on an existing point -> that point is reused, not twinned
#  D. dropped in open space -> a free point, no constraints
#  E. hover names the entity the click would bind to, and clears off it

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
	push_error("m36_point_bind: " + msg)
	return false


func _idle() -> void:
	await process_frame
	await process_frame


func _move(w: Vector2) -> void:
	_root.tools.handle_pointer_move(w, _root.sketch_view.world_to_screen(w),
		InputEventMouseMotion.new())


func _click(w: Vector2) -> void:
	_move(w)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(w, _root.sketch_view.world_to_screen(w), down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(w, _root.sketch_view.world_to_screen(w), up)


## The constraints that reference `pid`, as "TYPE:other" strings.
func _bonds(sk: Sketch, pid: String) -> Array:
	var out: Array = []
	for c in sk.constraints:
		if not c.references(pid):
			continue
		var other := c.operands[1] if c.operands[0] == pid else c.operands[0]
		out.append("%s:%s" % [
			String((SketchConstraint.Type.keys() as Array)[c.type]), other])
	return out


func _newest_point(sk: Sketch, known: Dictionary) -> String:
	for e in sk.entities():
		if e.kind() == "point" and not known.has(e.id):
			return e.id
	return ""


func _known_points(sk: Sketch) -> Dictionary:
	var d := {}
	for e in sk.entities():
		if e.kind() == "point":
			d[e.id] = true
	return d


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	await _idle()

	var fid := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(0, 0), 8.0)
	# One horizontal line from (-20,10) to (20,10).
	_root.tools.set_active("line")
	_click(Vector2(-20, 10))
	_click(Vector2(20, 10))
	_root.tools.handle_cancel()
	await _idle()
	var sk: Sketch = _root.doc.sketch_feature(fid).sketch
	var line: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e as SketchLine
	if line == null:
		return _fail("setup: no line drawn")

	# --- E. hover names the bind target -----------------------------------
	_root.tools.set_active("point")
	var tool := _root.tools.get_tool("point")
	_move(Vector2(-5, 10))
	if tool.hover_id != line.id:
		return _fail("E: hover over the line reads '%s'" % tool.hover_id)
	_move(Vector2(-5, -25))
	if tool.hover_id != "":
		return _fail("E: hover in open space reads '%s'" % tool.hover_id)
	# An existing point is a pick too — the click reuses it, so it must
	# pre-highlight rather than looking like a click into nothing.
	_move(sk.point(line.p0).pos)
	if tool.hover_id != line.p0:
		return _fail("E: hover over an existing point reads '%s'"
			% tool.hover_id)

	# --- A. on the curve -> POINT_ON --------------------------------------
	var before := _known_points(sk)
	_click(Vector2(-8, 10))
	await _idle()
	var pa := _newest_point(sk, before)
	if pa == "":
		return _fail("A: no point was created on the line")
	if _bonds(sk, pa) != ["POINT_ON:%s" % line.id]:
		return _fail("A: bonds are %s" % [_bonds(sk, pa)])

	# ...and it HOLDS: move the line up, re-solve, the point comes along.
	_root.stack.push_no_merge(CmdMovePoints.new(fid, {
		line.p0: sk.point(line.p0).pos + Vector2(0, 12),
		line.p1: sk.point(line.p1).pos + Vector2(0, 12)}))
	_root.solve_followers([line.p0, line.p1])
	await _idle()
	var a := sk.point(line.p0).pos
	var b := sk.point(line.p1).pos
	var n := Vector2(-(b - a).y, (b - a).x).normalized()
	var off := absf(n.dot(sk.point(pa).pos - a))
	if off > 0.01:
		return _fail("A: the point left the moved line by %f mm" % off)

	# --- B. on the midpoint -> MIDPOINT -----------------------------------
	before = _known_points(sk)
	var mid := (sk.point(line.p0).pos + sk.point(line.p1).pos) * 0.5
	_click(mid)
	await _idle()
	var pb := _newest_point(sk, before)
	if pb == "" or _bonds(sk, pb) != ["MIDPOINT:%s" % line.id]:
		return _fail("B: bonds are %s" % [_bonds(sk, pb)])

	# --- C. on an existing point -> reuse ---------------------------------
	before = _known_points(sk)
	_click(sk.point(line.p0).pos)
	await _idle()
	if _newest_point(sk, before) != "":
		return _fail("C: clicking an existing point minted a twin")
	if _root.selection != [line.p0]:
		return _fail("C: the existing point was not selected (%s)"
			% [_root.selection])

	# --- D. open space -> free point --------------------------------------
	before = _known_points(sk)
	_click(Vector2(-30, -30))
	await _idle()
	var pd := _newest_point(sk, before)
	if pd == "":
		return _fail("D: no free point was created")
	if not _bonds(sk, pd).is_empty():
		return _fail("D: a free point picked up %s" % [_bonds(sk, pd)])

	print("M36_POINT_BIND OK: point tool commits the snap it showed "
		+ "(POINT_ON / MIDPOINT / reuse), and the bond holds under motion")
	return true
