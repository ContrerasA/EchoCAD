class_name BrowserTree
extends Tree
## Fusion-style browser (model mode, left edge): the document's Origin folder
## (axes + the three origin planes) and its Bodies folder (one row per solid).
## Each row carries an eye checkbox that toggles that item's visibility in the
## 3D view.
##
## Visibility here is VIEW state, not model state: it never touches the
## command stack and is not undoable, the same way Fusion treats it. The
## origin planes additionally obey a mode gate in CadWorld — unchecking a
## plane keeps it hidden even while a sketch plane is being picked, but
## checking it does not force it visible in plain model mode.

## Single column: Godot's Tree applies the depth indent and fold arrow to
## column 0 only, so a separate eye column pushed every name a further eye
## width to the right of an already-indented (empty) cell. Eye and name
## share one cell instead (CELL_MODE_CHECK draws the glyph inline before the
## text), which is also how Fusion lays its browser out. Both names are kept
## so callers/tests can keep saying which part of the row they mean.
const COL_EYE := 0
const COL_NAME := 0

var app: AppRoot = null

## Row metadata: TreeItem -> {"kind": "plane"|"origin"|"body", "id": String}.
var _rows := {}


## Right-click context menu (sketch rows): item id -> action.
const MENU_EDIT_SKETCH := 0
const MENU_EXPORT_DXF := 1

var _menu: PopupMenu = null
var _menu_target := ""     # sketch feature id the open menu acts on


func _ready() -> void:
	name = "BrowserTree"
	columns = 1
	set_column_expand(COL_NAME, true)
	hide_root = true
	custom_minimum_size = Vector2(190, 0)
	select_mode = Tree.SELECT_ROW
	allow_rmb_select = true
	item_edited.connect(_on_item_edited)
	item_selected.connect(_on_item_selected)
	item_activated.connect(_on_item_activated)
	item_mouse_selected.connect(_on_item_mouse_selected)


