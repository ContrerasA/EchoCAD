extends SceneTree

# M21 QA fixes:
# - X toggles selected curves between normal and construction (one undo
#   step), which is how a construction line is made by hand.
# - X with NOTHING selected toggles construction MODE: geometry drawn from
#   then on is minted construction (works mid line chain).
# - Export DXF resolves the browser-SELECTED sketch in model mode, and the
#   browser's sketch context menu / explicit target id exports that sketch.
# - The DXF carries a DASHED linetype on the CONSTRUCTION layer, and
#   construction geometry can be excluded from the export.

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


func _count_lines(dxf: String) -> int:
	var n := 0
	var at := 0
	while true:
		at = dxf.find("\nLINE\n", at)
		if at < 0:
			break
		n += 1
		at += 1
	return n


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
	# A point-only selection refuses politely rather than toggling anything.
	_root.set_selection([(sk1.entity(lid) as SketchLine).p0])
	_root.toggle_construction()
	if sk1.entity(lid).construction or _root.construction_mode:
		return _fail("point selection must not toggle its line or the mode")

	# --- X with EMPTY selection toggles construction MODE -------------------
	_root.set_selection([])
	_root.toggle_construction()
	if not _root.construction_mode:
		return _fail("empty-selection X should turn construction mode on")
	# Draw a line through the real tool: it comes out construction.
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("line")
	var tool: SketchTool = _root.tools.get_tool("line")
	for w in [Vector2(0, 40), Vector2(30, 40)]:
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		tool.pointer_move(w, _root.sketch_view.world_to_screen(w),
			InputEventMouseMotion.new())
		tool.pointer_down(w, _root.sketch_view.world_to_screen(w), down)
	_root.tools.handle_cancel()
	var drawn: SketchLine = null
	for e in sk1.entities():
		if e.kind() == "line" and e.id != lid:
			drawn = e as SketchLine
	if drawn == null or not drawn.construction:
		return _fail("line drawn in construction mode should be construction")
	if sk1.point(drawn.p0).construction or sk1.point(drawn.p1).construction:
		return _fail("points must not be marked construction")
	_root.toggle_construction()   # empty selection -> mode off again
	_root.set_selection([])
	if _root.construction_mode:
		return _fail("second empty-selection X should turn the mode off")

	# --- DXF: DASHED linetype, layer wiring, exclude option -----------------
	var text1 := DxfExporter.to_dxf(sk1)
	if not text1.contains("DASHED"):
		return _fail("DXF missing the DASHED linetype")
	# The CONSTRUCTION layer must reference it (code 6 DASHED after the name).
	var li := text1.find("CONSTRUCTION")
	if li < 0 or text1.find("DASHED", li) < 0:
		return _fail("CONSTRUCTION layer not wired to DASHED")
	var text_no_cons := DxfExporter.to_dxf(sk1, false)
	# sk1's construction line runs to x=30 at y=40; excluded output must not
	# contain a LINE at y 40.
	if _count_lines(text_no_cons) != _count_lines(text1) - 1:
		return _fail("construction exclusion did not drop exactly one LINE")
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

	print("M21_QA_FIXES OK: X toggle + construction mode, dashed DXF "
		+ "linetype, construction exclusion, browser-selected export target")
	return true
