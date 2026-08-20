extends SceneTree

# M26: tool shelf + icons + themes. Instantiates the real app; checks every
# tool has a shelf button with icon + tooltip, groups flip with the mode, the
# RPC-facing button names all survived the shelf restructure, and the theme
# switch recolors UI + viewport + persists across a settings reload.

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
	push_error("m26_ui_shell: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	await _idle()
	var initial_dark := ThemeService.dark

	# --- every tool: shelf button, icon asset, tooltip --------------------
	for tid: String in _root.tools.tool_ids():
		var b: Button = _root._tool_buttons.get(tid)
		if b == null:
			return _fail("tool %s has no shelf button" % tid)
		if b.icon == null:
			return _fail("tool %s button has no icon" % tid)
		if b.tooltip_text == "":
			return _fail("tool %s button has no tooltip" % tid)
		var t := _root.tools.get_tool(tid)
		if t.shortcut != KEY_NONE \
				and not b.tooltip_text.contains(OS.get_keycode_string(t.shortcut)):
			return _fail("tool %s tooltip lacks its shortcut" % tid)

	# --- RPC-facing names all reachable (find_child, like query.control) --
	var names := ["CreateSketchBtn", "ExtrudeBtn", "RevolveBtn",
		"OffsetPlaneBtn", "ParametersBtn", "FinishSketchBtn", "UndoBtn",
		"RedoBtn", "SaveBtn", "OpenBtn", "ImportDxfBtn", "ExportDxfBtn",
		"ExportStlBtn", "PivotModeBtn", "PreferencesBtn", "GridSnapChk",
		"InferenceChk", "ConstructionChk", "LineToolBtn", "SelectToolBtn",
		"TrimToolBtn", "DimensionToolBtn", "CoincidentConBtn",
		"SymmetryConBtn", "TangentConBtn"]
	for n: String in names:
		var c := _root.find_child(n, true, false)
		if c == null:
			return _fail("control %s missing after shelf restructure" % n)

	# Action + constraint buttons carry icons too.
	for n: String in ["CreateSketchBtn", "ExtrudeBtn", "RevolveBtn",
			"UndoBtn", "SaveBtn", "CoincidentConBtn", "FixConBtn"]:
		var b := _root.find_child(n, true, false) as Button
		if b == null or b.icon == null:
			return _fail("%s has no icon" % n)

	# --- groups flip with the mode ----------------------------------------
	if not (_root._shelf_groups["Create"] as Control).is_visible_in_tree():
		return _fail("Create group hidden in model mode")
	if (_root._shelf_groups["Sketch"] as Control).is_visible_in_tree():
		return _fail("Sketch group visible in model mode")
	if _root._tool_bar.visible:
		return _fail("tool bar visible in model mode")
	# Menu bar + HUD + browser header + status bar exist (M36 shell).
	for n: String in ["MenuBar", "Ribbon", "Hud", "BrowserHeader",
			"TimelinePanel", "StatusPanel", "UnitBadge", "DocLabel"]:
		if _root.find_child(n, true, false) == null:
			return _fail("M36 shell piece %s missing" % n)
	var fid := _root.create_sketch("XY")
	await _idle()
	if (_root._shelf_groups["Create"] as Control).is_visible_in_tree():
		return _fail("Create group still visible in sketch mode")
	if (_root._shelf_groups["Construct"] as Control).is_visible_in_tree():
		return _fail("Construct group still visible in sketch mode")
	if not (_root._shelf_groups["Sketch"] as Control).is_visible_in_tree():
		return _fail("Sketch group hidden in sketch mode")
	if not _root._tool_bar.visible or not _root._constraint_bar.is_visible_in_tree():
		return _fail("tool/constraint shelves hidden in sketch mode")
	# The shelf must leave the canvas a real working area.
	var vr := _root.viewport_rect()
	if vr.size.y < 400.0:
		return _fail("shelf ate the viewport (canvas %spx tall)" % vr.size.y)
	_root.finish_sketch()
	await _idle()
	var f := _root.doc.sketch_feature(fid)
	if f == null:
		return _fail("sketch feature lost after shelf round trip")

	# --- theme switch: UI theme, 3D env, sketch canvas, persistence -------
	var env: WorldEnvironment = null
	for c in _root.world.get_children():
		if c is WorldEnvironment:
			env = c
	if env == null:
		return _fail("world has no WorldEnvironment")
	_root.set_dark_theme(false)
	if ThemeService.dark:
		return _fail("set_dark_theme(false) did not stick")
	if ThemeService.theme_id != "modernist-light":
		return _fail("set_dark_theme(false) did not pick the light sibling (got %s)"
			% ThemeService.theme_id)
	var light_bg := ThemeService.col("bg3d")
	if light_bg.get_luminance() < 0.5:
		return _fail("light theme bg3d is not light")
	if env.environment.background_color != light_bg:
		return _fail("light theme did not recolor the 3D background")
	if SketchView.bg_color() != light_bg:
		return _fail("light theme did not reach the sketch canvas")
	var th := _root.theme
	if th == null:
		return _fail("no UI theme applied")
	var light_btn := (th.get_stylebox("normal", "Button") as StyleBoxFlat).bg_color
	if light_btn != ThemeService.col("btn"):
		return _fail("UI theme not rebuilt for light mode")
	_root.set_dark_theme(true)
	if env.environment.background_color != ThemeService.col("bg3d") 			or ThemeService.col("bg3d").get_luminance() > 0.5:
		return _fail("dark theme did not restore the 3D background")

	# Persistence: save (via set_dark_theme), corrupt the static, reload.
	_root.set_dark_theme(false)
	ThemeService.dark = true
	ThemeService.load_settings()
	if ThemeService.dark:
		return _fail("settings reload did not restore the saved theme")

	# --- preferences dialog ------------------------------------------------
	_root._open_prefs_dialog()
	await _idle()
	var pick := _root.find_child("ThemePick", true, false) as OptionButton
	if pick == null or pick.item_count < 3:
		return _fail("preferences dialog does not list the built-in themes")
	if String(pick.get_item_metadata(pick.selected)) != "modernist-light":
		return _fail("theme picker out of sync (light should be selected)")
	var dark_idx := -1
	var classic_idx := -1
	for i in pick.item_count:
		if String(pick.get_item_metadata(i)) == "modernist-dark":
			dark_idx = i
		if String(pick.get_item_metadata(i)) == "classic-dark":
			classic_idx = i
	if dark_idx < 0 or classic_idx < 0:
		return _fail("theme picker lacks built-in themes")
	pick.item_selected.emit(dark_idx)
	if not ThemeService.dark or ThemeService.theme_id != "modernist-dark":
		return _fail("picking Modernist Dark in preferences did not switch")
	# A theme that `extends` another: inherits what it does not override.
	pick.item_selected.emit(classic_idx)
	if ThemeService.theme_id != "classic-dark":
		return _fail("picking Classic Dark did not switch")
	if ThemeService.metric("radius") != 4.0:
		return _fail("classic-dark metric override not applied")
	if ThemeService.metric("ribbon_height") != 92.0:
		return _fail("classic-dark did not inherit ribbon_height from its parent")
	if ThemeService.col("accent") == ThemeService.col("ink_construction"):
		return _fail("classic-dark palette re-tint did not resolve")
	# User themes: a file dropped into user://themes shows up after a rescan
	# and can override a built-in by id.
	var udir := ThemeService.user_theme_dir()
	var uf := FileAccess.open(udir.path_join("qa-user-theme.json"), FileAccess.WRITE)
	uf.store_string(JSON.stringify({"id": "qa-user", "name": "QA User",
		"extends": "modernist-dark", "colors": {"accent": "#00ff00"}}))
	uf.close()
	var loaded := _root.set_theme_id("qa-user")
	if loaded != "qa-user" or ThemeService.col("accent") != Color.html("#00ff00"):
		return _fail("user theme from user://themes not loaded (%s)" % loaded)
	if ThemeService.col("text") != Color.html("#dedbda"):
		return _fail("user theme did not inherit text color from modernist-dark")
	DirAccess.remove_absolute(udir.path_join("qa-user-theme.json"))
	# Unknown ids fall back to the default rather than leaving a broken UI.
	if _root.set_theme_id("no-such-theme") != ThemeService.DEFAULT_THEME:
		return _fail("unknown theme id did not fall back to the default")
	_root._prefs_dialog.hide()

	# Leave the user's setting the way we found it.
	_root.set_dark_theme(initial_dark)
	ThemeService.dark = initial_dark
	ThemeService.save_settings()

	print("M26_UI_SHELL OK: shelf groups, icons, tooltips, RPC names, ",
		"theme files (extends, palette refs, user dir) + persistence, prefs dialog")
	return true