func refresh() -> void:
	if app == null:
		return
	# Rebuilding wholesale keeps the tree honest against timeline rollback and
	# undo, which can add or remove bodies in any order.
	var expanded := _expanded_folders()
	clear()
	_rows.clear()
	var tree_root := create_item()
	# The document is the root COMPONENT (Fusion's top browser row): every
	# folder below belongs to it and it is always the active component. It
	# carries the file name in the accent colour as the activation mark (an
	# icon would shove the name out of line with the folders beneath it).
	# Multi-component documents are backlog (MILESTONES2 M36+).
	var root := create_item(tree_root)
	var doc_name := app.document_title() if app.has_method("document_title") \
			else "Untitled"
	root.set_text(COL_NAME, doc_name)
	root.set_tooltip_text(COL_NAME, "Root component (active)")
	root.set_selectable(COL_NAME, false)
	root.set_custom_color(COL_NAME, ThemeService.col("accent_text"))
	root.collapsed = not expanded.get(doc_name, true)
	_rows[root] = {"kind": "component", "id": ""}

	var origin := create_item(root)
	origin.set_text(COL_NAME, "Origin")
	origin.set_selectable(COL_NAME, false)
	origin.collapsed = not expanded.get("Origin", true)
	_add_row(origin, "origin", "", "Axes", app.world.origin_shown())
	_add_row(origin, "grid", "", "Grid", app.world.grid_shown())
	for plane_name: String in SketchFeature.PLANES:
		_add_row(origin, "plane", plane_name, plane_name,
			app.world.plane_shown(plane_name))

	# Construction planes (M22): their own folder, Fusion-style. Eye ticks map
	# to the same plane-visibility store the origin planes use (keyed by
	# feature id); double-click edits an offset plane's distance.
	var live_planes: Array = []
	for f in app.doc.live_features():
		if f is PlaneFeature:
			live_planes.append(f)
	if not live_planes.is_empty():
		var cons := create_item(root)
		cons.set_text(COL_NAME, "Construction")
		cons.set_selectable(COL_NAME, false)
		cons.collapsed = not expanded.get("Construction", true)
		for pf: PlaneFeature in live_planes:
			_add_row(cons, "cplane", pf.id, pf.name,
				app.world.plane_shown(pf.id))

	# Sketches get their own folder, named and individually hideable, the way
	# Fusion lists them. Without it there is no way to tell which sketch is
	# which, nor to get a finished sketch out of the way — and reference
	# geometry in sketch mode obeys the same ticks, so what you hide stays
	# hidden whichever mode you are in.
	var sketches := create_item(root)
	sketches.set_text(COL_NAME, "Sketches")
	sketches.set_selectable(COL_NAME, false)
	sketches.collapsed = not expanded.get("Sketches", true)
	for f in app.doc.live_features():
		var sf := f as SketchFeature
		if sf == null:
			continue
		var srow := _add_row(sketches, "sketch", sf.id, sf.name,
			app.world.sketch_shown(sf.id))
		if sf.id == app.active_sketch_id:
			srow.set_custom_color(COL_NAME, ThemeService.col("accent_text"))

	# Reference images (M30), Fusion's "Canvases" folder.
	var live_canvases: Array = []
	for f in app.doc.live_features():
		if f is CanvasFeature:
			live_canvases.append(f)
	if not live_canvases.is_empty():
		var canv := create_item(root)
		canv.set_text(COL_NAME, "Canvases")
		canv.set_selectable(COL_NAME, false)
		canv.collapsed = not expanded.get("Canvases", true)
		for cf: CanvasFeature in live_canvases:
			var crow := _add_row(canv, "canvas", cf.id,
				cf.name + ("  🔒" if cf.locked else ""),
				app.world.canvas_shown(cf.id))
			crow.set_selectable(COL_NAME, true)

	var bodies := create_item(root)
	bodies.set_text(COL_NAME, "Bodies")
	bodies.set_selectable(COL_NAME, false)
	bodies.collapsed = not expanded.get("Bodies", true)
	var selected := app.world.selected_body()
	# List the BUILT bodies, not the raw solid features: a Join/Cut feature
	# contributes to an existing body rather than owning a row of its own
	# (QA §M23 — a cut revolve listed as a phantom "Revolve" body whose eye
	# did nothing). Bodies fully consumed by cuts have no mesh left and are
	# skipped, matching what the 3D view instances.
	for b: Dictionary in app.world.bodies():
		var mesh: ArrayMesh = b.get("mesh")
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var fid := String(b["id"])
		var row := _add_row(bodies, "body", fid, String(b["name"]),
			app.world.body_shown(fid))
		if fid == selected:
			row.select(COL_NAME)


## Godot flips a CELL_MODE_CHECK anywhere in the cell, which with eye and
## name sharing one cell would hide a body every time its row is clicked.
## Gate it: a left click that lands in a check cell but right of the eye
## glyph is turned into a plain row selection here and swallowed before the
## Tree sees it. (The setter that does this natively is editor-only.)
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var row := get_item_at_position(mb.position)
	if row == null or row.get_cell_mode(COL_EYE) != TreeItem.CELL_MODE_CHECK:
		return
	if mb.position.x <= _eye_right_edge(row):
		return
	accept_event()
	if mb.double_click:
		if row.is_selectable(COL_NAME):
			item_activated.emit()
		return
	if row.is_selectable(COL_NAME):
		row.select(COL_NAME)
	else:
		deselect_all()


## Screen-x (tree local) where the eye glyph of a row ends. Tree indents
## column 0 by item_margin per visible depth plus one for the fold arrow;
## get_item_area_rect() does not include that indent.
func _eye_right_edge(row: TreeItem) -> float:
	var depth := 0
	var p := row.get_parent()
	while p != null and p != get_root():
		depth += 1
		p = p.get_parent()
	var margin := get_theme_constant("item_margin")
	var x := get_item_area_rect(row, COL_EYE).position.x 		+ margin * (depth + 1) + get_theme_constant("inner_item_margin_left")
	return x + get_theme_icon("checked").get_width() + 4


