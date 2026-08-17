extends SceneTree

# M17: per-DOF drag. A drag is projected onto the freedoms the constraints
# leave open: a parallel pair's partner keeps its angle, a point on a
# Horizontal line moves in x but never y, an unconstrained point moves
# freely, a rect corner slides its neighbours — and a drag is still ONE
# undo step.

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
	push_error("m17_dof_drag: " + msg)
	return false


func _pt(sk: Sketch, p: Vector2) -> String:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	sk.add(e)
	return e.id


func _line(sk: Sketch, a: String, b: String) -> String:
	var e := SketchLine.make(a, b)
	e.id = sk.next_id()
	sk.add(e)
	return e.id


func _con(sk: Sketch, t: SketchConstraint.Type, ops: Array) -> void:
	var typed: Array[String] = []
	for o in ops:
		typed.append(String(o))
	sk.constraints.append(SketchConstraint.make(t, typed))


## Drive a full select-tool drag from `from` by `delta` (world mm).
func _drag(from: Vector2, delta: Vector2) -> void:
	_root._refresh_dof()
	_root.tools.set_active("select")
	var tool: SketchTool = _root.tools.get_tool("select")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	tool.pointer_down(from, _root.sketch_view.world_to_screen(from), down)
	for i in 5:
		var w := from + delta * float(i + 1) / 5.0
		tool.pointer_move(w, _root.sketch_view.world_to_screen(w),
			InputEventMouseMotion.new())
		await _idle()
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	tool.pointer_up(Vector2.ZERO, Vector2.ZERO, up)
	await _idle()


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var sid := _root.create_sketch("XY")
	var sk: Sketch = _root.doc.sketch_feature(sid).sketch
	_root.snap.grid_enabled = false

	# --- unconstrained point moves freely ----------------------------------
	var free := _pt(sk, Vector2(100, 100))
	var fplan := DragFilter.plan(sk, [free], {free: Vector2(7, -3)})
	if not bool(fplan["allowed"]) or bool(fplan["restricted"]):
		return _fail("unconstrained point should move freely")
	if (fplan["moves"][free] as Vector2).distance_to(Vector2(7, -3)) > 1e-9:
		return _fail("unconstrained motion altered: %s" % str(fplan["moves"][free]))
	sk.remove(free)

	# --- a point on a Horizontal line moves in x, never y -------------------
	var h0 := _pt(sk, Vector2(10, 20))
	var h1 := _pt(sk, Vector2(50, 20))
	var hl := _line(sk, h0, h1)
	_con(sk, SketchConstraint.Type.HORIZONTAL, [hl])
	await _drag(Vector2(10, 20), Vector2(12, 9))
	var p0: Vector2 = sk.point(h0).pos
	if absf(p0.y - 20.0) > 1e-6:
		return _fail("H endpoint moved in y (%s)" % str(p0))
	if p0.x < 15.0:
		return _fail("H endpoint did not slide in x (%s)" % str(p0))
	if sk.point(h1).pos.distance_to(Vector2(50, 20)) > 1e-6:
		return _fail("untouched H endpoint moved (%s)" % str(sk.point(h1).pos))
	# A PURELY vertical drag sticks — never translates the line.
	var before := sk.point(h0).pos
	await _drag(before, Vector2(0, 15))
	if absf(sk.point(h0).pos.y - 20.0) > 1e-6:
		return _fail("vertical drag changed a Horizontal line's y")

	# --- parallel pair: the partner's angle never changes -------------------
	var a0 := _pt(sk, Vector2(0, 60))
	var a1 := _pt(sk, Vector2(40, 80))
	var al := _line(sk, a0, a1)
	var b0 := _pt(sk, Vector2(0, 100))
	var b1 := _pt(sk, Vector2(40, 120))
	var bl := _line(sk, b0, b1)
	_con(sk, SketchConstraint.Type.PARALLEL, [al, bl])
	var b_angle := (sk.point(b1).pos - sk.point(b0).pos).angle()
	var a_start: Vector2 = sk.point(a0).pos
	await _drag(a_start, Vector2(10, 14))
	var b_after := (sk.point(b1).pos - sk.point(b0).pos).angle()
	if absf(b_after - b_angle) > 1e-4:
		return _fail("parallel partner rotated (%f -> %f)" % [b_angle, b_after])
	if sk.point(b0).pos.distance_to(Vector2(0, 100)) > 1e-6:
		return _fail("parallel partner's endpoint moved")
	if sk.point(a0).pos.distance_to(a_start) < 1.0:
		return _fail("dragged endpoint of the parallel pair did not slide")
	var a_angle := (sk.point(a1).pos - sk.point(a0).pos).angle()
	if absf(a_angle - b_after) > 1e-4:
		return _fail("pair no longer parallel after drag")

	# --- rect corner: corner moves, neighbours slide, H/V hold --------------
	var r00 := _pt(sk, Vector2(200, 10))
	var r10 := _pt(sk, Vector2(240, 10))
	var r11 := _pt(sk, Vector2(240, 40))
	var r01 := _pt(sk, Vector2(200, 40))
	var bot := _line(sk, r00, r10)
	var rgt := _line(sk, r10, r11)
	var top := _line(sk, r11, r01)
	var lft := _line(sk, r01, r00)
	_con(sk, SketchConstraint.Type.HORIZONTAL, [bot])
	_con(sk, SketchConstraint.Type.VERTICAL, [rgt])
	_con(sk, SketchConstraint.Type.HORIZONTAL, [top])
	_con(sk, SketchConstraint.Type.VERTICAL, [lft])
	var depth_before: int = _root.stack._undo.size()
	await _drag(Vector2(200, 10), Vector2(-8, -6))
	var c: Vector2 = sk.point(r00).pos
	if c.distance_to(Vector2(192, 4)) > 0.5:
		return _fail("rect corner did not follow the drag (got %s)" % str(c))
	if absf(sk.point(r10).pos.y - c.y) > 1e-6:
		return _fail("bottom edge no longer horizontal")
	if absf(sk.point(r01).pos.x - c.x) > 1e-6:
		return _fail("left edge no longer vertical")
	if sk.point(r11).pos.distance_to(Vector2(240, 40)) > 1e-6:
		return _fail("opposite corner moved (%s)" % str(sk.point(r11).pos))

	# --- the whole corner drag is one undo step ----------------------------
	if _root.stack._undo.size() != depth_before + 1:
		return _fail("corner drag was %d undo steps, want 1"
			% (_root.stack._undo.size() - depth_before))
	_root.stack.undo()
	if sk.point(r00).pos.distance_to(Vector2(200, 10)) > 1e-6:
		return _fail("undo did not revert the corner drag")

	# --- Point-On a circle: the point rides the circle, and STAYS on it -----
	# (QA finding: the substep walk drifted off the circle enough to trip the
	# conflict badge; the Newton polish must keep the residual below the DOF
	# analyzer's violation tolerance for the whole drag.)
	var cc := _pt(sk, Vector2(320, 200))
	var circ := SketchCircle.make(cc, 25.0)
	circ.id = sk.next_id()
	sk.add(circ)
	var rider := _pt(sk, Vector2(345, 200))   # on the rim, due east
	_con(sk, SketchConstraint.Type.POINT_ON, [rider, circ.id])
	await _drag(Vector2(345, 200), Vector2(-10, 24))   # pull up and around
	var rp: Vector2 = sk.point(rider).pos
	var rerr := absf(rp.distance_to(sk.point(cc).pos) - 25.0)
	if rerr > 5e-4:
		return _fail("rider left the circle by %.5f mm (pos %s)" % [rerr, str(rp)])
	if rp.distance_to(Vector2(345, 200)) < 5.0:
		return _fail("rider did not slide around the circle (%s)" % str(rp))
	if sk.point(cc).pos.distance_to(Vector2(320, 200)) > 1e-6:
		return _fail("circle center moved during rim drag")
	var dof_after := DofAnalyzer.analyze(sk)
	if not (dof_after["conflicts"] as Array).is_empty():
		return _fail("conflict badge tripped after point-on drag: %s"
			% str(dof_after["conflicts"]))

	# --- FIXed geometry refuses with no motion ------------------------------
	var fx := _pt(sk, Vector2(300, 300))
	_con(sk, SketchConstraint.Type.FIX, [fx])
	var fxplan := DragFilter.plan(sk, [fx], {fx: Vector2(5, 5)})
	if bool(fxplan["allowed"]):
		return _fail("FIXed point drag should be refused")

	print("M17 OK: rails drag — H stays level, parallel partner still, corner slides")
	return true
