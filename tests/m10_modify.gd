extends SceneTree

# M10: trim / extend / offset / mirror / fillet through the ToolManager.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m10_modify: " + msg)
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
		e.unicode = ch.unicode_at(0)
		tool.key_input(e)


## Document JSON with never-rolled-back id counters neutralized.
func _snap() -> String:
	var d: Dictionary = _root.doc.to_dict()
	d["feature_counter"] = 0
	for f: Dictionary in d["features"]:
		if f.has("sketch"):
			(f["sketch"] as Dictionary)["id_counter"] = 0
	return JSON.stringify(d)


func _line(sk: Sketch, a: Vector2, b: Vector2) -> SketchLine:
	var pa := SketchPoint.make(a)
	var pb := SketchPoint.make(b)
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pa, pb, l]))
	return l


func _lines(sk: Sketch) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e.kind() == "line":
			out.append(e)
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# --- TRIM: cross of two lines; clicking one side of the crossing
	# removes exactly that span.
	var h := _line(sk, Vector2(-40, 0), Vector2(40, 0))
	var v := _line(sk, Vector2(0, -40), Vector2(0, 40))
	_root.rebuild_snap_index()
	var json0 := _snap()
	_root.tools.set_active("trim")
	_click(Vector2(20, 0.5))       # right half of the horizontal line
	var lines := _lines(sk)
	if lines.size() != 2:
		return _fail("trim census wrong: %d lines" % lines.size())
	# Remaining horizontal piece spans [-40, 0].
	var xs: Array = []
	for l: SketchLine in lines:
		xs.append([sk.point(l.p0).pos, sk.point(l.p1).pos])
	var found_left := false
	for pair in xs:
		var lo: Vector2 = pair[0]
		var hi: Vector2 = pair[1]
		if absf(lo.y) < 0.01 and absf(hi.y) < 0.01:
			var minx: float = minf(lo.x, hi.x)
			var maxx: float = maxf(lo.x, hi.x)
			if absf(minx + 40.0) < 0.01 and absf(maxx) < 0.01:
				found_left = true
	if not found_left:
		return _fail("trim kept the wrong span: %s" % str(xs))
	_root.stack.undo()
	if _snap() != json0:
		return _fail("trim not one undo step")
	_root.stack.redo()

	# --- TRIM a circle crossed by the vertical line: circle becomes an arc.
	var cp := SketchPoint.make(Vector2(0, 20))
	cp.id = sk.next_id()
	var circle := SketchCircle.make(cp.id, 10.0)
	circle.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[cp, circle]))
	_click(Vector2(-10, 20))       # left rim, between the two cuts at x=0
	var arcs := 0
	var circles := 0
	for e in sk.entities():
		if e.kind() == "arc":
			arcs += 1
		elif e.kind() == "circle":
			circles += 1
	if circles != 0 or arcs != 1:
		return _fail("circle trim wrong: %d circles %d arcs" % [circles, arcs])

	# --- EXTEND: a short line pointing at another extends to meet it.
	var target := _line(sk, Vector2(60, -30), Vector2(60, 30))
	var short := _line(sk, Vector2(30, 10), Vector2(45, 10))
	_root.tools.set_active("extend")
	_click(Vector2(44, 10.5))      # near the (45,10) tip
	if absf(sk.point(short.p1).pos.x - 60.0) > 0.001:
		return _fail("extend missed: %s" % sk.point(short.p1).pos)

	# --- OFFSET: line offset by typed 0.5in on the cursor side.
	_root.tools.set_active("offset")
	var base := _line(sk, Vector2(-60, -60), Vector2(-20, -60))
	_root.rebuild_snap_index()
	var n_lines := _lines(sk).size()
	_click(Vector2(-40, -59.5))    # pick the line
	_root.tools.handle_pointer_move(Vector2(-40, -50),
		_root.sketch_view.world_to_screen(Vector2(-40, -50)),
		InputEventMouseMotion.new())
	_type("0.5")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	_root.tools.get_tool("offset").key_input(enter)
	lines = _lines(sk)
	if lines.size() != n_lines + 1:
		return _fail("offset did not add a line")
	var off := lines[lines.size() - 1] as SketchLine
	if absf(sk.point(off.p0).pos.y - (-60.0 + 12.7)) > 0.001:
		return _fail("offset distance wrong: %s" % sk.point(off.p0).pos)

	# --- MIRROR: mirror the offset line about the vertical remnant... use a
	# fresh axis; SYMMETRY constraints created, geometry mirrored.
	var axis := _line(sk, Vector2(-80, -80), Vector2(-80, -20))
	_root.set_selection([off.id])
	_root.tools.set_active("mirror")
	var cons_before := sk.constraints.size()
	_click(Vector2(-80, -50))      # click the axis
	var syms := 0
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.SYMMETRY:
			syms += 1
	if syms != 2:
		return _fail("mirror symmetry constraints wrong: %d" % syms)
	var mirrored := _lines(sk)[_lines(sk).size() - 1] as SketchLine
	# off.p0 at (-60, -47.3) -> mirrored about x=-80 -> (-100, -47.3).
	if sk.point(mirrored.p0).pos.distance_to(Vector2(-100, -47.3)) > 0.01:
		return _fail("mirror position wrong: %s" % sk.point(mirrored.p0).pos)

	# --- FILLET: an L corner gets a tangent arc, corner point split+gone.
	var la := _line(sk, Vector2(100, 100), Vector2(140, 100))
	var lb := SketchLine.make(la.p1, "")
	# Build the second leg SHARING la.p1.
	var pb2 := SketchPoint.make(Vector2(140, 140))
	pb2.id = sk.next_id()
	lb = SketchLine.make(la.p1, pb2.id)
	lb.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pb2, lb]))
	_root.rebuild_snap_index()
	var corner_id := la.p1
	var arcs_before := 0
	for e in sk.entities():
		if e.kind() == "arc":
			arcs_before += 1
	_root.tools.set_active("fillet")
	_type("0.25")
	_click(Vector2(140, 100))      # the corner
	if sk.has(corner_id):
		return _fail("fillet left the corner point")
	var fillet_arc: SketchArc = null
	for e in sk.entities():
		if e.kind() == "arc" and sk.index_of(e.id) > 0:
			fillet_arc = e
	var arcs_after := 0
	for e in sk.entities():
		if e.kind() == "arc":
			arcs_after += 1
	if arcs_after != arcs_before + 1:
		return _fail("fillet arc missing")
	# Tangency: arc radius 6.35, center at (140-6.35, 100+6.35).
	var fc: Vector2 = sk.point(fillet_arc.center).pos
	if fc.distance_to(Vector2(133.65, 106.35)) > 0.01:
		return _fail("fillet center wrong: %s" % fc)
	# Lines now end at the tangency points.
	if absf(sk.point(la.p1).pos.x - 133.65) > 0.01 \
			or absf(sk.point(la.p1).pos.y - 100.0) > 0.01:
		return _fail("fillet line rewire wrong: %s" % sk.point(la.p1).pos)
	# One undo restores the sharp corner.
	_root.stack.undo()
	if not sk.has(corner_id):
		return _fail("fillet undo did not restore corner")

	print("M10_MODIFY OK: trim line+circle, extend, offset, mirror, fillet")
	return true