func _add_row(parent: TreeItem, kind: String, id: String, label: String,
		shown: bool) -> TreeItem:
	var row := create_item(parent)
	row.set_cell_mode(COL_EYE, TreeItem.CELL_MODE_CHECK)
	row.set_checked(COL_EYE, shown)
	row.set_editable(COL_EYE, true)
	row.set_text(COL_NAME, label)
	row.set_selectable(COL_NAME,
		kind == "body" or kind == "sketch" or kind == "cplane")
	_rows[row] = {"kind": kind, "id": id}
	return row


## Remember which folders were open so a refresh does not fold the tree up
## under the user mid-session.
func _expanded_folders() -> Dictionary:
	var out := {}
	var root := get_root()
	if root == null:
		return out
	var comp := root.get_first_child()
	while comp != null:
		out[comp.get_text(COL_NAME)] = not comp.collapsed
		var it := comp.get_first_child()
		while it != null:
			out[it.get_text(COL_NAME)] = not it.collapsed
			it = it.get_next()
		comp = comp.get_next()
	return out


func _on_item_edited() -> void:
	var row := get_edited()
	if row == null or not _rows.has(row):
		return
	var meta: Dictionary = _rows[row]
	var shown: bool = row.is_checked(COL_EYE)
	match String(meta["kind"]):
		"origin":
			app.world.set_origin_shown(shown)
		"grid":
			app.world.set_grid_shown(shown)
		"plane", "cplane":
			app.world.set_plane_shown(String(meta["id"]), shown)
		"body":
			app.world.set_body_shown(String(meta["id"]), shown)
		"sketch":
			app.set_sketch_shown(String(meta["id"]), shown)
		"canvas":
			app.set_canvas_shown(String(meta["id"]), shown)


func _on_item_selected() -> void:
	var row := get_selected()
	if row == null or not _rows.has(row):
		return
	var meta: Dictionary = _rows[row]
	match String(meta["kind"]):
		"body":
			# Deferred: select_body refreshes this tree, and Godot forbids
			# clear/create_item from inside a Tree mouse-selection callback
			# (QA §M23 — the "tree cannot be cleared" error spam).
			app.select_body.call_deferred(String(meta["id"]))
		"sketch":
			# A single click just selects the row (double-click edits, the
			# context menu exports) — matching how bodies behave.
			pass


## The sketch feature id of the selected row, "" when the selection is not a
## sketch. Export DXF reads this so "click a sketch, click Export" works.
func selected_sketch_id() -> String:
	var row := get_selected()
	if row == null or not _rows.has(row):
		return ""
	var meta: Dictionary = _rows[row]
	if String(meta["kind"]) != "sketch":
		return ""
	return String(meta["id"])


## Double-click on a sketch row opens it for editing, Fusion-style; on a
## construction plane it opens the offset editor.
func _on_item_activated() -> void:
	var sid := selected_sketch_id()
	if sid != "":
		app.edit_sketch(sid)
		return
	var row := get_selected()
	if row != null and _rows.has(row) \
			and String((_rows[row] as Dictionary)["kind"]) == "cplane":
		app.edit_plane_offset(String((_rows[row] as Dictionary)["id"]))
		return
	if row != null and _rows.has(row) \
			and String((_rows[row] as Dictionary)["kind"]) == "canvas":
		app.open_canvas_dialog(String((_rows[row] as Dictionary)["id"]))


var _body_menu: PopupMenu = null
var _body_menu_target := ""

const BODY_MENU_EXPORT_STL := 0
const BODY_MENU_PROPERTIES := 1
const BODY_MENU_COLOR := 2

var _cplane_menu: PopupMenu = null
var _cplane_menu_target := ""

const CPLANE_MENU_EDIT := 0
const CPLANE_MENU_DELETE := 1

var _canvas_menu: PopupMenu = null
var _canvas_menu_target := ""

const CANVAS_MENU_EDIT := 0
const CANVAS_MENU_CALIBRATE := 1
const CANVAS_MENU_DELETE := 2


