extends SceneTree

# M11: timeline — rollback marker hides downstream features, suppress,
# undoable timeline ops, save/load preserves marker, edit-and-return,
# timeline bar chips reflect state.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m11_timeline: " + msg)
	return false


func _add_line(fid: String, a: Vector2, b: Vector2) -> void:
	var sk := _root.doc.sketch_feature(fid).sketch
	var pa := SketchPoint.make(a)
	var pb := SketchPoint.make(b)
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(fid, [pa, pb, l]))


func _visible_sketch_meshes() -> int:
	var n := 0
	for c in _root.world._sketch_root.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# Two sketches with content.
	var f1 := _root.create_sketch("XY")
	_add_line(f1, Vector2(0, 0), Vector2(20, 0))
	_root.finish_sketch()
	var f2 := _root.create_sketch("XZ")
	_add_line(f2, Vector2(0, 0), Vector2(0, 30))
	_root.finish_sketch()
	if _root.doc.timeline_marker != 2:
		return _fail("marker not at end: %d" % _root.doc.timeline_marker)
	if _visible_sketch_meshes() != 2:
		return _fail("expected 2 sketch meshes")

	# Roll back before Sketch2: it disappears from the world.
	_root.stack.push_no_merge(CmdSetMarker.new(2, 1))
	if _root.doc.live_features().size() != 1:
		return _fail("rollback did not hide feature 2")
	if _visible_sketch_meshes() != 1:
		return _fail("world still shows rolled-back sketch")
	# Chips reflect rollback: chip for f2 is parenthesized.
	_root.timeline.refresh()
	var chip2 := _root.timeline.find_child("Chip_" + f2, false, false) as Button
	if chip2 == null or not chip2.text.begins_with("("):
		return _fail("rolled-back chip not marked: %s"
			% (chip2.text if chip2 != null else "missing"))

	# Undo the rollback.
	_root.stack.undo()
	if _root.doc.timeline_marker != 2 or _root.doc.live_features().size() != 2:
		return _fail("rollback undo wrong")

	# Suppress Sketch1: hidden but marker untouched.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(f1, "suppressed", true))
	if _root.doc.live_features().size() != 1:
		return _fail("suppress did not hide")
	if _visible_sketch_meshes() != 1:
		return _fail("world shows suppressed sketch")
	_root.stack.undo()

	# New sketches insert AT the marker: roll back to 1, create -> lands at
	# index 1, marker 2, old Sketch2 shifts to index 2 (still rolled back).
	_root.stack.push_no_merge(CmdSetMarker.new(2, 1))
	var f3 := _root.create_sketch("YZ")
	_root.finish_sketch()
	if _root.doc.features[1].id != f3 or _root.doc.timeline_marker != 2:
		return _fail("insert-at-marker wrong: %s marker=%d"
			% [_root.doc.features[1].id, _root.doc.timeline_marker])
	if _root.doc.features[2].id != f2:
		return _fail("downstream feature did not shift")
	if _root.doc.live_features().size() != 2:
		return _fail("live set wrong after insert")

	# Save -> load preserves order, marker, suppressed flags.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(f1, "suppressed", true))
	var path := "user://m11_timeline.ecad"
	Serializer.save(_root.doc, path)
	var loaded := Serializer.load_file(path)
	if loaded.timeline_marker != 2 or loaded.features.size() != 3:
		return _fail("save/load lost timeline state")
	if not loaded.features[0].suppressed:
		return _fail("save/load lost suppressed flag")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(String(path)))

	# Edit a live sketch from the timeline and finish: content edits apply.
	_root.edit_sketch(f3)
	if _root.mode != AppRoot.Mode.SKETCH or _root.active_sketch_id != f3:
		return _fail("edit_sketch did not enter")
	_add_line(f3, Vector2(5, 5), Vector2(25, 5))
	_root.finish_sketch()
	if _root.doc.sketch_feature(f3).sketch.size() != 3:
		return _fail("edit did not persist")

	print("M11_TIMELINE OK: rollback, suppress, insert-at-marker, "
		+ "save/load, edit-and-return, chips")
	return true
