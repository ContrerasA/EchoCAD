extends SceneTree

# M46: autosave writes only when dirty and is cleared by save; a pending
# autosave is recovered into a dirty document; the unsaved guard runs the
# action only when clean; recent files list; a newer-schema file is
# refused with a message; prefs survive a save of unrelated keys; the
# start panel shows/hides.

var _root: AppRoot = null
const TMP := "user://m46_tmp"


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M46_DOC_SAFETY OK: autosave + recovery, unsaved guard, recent files, "
			+ "newer-schema refusal, prefs durability, start panel")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m46_doc_safety: " + msg)
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var dir := ProjectSettings.globalize_path(TMP)
	# Start clean: no leftovers from earlier runs.
	for rec: Dictionary in _root.pending_recoveries():
		for p in [String(rec["path"]), String(rec["path"]) + ".meta"]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

	# --- A. autosave only when dirty; cleared by save -------------------------
	if _root.autosave_now():
		return _fail("A: a clean document must not autosave")
	var s1 := _root.create_sketch("XY")
	_root.finish_sketch()
	await _idle()
	if not _root.stack.is_dirty():
		return _fail("A: creating a sketch should dirty the document")
	if not _root.autosave_now():
		return _fail("A: dirty document should autosave")
	if not FileAccess.file_exists(_root.autosave_path()):
		return _fail("A: autosave file missing at %s" % _root.autosave_path())
	if _root.pending_recoveries().size() != 1:
		return _fail("A: one pending recovery expected")
	var path := dir.path_join("doc.ecad")
	if not _root.save_to(path):
		return _fail("A: save failed")
	if FileAccess.file_exists(_root.autosave_path()) or not _root.pending_recoveries().is_empty():
		return _fail("A: saving should clear the autosave")
	if _root.stack.is_dirty():
		return _fail("A: saved document should be clean")

	# --- B. recovery: dirty again, autosave, 'crash', recover into a dirty doc
	var s2 := _root.create_sketch("XZ")
	_root.finish_sketch()
	await _idle()
	_root.autosave_now()
	var rec_list := _root.pending_recoveries()
	if rec_list.size() != 1 or String(rec_list[0]["source"]) != path:
		return _fail("B: recovery should remember the source path (%s)" % str(rec_list))
	# Simulate a new session: fresh empty document, then recover.
	_root.load_document(CadDocument.new())
	_root.stack.mark_saved()
	if not _root.recover_from(rec_list[0]):
		return _fail("B: recovery failed")
	if _root.doc.features.size() != 2:
		return _fail("B: recovered document should hold 2 sketches, got %d" % _root.doc.features.size())
	if not _root.stack.is_dirty():
		return _fail("B: recovered work must read as unsaved")
	if not _root.pending_recoveries().is_empty():
		return _fail("B: recovery should consume the autosave")
	if _root.document_title() != "doc":
		return _fail("B: recovered document should keep its file name (%s)" % _root.document_title())

	# --- C. unsaved guard ---------------------------------------------------------
	var ran := [false]
	_root.guard_unsaved("Test", func() -> void: ran[0] = true)
	if ran[0]:
		return _fail("C: guard must not run the action while dirty")
	if _root._guard_dialog == null or not _root._guard_dialog.visible:
		return _fail("C: guard should show the Save / Don't save / Cancel dialog")
	# Don't save -> the action runs.
	_root._guard_dialog.custom_action.emit(&"discard")
	if not ran[0]:
		return _fail("C: Don't save should run the action")
	_root.save_to(path)
	ran[0] = false
	_root.guard_unsaved("Test", func() -> void: ran[0] = true)
	if not ran[0]:
		return _fail("C: a clean document runs the action immediately")

	# --- D. recent files -------------------------------------------------------
	var recents := _root.recent_files()
	if recents.is_empty() or String(recents[0]) != path:
		return _fail("D: saved file should top the recent list: %s" % str(recents))
	var path2 := dir.path_join("other.ecad")
	_root.save_to(path2)
	recents = _root.recent_files()
	if String(recents[0]) != path2 or String(recents[1]) != path:
		return _fail("D: recent order: %s" % str(recents))
	if _root._recent_menu == null or _root._recent_menu.item_count < 2:
		return _fail("D: Open Recent menu not populated")

	# --- E. a newer-schema file is refused ------------------------------------
	var newer := JSON.parse_string(Serializer.to_json(_root.doc)) as Dictionary
	newer["version"] = CadDocument.SCHEMA_VERSION + 5
	var path3 := dir.path_join("future.ecad")
	var f := FileAccess.open(path3, FileAccess.WRITE)
	f.store_string(JSON.stringify(newer))
	f.close()
	var before := _root.doc.features.size()
	if _root.open_from(path3):
		return _fail("E: newer schema should be refused")
	if not Serializer.last_error.contains("newer"):
		return _fail("E: refusal should explain (%s)" % Serializer.last_error)
	if _root.doc.features.size() != before:
		return _fail("E: refused open must leave the document alone")
	for c in _root.get_children():
		if c.name == "AlertDialog":
			(c as Window).hide()

	# --- F. prefs durability: unrelated keys survive theme saves ------------------
	ThemeService.set_pref("m46_probe", 42)
	ThemeService.save_settings()
	ThemeService.load_settings()
	if int(ThemeService.get_pref("m46_probe", 0)) != 42:
		return _fail("F: prefs should survive theme save/load")
	var cfg := ConfigFile.new()
	cfg.load(ThemeService.settings_path())
	if String(cfg.get_value("ui", "theme", "")) == "":
		return _fail("F: theme key lost")

	# --- G. start panel --------------------------------------------------------
	_root.load_document(CadDocument.new())
	_root.stack.mark_saved()
	_root.show_start_panel()
	await _idle()
	var panel := _root.find_child("StartPanel", true, false)
	if panel == null:
		return _fail("G: start panel missing")
	var nb := _root.find_child("StartNewSketchBtn", true, false) as Button
	if nb == null:
		return _fail("G: start panel New Sketch button missing")
	nb.pressed.emit()
	await _idle()
	if _root.find_child("StartPanel", true, false) != null and is_instance_valid(panel) and panel.is_inside_tree():
		return _fail("G: start panel should dismiss on New Sketch")
	if not _root.picking_plane:
		return _fail("G: New Sketch should arm the plane pick")
	_root.handle_cancel() if _root.has_method("handle_cancel") else null
	return true
