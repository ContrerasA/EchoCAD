extends SceneTree

# QA volume 2 fixes (§M22–§M25):
# - browser lists BUILT bodies, so a cut/join feature never shows as a
#   phantom body row (§M23 issue),
# - revolve axis pick resolves the drawn sketch axes by click, not just the
#   X/Y keys (§M23.1), and world grows candidate/hover overlays (§M23.6),
# - construction-plane context menu delete honours the reference guard
#   (§M22.8),
# - DXF import takes a target plane (§M25.1 — the interactive dialog feeds
#   the same parameter).

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
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m25_qa_fixes: " + msg)
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


func _sketch_rect(plane: String, a: Vector2, b: Vector2) -> String:
	var fid := _root.create_sketch(plane)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	return fid


## Body rows currently in the browser: [{id, label}].
func _body_rows() -> Array:
	var out: Array = []
	for row: TreeItem in _root.browser._rows:
		var meta: Dictionary = _root.browser._rows[row]
		if String(meta["kind"]) == "body":
			out.append({"id": String(meta["id"]),
				"label": row.get_text(BrowserTree.COL_NAME)})
	return out


## An XY-plane pick ray straight down onto sketch uv `at`.
func _ray_at(at: Vector2) -> Array:
	return [Vector3(at.x, at.y, 50.0), Vector3(0, 0, -1)]


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A: cut features do not get body rows -------------------------------
	var f1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	var e1 := _root.extrude(f1, Vector2(2, 2), 10.0)
	var f2 := _sketch_rect("XY", Vector2(10, 10), Vector2(20, 20))
	_root.finish_sketch()
	var e2 := _root.extrude(f2, Vector2(15, 15), 10.0, ExtrudeFeature.OP_CUT)
	if e1 == "" or e2 == "":
		return _fail("extrudes refused")
	await _idle()
	_root.browser.refresh()
	var rows := _body_rows()
	if rows.size() != 1:
		return _fail("browser should list 1 body, has %d" % rows.size())
	if String((rows[0] as Dictionary)["id"]) != e1:
		return _fail("body row should be the NEW_BODY root, is %s"
			% str(rows[0]))

	# --- B: revolve axis pick — sketch axes by click ------------------------
	_root.load_document(CadDocument.new())
	var f3 := _sketch_rect("XY", Vector2(20, 0), Vector2(30, 10))
	_root.finish_sketch()
	_root._pending_revolve = {"sketch_id": f3, "at": Vector2(25, 5)}
	var r1 := _ray_at(Vector2(5, 0.2))
	var p1 := _root._axis_pick_under_ray(r1[0], r1[1])
	if p1.is_empty() or String(p1["axis"]) != "x":
		return _fail("near the u axis the pick should say x, got %s" % str(p1))
	var r2 := _ray_at(Vector2(0.2, 5))
	var p2 := _root._axis_pick_under_ray(r2[0], r2[1])
	if p2.is_empty() or String(p2["axis"]) != "y":
		return _fail("near the v axis the pick should say y, got %s" % str(p2))
	# Near the rectangle's top edge the LINE entity must win over the axes.
	var r3 := _ray_at(Vector2(25, 10.05))
	var p3 := _root._axis_pick_under_ray(r3[0], r3[1])
	if p3.is_empty():
		return _fail("no pick near the rectangle's top edge")
	var sf3 := _root.doc.sketch_feature(f3)
	var ent := sf3.sketch.entity(String(p3["axis"]))
	if ent == null or ent.kind() != "line":
		return _fail("top-edge pick should be a line entity, got %s"
			% String(p3["axis"]))
	# The picked axis revolves: keyboard and click paths share this call.
	var rid := _root.revolve(f3, Vector2(25, 5), String(p2["axis"]), 360.0)
	if rid == "":
		return _fail("revolve about the clicked y axis refused")
	_root.stack.undo()

	# --- C: axis candidate + hover overlays ---------------------------------
	_root.world.show_axis_candidates(sf3)
	if _root.world._axis_candidates_mi == null:
		return _fail("show_axis_candidates built nothing")
	_root.world.set_axis_hover(sf3, "x", Vector2(-150, 0), Vector2(150, 0), 2.0)
	if _root.world._axis_hover_mi == null:
		return _fail("set_axis_hover built nothing")
	_root.world.clear_axis_hover()
	if _root.world._axis_hover_mi != null:
		return _fail("clear_axis_hover left the overlay behind")
	_root.world.hide_axis_candidates()
	if _root.world._axis_candidates_mi != null:
		return _fail("hide_axis_candidates left the lines behind")

	# --- D: construction-plane context-menu delete guard --------------------
	_root.load_document(CadDocument.new())
	var pid := _root.create_offset_plane("XY", 25.4)
	var sid := _root.create_sketch(pid)
	_root.finish_sketch()
	_root.browser.refresh()
	_root.browser._cplane_menu_target = pid
	_root.browser._on_cplane_menu_pressed(BrowserTree.CPLANE_MENU_DELETE)
	if _root.doc.feature_by_id(pid) == null:
		return _fail("delete should refuse while a sketch uses the plane")
	var pid2 := _root.create_offset_plane(pid, 12.7)
	_root.browser._cplane_menu_target = pid2
	_root.browser._on_cplane_menu_pressed(BrowserTree.CPLANE_MENU_DELETE)
	if _root.doc.feature_by_id(pid2) != null:
		return _fail("unreferenced plane should delete from the context menu")
	if _root.doc.feature_by_id(sid) == null:
		return _fail("plane delete took the sketch with it")

	# --- E: cplane context menu opens through the real popup path -----------
	var pid3 := _root.create_offset_plane("XY", 10.0)
	_root.browser.refresh()
	var cplane_row: TreeItem = null
	for row: TreeItem in _root.browser._rows:
		var meta: Dictionary = _root.browser._rows[row]
		if String(meta["kind"]) == "cplane" and String(meta["id"]) == pid3:
			cplane_row = row
			break
	if cplane_row == null:
		return _fail("no cplane row for the offset plane")
	cplane_row.select(BrowserTree.COL_NAME)
	_root.browser._on_item_mouse_selected(Vector2(10, 10), MOUSE_BUTTON_RIGHT)
	if _root.browser._cplane_menu == null \
			or not _root.browser._cplane_menu.visible:
		return _fail("right-click on a cplane row did not open its menu")
	if _root.browser._cplane_menu_target != pid3:
		return _fail("cplane menu targets %s, want %s"
			% [_root.browser._cplane_menu_target, pid3])
	_root.browser._cplane_menu.hide()

	# --- F: DXF import dialog — plane dropdown feeds import_dxf -------------
	_root.load_document(CadDocument.new())
	var before: Array = []
	for f in _root.doc.live_features():
		before.append(f.id)
	_root.import_dxf_interactive()
	if _root._dxf_import_plane == null:
		return _fail("import dialog has no plane dropdown")
	var xz_idx := -1
	for i in _root._dxf_import_plane.item_count:
		if String(_root._dxf_import_plane.get_item_metadata(i)) == "XZ":
			xz_idx = i
			break
	if xz_idx < 0:
		return _fail("plane dropdown does not list XZ")
	_root._dxf_import_plane.selected = xz_idx
	_root._dxf_import_dialog.hide()
	_root._dxf_import_dialog.file_selected.emit(
		ProjectSettings.globalize_path("res://tests/M25.dxf"))
	var imported: SketchFeature = null
	for f in _root.doc.live_features():
		if f is SketchFeature and not before.has(f.id):
			imported = f
	if imported == null:
		return _fail("dialog-path import produced no sketch")
	if imported.plane != "XZ":
		return _fail("dialog-path import landed on %s, want XZ"
			% imported.plane)
	if imported.sketch.entities().is_empty():
		return _fail("dialog-path import produced an empty sketch")

	# --- G: STL metres option scales 1000x down for Blender -----------------
	_root.load_document(CadDocument.new())
	var f4 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	if _root.extrude(f4, Vector2(2, 2), 10.0) == "":
		return _fail("box extrude refused")
	await _idle()
	var dir := OS.get_cache_dir().path_join("echocad_m25_qa")
	DirAccess.make_dir_recursive_absolute(dir)
	var p_m := dir.path_join("box_m.stl")
	if not _root.export_stl(p_m, "", false, 0.001):
		return _fail("metre-scaled export failed")
	var fh := FileAccess.open(p_m, FileAccess.READ)
	var header := fh.get_buffer(80).get_string_from_ascii()
	var count := fh.get_32()
	var vol := 0.0
	for t in count:
		for i in 3:
			fh.get_float()   # facet normal
		var a := Vector3(fh.get_float(), fh.get_float(), fh.get_float())
		var b := Vector3(fh.get_float(), fh.get_float(), fh.get_float())
		var c := Vector3(fh.get_float(), fh.get_float(), fh.get_float())
		fh.get_16()
		vol += a.cross(b).dot(c) / 6.0
	fh.close()
	if not header.contains("units: m"):
		return _fail("metre export header should say units: m, got %s" % header)
	# 40 x 30 x 10 mm = 0.04 x 0.03 x 0.01 m -> 1.2e-5 m^3.
	if absf(absf(vol) - 1.2e-5) > 1e-7:
		return _fail("metre-scaled volume wrong: %e" % absf(vol))

	print("M25_QA_FIXES OK: browser lists built bodies only, revolve axis "
		+ "click-pick + overlays, cplane menu delete guard + popup path, "
		+ "DXF import plane dropdown, STL metre scale")
	return true
