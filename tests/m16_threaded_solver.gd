extends SceneTree

# M16: threaded solver. Worker-thread solves are identical to synchronous
# ones; a gesture that outruns the solver applies only the newest result;
# a drag plus its threaded re-solves still collapses to ONE undo step.

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
	push_error("m16_threaded_solver: " + msg)
	return false


## Spin frames until the worker goes idle (bounded).
func _drain(ts: ThreadedSolver) -> void:
	for i in 300:
		if not ts.busy():
			return
		await process_frame


## A constrained fixture: rect with H/V + coincident corners, one corner
## welded and a circle tied by a radius-ish EQUAL pair — enough structure
## that a solve genuinely moves followers.
func _fixture() -> Sketch:
	var sk := Sketch.new()
	var ids: Array[String] = []
	for p: Vector2 in [Vector2(0, 0), Vector2(40, 0), Vector2(40, 30), Vector2(0, 30)]:
		var pt := SketchPoint.make(p)
		pt.id = sk.next_id()
		sk.add(pt)
		ids.append(pt.id)
	for i in 4:
		var ln := SketchLine.make(ids[i], ids[(i + 1) % 4])
		ln.id = sk.next_id()
		sk.add(ln)
	var lines: Array = []
	for e in sk.entities():
		if e.kind() == "line":
			lines.append(e)
	sk.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.HORIZONTAL, [lines[0].id]))
	sk.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.VERTICAL, [lines[1].id]))
	sk.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.HORIZONTAL, [lines[2].id]))
	sk.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.VERTICAL, [lines[3].id]))
	return sk


func _results_equal(a: Dictionary, b: Dictionary) -> bool:
	var ap: Dictionary = a["points"]
	var bp: Dictionary = b["points"]
	if ap.size() != bp.size():
		return false
	for id: String in ap:
		if not bp.has(id) or (ap[id] as Vector2).distance_to(bp[id] as Vector2) > 1e-12:
			return false
	var ar: Dictionary = a["radii"]
	var br: Dictionary = b["radii"]
	if ar.size() != br.size():
		return false
	for id: String in ar:
		if not br.has(id) or absf(float(ar[id]) - float(br[id])) > 1e-12:
			return false
	return true


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var ts: ThreadedSolver = _root.threaded_solver
	if ts == null or not ts.available():
		return _fail("threaded solver not running")

	# --- identical results, threaded vs synchronous -------------------------
	var sk := _fixture()
	# Nudge a corner off-constraint so the solve has real work.
	var first_pt := sk.entities()[1] as SketchPoint   # entities()[0] is the origin
	first_pt.pos += Vector2(3, 2)
	var sync := ConstraintSolver.solve(Sketch.from_dict(sk.to_dict()), [first_pt.id])
	ts.request("fixture", sk, [first_pt.id])
	await _drain(ts)
	var got := ts.take_result()
	if got.is_empty():
		return _fail("threaded solve produced no result")
	if not _results_equal(got, sync):
		return _fail("threaded result differs from synchronous (%s vs %s)"
			% [str(got["points"]), str(sync["points"])])

	# --- only the newest result of a fast gesture applies -------------------
	first_pt.pos += Vector2(1, 0)
	ts.request("fixture", sk, [first_pt.id])
	await _drain(ts)                       # result A is READY but un-taken
	first_pt.pos += Vector2(4, 4)
	var sync_b := ConstraintSolver.solve(Sketch.from_dict(sk.to_dict()), [first_pt.id])
	ts.request("fixture", sk, [first_pt.id])   # supersedes A
	var stale := ts.take_result()
	if not stale.is_empty():
		return _fail("stale result A was handed out after request B")
	await _drain(ts)
	var fresh := ts.take_result()
	if fresh.is_empty():
		return _fail("newest result never arrived")
	if not _results_equal(fresh, sync_b):
		return _fail("newest result does not match B's synchronous solve")

	# --- cancel drops everything -------------------------------------------
	first_pt.pos += Vector2(1, 1)
	ts.request("fixture", sk, [first_pt.id])
	ts.cancel()
	await _drain(ts)
	if not ts.take_result().is_empty():
		return _fail("cancel left a result behind")

	# --- a real drag through the app is still ONE undo step -----------------
	var sid := _root.create_sketch("XY")
	var live: Sketch = _root.doc.sketch_feature(sid).sketch
	var ids: Array[String] = []
	for p: Vector2 in [Vector2(10, 10), Vector2(50, 10)]:
		var pt := SketchPoint.make(p)
		pt.id = live.next_id()
		live.add(pt)
		ids.append(pt.id)
	var ln := SketchLine.make(ids[0], ids[1])
	ln.id = live.next_id()
	live.add(ln)
	live.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.HORIZONTAL, [ln.id]))
	_root._refresh_dof()
	await _idle()

	var depth_before: int = _root.stack._undo.size()
	_root.tools.set_active("select")
	var tool: SketchTool = _root.tools.get_tool("select")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	var start_world := Vector2(10, 10)
	var start_screen: Vector2 = _root.sketch_view.world_to_screen(start_world)
	tool.pointer_down(start_world, start_screen, down)
	# Several move steps, each letting frames pass so threaded results land.
	for i in 6:
		var w := start_world + Vector2(2 * (i + 1), 1.5 * (i + 1))
		var mm := InputEventMouseMotion.new()
		tool.pointer_move(w, _root.sketch_view.world_to_screen(w), mm)
		await _idle()
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	tool.pointer_up(Vector2.ZERO, Vector2.ZERO, up)
	await _drain(ts)
	await _idle()

	var depth_after: int = _root.stack._undo.size()
	if depth_after != depth_before + 1:
		return _fail("drag produced %d undo steps, want 1"
			% (depth_after - depth_before))
	# The horizontal constraint held: both endpoints share a y.
	var pa: Vector2 = live.point(ids[0]).pos
	var pb: Vector2 = live.point(ids[1]).pos
	if absf(pa.y - pb.y) > 1e-6:
		return _fail("H constraint lost during threaded drag (%s vs %s)"
			% [str(pa), str(pb)])
	if pa.distance_to(start_world) < 1.0:
		return _fail("drag did not move the point")
	_root.stack.undo()
	if live.point(ids[0]).pos.distance_to(start_world) > 1e-6:
		return _fail("one undo did not revert the whole drag")

	print("M16 OK: threaded == sync, newest-only apply, one-step drag undo")
	return true