func _on_item_mouse_selected(pos: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var row := get_selected()
	if row == null or not _rows.has(row):
		return
	var meta: Dictionary = _rows[row]
	if String(meta["kind"]) == "body":
		# Body rows get their own context menu (M24: per-body STL export).
		_body_menu_target = String(meta["id"])
		if _body_menu == null:
			_body_menu = PopupMenu.new()
			_body_menu.name = "BodyContextMenu"
			_body_menu.add_item("Export STL...", BODY_MENU_EXPORT_STL)
			_body_menu.add_item("Properties...", BODY_MENU_PROPERTIES)
			_body_menu.add_item("Color...", BODY_MENU_COLOR)
			_body_menu.id_pressed.connect(_on_body_menu_pressed)
			add_child(_body_menu)
		_body_menu.position = Vector2i(get_global_position() + pos)
		_body_menu.popup()
		return
	if String(meta["kind"]) == "cplane":
		# Construction-plane rows: edit the offset or delete the plane (QA
		# §M22.8 — deletion refuses via app.request_delete_feature when a
		# sketch or another plane still uses it).
		_cplane_menu_target = String(meta["id"])
		if _cplane_menu == null:
			_cplane_menu = PopupMenu.new()
			_cplane_menu.name = "CplaneContextMenu"
			_cplane_menu.add_item("Edit Offset...", CPLANE_MENU_EDIT)
			_cplane_menu.add_item("Delete", CPLANE_MENU_DELETE)
			_cplane_menu.id_pressed.connect(_on_cplane_menu_pressed)
			add_child(_cplane_menu)
		_cplane_menu.position = Vector2i(get_global_position() + pos)
		_cplane_menu.popup()
		return
	if String(meta["kind"]) == "canvas":
		_canvas_menu_target = String(meta["id"])
		if _canvas_menu == null:
			_canvas_menu = PopupMenu.new()
			_canvas_menu.name = "CanvasContextMenu"
			_canvas_menu.add_item("Edit Canvas...", CANVAS_MENU_EDIT)
			_canvas_menu.add_item("Calibrate...", CANVAS_MENU_CALIBRATE)
			_canvas_menu.add_item("Delete", CANVAS_MENU_DELETE)
			_canvas_menu.id_pressed.connect(_on_canvas_menu_pressed)
			add_child(_canvas_menu)
		_canvas_menu.position = Vector2i(get_global_position() + pos)
		_canvas_menu.popup()
		return
	if String(meta["kind"]) != "sketch":
		return
	_menu_target = String(meta["id"])
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.name = "SketchContextMenu"
		_menu.add_item("Edit Sketch", MENU_EDIT_SKETCH)
		_menu.add_item("Export DXF...", MENU_EXPORT_DXF)
		_menu.id_pressed.connect(_on_menu_pressed)
		add_child(_menu)
	_menu.position = Vector2i(get_global_position() + pos)
	_menu.popup()


func _on_menu_pressed(id: int) -> void:
	match id:
		MENU_EDIT_SKETCH:
			app.edit_sketch(_menu_target)
		MENU_EXPORT_DXF:
			app.export_dxf_interactive(_menu_target)


func _on_body_menu_pressed(id: int) -> void:
	match id:
		BODY_MENU_EXPORT_STL:
			app.export_stl_interactive(_body_menu_target)
		BODY_MENU_PROPERTIES:
			app.show_body_properties(_body_menu_target)
		BODY_MENU_COLOR:
			app.pick_body_color(_body_menu_target)


func _on_canvas_menu_pressed(id: int) -> void:
	match id:
		CANVAS_MENU_EDIT:
			app.open_canvas_dialog(_canvas_menu_target)
		CANVAS_MENU_CALIBRATE:
			app.start_canvas_calibrate(_canvas_menu_target)
		CANVAS_MENU_DELETE:
			app.request_delete_feature(_canvas_menu_target)


func _on_cplane_menu_pressed(id: int) -> void:
	match id:
		CPLANE_MENU_EDIT:
			app.edit_plane_offset(_cplane_menu_target)
		CPLANE_MENU_DELETE:
			app.request_delete_feature(_cplane_menu_target)
