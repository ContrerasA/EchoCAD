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

const COL_EYE := 0
const COL_NAME := 1

var app: AppRoot = null

## Row metadata: TreeItem -> {"kind": "plane"|"origin"|"body", "id": String}.
var _rows := {}


func _ready() -> void:
	name = "BrowserTree"
	columns = 2
	set_column_expand(COL_EYE, false)
	set_column_custom_minimum_width(COL_EYE, 28)
	set_column_expand(COL_NAME, true)
	hide_root = true
	custom_minimum_size = Vector2(190, 0)
	select_mode = Tree.SELECT_ROW
	item_edited.connect(_on_item_edited)
	item_selected.connect(_on_item_selected)


func refresh() -> void:
	if app == null:
		return
	# Rebuilding wholesale keeps the tree honest against timeline rollback and
	# undo, which can add or remove bodies in any order.
	var expanded := _expanded_folders()
	clear()
	_rows.clear()
	var root := create_item()

	var origin := create_item(root)
	origin.set_text(COL_NAME, "Origin")
	origin.set_selectable(COL_EYE, false)
	origin.set_selectable(COL_NAME, false)
	origin.collapsed = not expanded.get("Origin", true)
	_add_row(origin, "origin", "", "Axes", app.world.origin_shown())
	_add_row(origin, "grid", "", "Grid", app.world.grid_shown())
	for plane_name: String in SketchFeature.PLANES:
		_add_row(origin, "plane", plane_name, plane_name,
			app.world.plane_shown(plane_name))

	# Sketches get their own folder, named and individually hideable, the way
	# Fusion lists them. Without it there is no way to tell which sketch is
	# which, nor to get a finished sketch out of the way — and reference
	# geometry in sketch mode obeys the same ticks, so what you hide stays
	# hidden whichever mode you are in.
	var sketches := create_item(root)
	sketches.set_text(COL_NAME, "Sketches")
	sketches.set_selectable(COL_EYE, false)
	sketches.set_selectable(COL_NAME, false)
	sketches.collapsed = not expanded.get("Sketches", true)
	for f in app.doc.live_features():
		var sf := f as SketchFeature
		if sf == null:
			continue
		var srow := _add_row(sketches, "sketch", sf.id, sf.name,
			app.world.sketch_shown(sf.id))
		if sf.id == app.active_sketch_id:
			srow.set_custom_color(COL_NAME, Color(1.0, 0.85, 0.3))

	var bodies := create_item(root)
	bodies.set_text(COL_NAME, "Bodies")
	bodies.set_selectable(COL_EYE, false)
	bodies.set_selectable(COL_NAME, false)
	bodies.collapsed = not expanded.get("Bodies", true)
	var selected := app.world.selected_body()
	for f in app.doc.live_features():
		if not (f is ExtrudeFeature):
			continue
		var row := _add_row(bodies, "body", f.id, f.name,
			app.world.body_shown(f.id))
		if f.id == selected:
			row.select(COL_NAME)


func _add_row(parent: TreeItem, kind: String, id: String, label: String,
		shown: bool) -> TreeItem:
	var row := create_item(parent)
	row.set_cell_mode(COL_EYE, TreeItem.CELL_MODE_CHECK)
	row.set_checked(COL_EYE, shown)
	row.set_editable(COL_EYE, true)
	row.set_selectable(COL_EYE, false)
	row.set_text(COL_NAME, label)
	row.set_selectable(COL_NAME, kind == "body" or kind == "sketch")
	_rows[row] = {"kind": kind, "id": id}
	return row


## Remember which folders were open so a refresh does not fold the tree up
## under the user mid-session.
func _expanded_folders() -> Dictionary:
	var out := {}
	var root := get_root()
	if root == null:
		return out
	var it := root.get_first_child()
	while it != null:
		out[it.get_text(COL_NAME)] = not it.collapsed
		it = it.get_next()
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
		"plane":
			app.world.set_plane_shown(String(meta["id"]), shown)
		"body":
			app.world.set_body_shown(String(meta["id"]), shown)
		"sketch":
			app.set_sketch_shown(String(meta["id"]), shown)


func _on_item_selected() -> void:
	var row := get_selected()
	if row == null or not _rows.has(row):
		return
	var meta: Dictionary = _rows[row]
	match String(meta["kind"]):
		"body":
			app.select_body(String(meta["id"]))
		"sketch":
			# Double-click opens a sketch for editing; a single click just
			# selects the row, matching how bodies behave.
			pass
