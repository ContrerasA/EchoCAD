extends SceneTree

# M21 QA fixes:
# - X toggles selected curves between normal and construction (one undo
#   step), which is how a construction line is made by hand.
# - Export DXF resolves the browser-SELECTED sketch in model mode, and the
#   browser's sketch context menu / explicit target id exports that sketch.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m21_qa_fixes: " + msg)
	return false


func _add_line(sk: Sketch, a: Vector2, b: Vector2) -> String:
	var pa := SketchPoint.make(a)
	var pb := SketchPoint.make(b)
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pa, pb, l]))
	return l.id


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- X construction toggle ----------------------------------------------
	var f1 := _root.create_sketch("XY")
	var sk1: Sketch = _root.active_sketch()
	var lid := _add_line(sk1, Vector2(0, 0), Vector2(30, 0))
	_root.set_selection([lid])
	_root.toggle_construction()
	if not sk1.entity(lid).construction:
		return _fail("X toggle did not mark the line construction")
	# The DXF now carries it on the CONSTRUCTION layer.
	if not DxfExporter.to_dxf(sk1).contains("CONSTRUCTION"):
		return _fail("construction line not on its layer in DXF")
	_root.toggle_construction()
	if sk1.entity(lid).construction:
		return _fail("second X did not toggle back")
	_root.toggle_construction()   # leave it construction for the undo check
	_root.stack.undo()
	if sk1.entity(lid).construction:
		return _fail("undo did not restore the flag")
	# A point-only selection refuses politely rather than toggling nothing.
	_root.set_selection([(sk1.entity(lid) as SketchLine).p0])
	_root.toggle_construction()
	if sk1.entity(lid).construction:
		return _fail("point selection must not toggle its line")
	_root.finish_sketch()

	# --- Export target resolution in model mode ------------------------------
	var f2 := _root.create_sketch("XZ")
	var sk2: Sketch = _root.active_sketch()
	_add_line(sk2, Vector2(100, 100), Vector2(140, 100))
	_root.finish_sketch()
	_root.browser.refresh()

	# Two sketches, nothing selected: ambiguous.
	if _root._dxf_target_feature() != null:
		return _fail("two sketches with no selection should be ambiguous")

	# Selecting a sketch row in the browser resolves it.
	var picked := false
	for row: TreeItem in _root.browser._rows:
		var meta: Dictionary = _root.browser._rows[row]
		if String(meta["kind"]) == "sketch" and String(meta["id"]) == f1:
			row.select(BrowserTree.COL_NAME)
			picked = true
			break
	if not picked:
		return _fail("sketch row for f1 not found in the browser")
	if _root.browser.selected_sketch_id() != f1:
		return _fail("selected_sketch_id wrong")
	var target := _root._dxf_target_feature()
	if target == null or target.id != f1:
		return _fail("export target should be the browser-selected sketch")

	# Explicit target (the context menu's path) exports THAT sketch even
	# though another is selected: sketch2's line is at x=100..140.
	_root.export_dxf_interactive(f2)
	if _root._dxf_export_id != f2:
		return _fail("explicit export target not honored")
	if not _root.export_dxf("user://m21_fix_out"):
		return _fail("export refused")
	var f := FileAccess.open("user://m21_fix_out.dxf", FileAccess.READ)
	if f == null:
		return _fail("exported file missing")
	var text := f.get_as_text()
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://m21_fix_out.dxf"))
	if not text.contains("100") or not text.contains("140"):
		return _fail("exported the wrong sketch (f2's line missing)")

	print("M21_QA_FIXES OK: X construction toggle (undoable, DXF layer), "
		+ "browser-selected export target, explicit context-menu target")
	return true
