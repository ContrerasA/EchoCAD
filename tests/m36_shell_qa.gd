extends SceneTree

# M36 QA round (docs/MANUAL_QA2.md §M36 "Additional"): uniform ribbon buttons
# with the tool-names preference, flyout stacks, no File group, centred
# captions, menu accelerators, themed embedded title bars, seeded user theme
# folder, labelled view cube, browser root component.

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
	push_error("m36_shell_qa: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	await _idle()
	var start_theme := ThemeService.theme_id
	var start_names := ThemeService.show_tool_names

	# --- A: no File group; Save/Open survive as hidden named controls ------
	if _root._shelf_groups.has("File"):
		return _fail("A: File group still in the ribbon")
	if not _root._shelf_groups.has("Insert"):
		return _fail("A: Insert group missing")
	for n in ["SaveBtn", "OpenBtn"]:
		var b := _root.find_child(n, true, false) as Button
		if b == null:
			return _fail("A: %s missing" % n)
		if b.visible:
			return _fail("A: %s visible in the ribbon" % n)

	# --- B: uniform buttons + Show tool names ------------------------------
	_root.set_show_tool_names(false)
	await _idle()
	var small := Vector2(ThemeService.metric("small_button_w"),
		ThemeService.metric("small_button_h"))
	var big := Vector2(ThemeService.metric("big_button_w"),
		ThemeService.metric("big_button_h"))
	for e: Dictionary in _root._ribbon_buttons:
		var b := e["btn"] as Button
		if b.theme_type_variation != "ToolButton":
			return _fail("B: %s is not a ToolButton" % b.name)
		if b.text != "" or b.custom_minimum_size != small:
			return _fail("B: %s not icon-only (%s %s)" % [b.name, b.text,
				b.custom_minimum_size])
	_root.set_show_tool_names(true)
	await _idle()
	for e: Dictionary in _root._ribbon_buttons:
		var b := e["btn"] as Button
		if b.text != String(e["title"]) or b.custom_minimum_size != big:
			return _fail("B: %s not labelled (%s)" % [b.name, b.text])
	await _idle()
	if _root._ribbon.custom_minimum_size.y <= ThemeService.metric("ribbon_height"):
		return _fail("B: ribbon did not grow for labelled two-row grids")
	if not ThemeService.show_tool_names:
		return _fail("B: preference not stored")
	ThemeService.load_settings()
	if not ThemeService.show_tool_names:
		return _fail("B: preference did not survive a settings reload")
	_root.set_show_tool_names(false)
	await _idle()
	var cons_grid: GridContainer = null
	for g: Dictionary in _root._ribbon_grids:
		if (g["grid"] as Control).get_child_count() == 14:
			cons_grid = g["grid"]
	if cons_grid == null or cons_grid.columns != 7:
		return _fail("B: constraint grid not back to 7 columns")
	var cap := (_root._shelf_groups["Create"] as Control).find_child("Caption",
		true, false) as Label
	if cap == null or cap.horizontal_alignment != HORIZONTAL_ALIGNMENT_CENTER:
		return _fail("B: group caption not centred")

	# --- C: flyout stacks ----------------------------------------------------
	for tid: String in _root.tools.tool_ids():
		var b: Button = _root._tool_buttons.get(tid)
		if b == null or b.icon == null or b.tooltip_text == "":
			return _fail("C: tool %s lost its button/icon/tooltip" % tid)
	var circle := _root.find_child("CircleToolBtn", true, false) as Button
	var circle3 := _root.find_child("Circle3ToolBtn", true, false) as Button
	if circle == null or circle3 == null:
		return _fail("C: circle stack buttons missing")
	if circle3.is_visible_in_tree():
		return _fail("C: 3-pt circle visible outside its flyout")
	var fly := circle.get_node_or_null("Flyout") as PopupPanel
	if fly == null or not fly.is_ancestor_of(circle3):
		return _fail("C: Circle3ToolBtn not inside CircleToolBtn's flyout")
	if circle.get_node_or_null("StackMark") == null:
		return _fail("C: stack button lacks its corner mark")
	var plain := _root.find_child("LineToolBtn", true, false) as Button
	if plain.get_node_or_null("StackMark") != null:
		return _fail("C: plain tool button carries a stack mark")
	_root.create_sketch("XY")
	await _idle()
	_root.tools.set_active("circle3")
	_root._refresh_ui()
	await _idle()
	if circle.icon != ThemeService.icon("circle3") or not circle.button_pressed:
		return _fail("C: stack face did not follow the active variant")
	if not circle.tooltip_text.begins_with("3-Pt Circle"):
		return _fail("C: stack tooltip did not follow (%s)" % circle.tooltip_text)
	_root.tools.set_active("line")
	_root._refresh_ui()
	await _idle()
	if circle.button_pressed:
		return _fail("C: stack face stayed pressed after leaving its tools")
	if circle.icon != ThemeService.icon("circle3"):
		return _fail("C: stack face forgot its last pick")
	# Right-click opens the flyout; picking an entry activates that tool.
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.position = circle.size / 2.0
	circle.gui_input.emit(ev)
	await _idle()
	if not fly.visible:
		return _fail("C: right-click did not open the flyout")
	var c1 := fly.find_child("CircleVariantBtn", true, false) as Button
	if c1 == null:
		return _fail("C: head variant row missing from the flyout")
	c1.pressed.emit()
	await _idle()
	if _root.tools.active_id() != "circle" or fly.visible:
		return _fail("C: flyout pick did not activate circle / close")
	if circle.icon != ThemeService.icon("circle"):
		return _fail("C: stack face did not return to circle")
	_root.finish_sketch()
	await _idle()

	# --- D: menu bar ---------------------------------------------------------
	if _root._menu_bar.size_flags_vertical != Control.SIZE_SHRINK_CENTER:
		return _fail("D: menu bar not centred in the row")
	if _root._menu_bar.is_processing_shortcut_input():
		return _fail("D: menu bar would fire accelerators (double key handling)")
	var file_menu := _root._menu_bar.get_menu_popup(0)
	if file_menu.get_item_accelerator(0) != (KEY_O | KEY_MASK_CTRL):
		return _fail("D: Open lacks its Ctrl+O accelerator (got %d)"
			% file_menu.get_item_accelerator(0))
	if file_menu.get_item_text(0).contains("\t"):
		return _fail("D: shortcut still baked into the label")
	var edit_menu := _root._menu_bar.get_menu_popup(1)
	if edit_menu.get_item_accelerator(1) != (KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT):
		return _fail("D: Redo lacks Ctrl+Shift+Z")
	var theme := _root.theme
	if theme.get_color("font_accelerator_color", "PopupMenu") \
			== theme.get_color("font_color", "PopupMenu"):
		return _fail("D: accelerator colour equals item colour")

	# --- E: embedded window title bars follow the theme ----------------------
	for tid in ["modernist-light", "modernist-dark"]:
		_root.set_theme_id(tid)
		await _idle()
		var eb := _root.theme.get_stylebox("embedded_border", "Window") as StyleBoxFlat
		if eb == null:
			return _fail("E: %s has no embedded_border stylebox" % tid)
		if eb.bg_color != ThemeService.col("titlebar"):
			return _fail("E: %s title bar not the theme titlebar colour" % tid)
		if eb.expand_margin_top != ThemeService.metric("title_height"):
			return _fail("E: %s title bar height not title_height" % tid)
		if _root.theme.get_icon("close", "Window") == null:
			return _fail("E: %s has no themed close glyph" % tid)
	_root.set_theme_id(start_theme)
	await _idle()

	# --- F: user theme folder is seeded --------------------------------------
	var udir := ThemeService.user_theme_dir()
	if not FileAccess.file_exists(udir.path_join("README.txt")):
		return _fail("F: README.txt not seeded in %s" % udir)
	for f in ["modernist-dark.json", "modernist-light.json", "classic-dark.json"]:
		if not FileAccess.file_exists(udir.path_join("examples").path_join(f)):
			return _fail("F: examples/%s not seeded" % f)
	var found_example := false
	for t: Dictionary in ThemeService.available_themes():
		if String(t["path"]).contains("/examples/"):
			found_example = true
	if found_example:
		return _fail("F: examples/ must not be scanned as themes")

	# --- G: view cube --------------------------------------------------------
	var cube := _root.view_cube
	if cube.custom_minimum_size.x < 120:
		return _fail("G: view cube not enlarged")
	var names := {}
	for l in cube.find_children("*", "Label3D", true, false):
		names[(l as Label3D).text] = true
	for want in ["FRONT", "BACK", "TOP", "BOTTOM", "LEFT", "RIGHT", "X", "Y", "Z"]:
		if not names.has(want):
			return _fail("G: view cube lacks the %s label" % want)
	var fr := cube.face_screen_px(Vector3(0, -1, 0))
	if not bool(fr["ok"]):
		return _fail("G: FRONT face not clickable from the home view")

	# --- H: browser root component -------------------------------------------
	_root.browser.refresh()
	var troot := _root.browser.get_root()
	var comp := troot.get_first_child()
	if comp == null or comp.get_text(1) != "Untitled":
		return _fail("H: browser root component row missing")
	if comp.get_icon(1) == null:
		return _fail("H: root component lacks its active marker")
	var folders := {}
	var it := comp.get_first_child()
	while it != null:
		folders[it.get_text(1)] = true
		it = it.get_next()
	for want in ["Origin", "Sketches", "Bodies"]:
		if not folders.has(want):
			return _fail("H: %s folder not under the root component" % want)
	if comp.get_next() != null:
		return _fail("H: folders leaked beside the root component")

	_root.set_show_tool_names(start_names)
	print("M36_SHELL_QA OK: no File group, uniform tool buttons + names pref, "
		+ "flyout stacks, centred menu bar + accelerators, themed title bars, "
		+ "seeded themes folder, labelled view cube, browser root component")
	return true
