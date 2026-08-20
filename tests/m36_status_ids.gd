extends SceneTree

# M36 dev readout: the status bar names WHAT is selected (or hovered) —
# entity id, kind, index into the sketch, plus the sub-entity ids — so
# geometry on screen can be matched to the .ecad JSON without opening it.
#  A. one line selected -> "e<n> line #<i>  [p0→p1]"
#  B. hover with an empty selection -> the same brief behind a "⌖"
#  C. multi-select collapses, construction + origin are called out
#  D. a selected constraint names its index, type and operands
#  E. the slot is empty outside sketch mode

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
	push_error("m36_status_ids: " + msg)
	return false


func _idle() -> void:
	await process_frame
	await process_frame


func _label() -> Label:
	return _root.find_child("StatusIds", true, false) as Label


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	await _idle()

	var fid := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 8.0)
	_root.tools.set_active("rect")
	var sv := _root.sketch_view
	for w in [Vector2(0, 0), Vector2(40, 30)]:
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		_root.tools.handle_pointer_move(w, sv.world_to_screen(w),
			InputEventMouseMotion.new())
		_root.tools.handle_pointer_down(w, sv.world_to_screen(w), down)
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		_root.tools.handle_pointer_up(w, sv.world_to_screen(w), up)
	await _idle()
	var sk: Sketch = _root.doc.sketch_feature(fid).sketch
	var lab := _label()
	if lab == null:
		return _fail("A: no StatusIds label in the status bar")

	# --- A. one line ------------------------------------------------------
	var line: SketchLine = null
	for e in sk.entities():
		if e.kind() == "line":
			line = e as SketchLine
			break
	if line == null:
		return _fail("A: the rect tool drew no line")
	_root.tools.set_active("select")
	_root.set_selection([line.id])
	await _idle()
	var want := "%s line #%d" % [line.id, sk.index_of(line.id)]
	if not lab.text.begins_with(want):
		return _fail("A: got '%s', wanted it to start '%s'" % [lab.text, want])
	if not lab.text.contains("%s→%s" % [line.p0, line.p1]):
		return _fail("A: '%s' omits the endpoint ids" % lab.text)

	# --- B. hover names the candidate when nothing is selected ------------
	_root.set_selection([])
	await _idle()
	if lab.text != "":
		return _fail("B: empty selection + no hover should read '' (%s)"
			% lab.text)
	var mid := (sk.point(line.p0).pos + sk.point(line.p1).pos) * 0.5
	_root.tools.handle_pointer_move(mid, sv.world_to_screen(mid),
		InputEventMouseMotion.new())
	await _idle()
	if not lab.text.begins_with("⌖ %s line" % line.id):
		return _fail("B: hover reads '%s'" % lab.text)

	# --- C. several at once, construction + origin flags ------------------
	var ids: Array = []
	for e in sk.entities():
		ids.append(e.id)
	_root.set_selection(ids)
	await _idle()
	if not lab.text.begins_with("%d sel:" % ids.size()) \
			or not lab.text.contains("more"):
		return _fail("C: multi-select reads '%s'" % lab.text)
	var cons := SketchLine.make(sk.origin_id(), line.p0)
	cons.id = sk.next_id()
	cons.construction = true
	sk.add(cons)
	if not SelectionReadout.entity_brief(sk, cons.id, false).contains("constr"):
		return _fail("C: construction geometry is not flagged")
	if not SelectionReadout.entity_brief(sk, sk.origin_id(), false) \
			.contains("origin"):
		return _fail("C: the origin point is not flagged")
	if not SelectionReadout.entity_brief(sk, "e999", false).contains("gone"):
		return _fail("C: a dangling id must read as gone")

	# --- D. a selected constraint names index / type / operands -----------
	if sk.constraints.is_empty():
		return _fail("D: the rect tool laid down no constraints")
	_root.set_selection([])
	_root.selected_constraint = 0
	await _idle()
	var c0 := sk.constraints[0]
	var tname := String((SketchConstraint.Type.keys() as Array)[c0.type])
	if not lab.text.begins_with("c#0 %s" % tname) \
			or not lab.text.contains(c0.operands[0]):
		return _fail("D: constraint readout is '%s'" % lab.text)
	_root.selected_constraint = -1

	# --- E. model mode clears the slot ------------------------------------
	_root.finish_sketch()
	await _idle()
	if lab.text != "":
		return _fail("E: model mode still reads '%s'" % lab.text)

	print("M36_STATUS_IDS OK: status bar names selection/hover ids, kinds, "
		+ "indices and constraint operands")
	return true
