class_name TimelineBar
extends HBoxContainer
## Fusion-style timeline bar (model mode, bottom of the window): one chip
## per feature in document order with the rollback MARKER between them.
## - double-click a sketch chip: edit it
## - right-click a chip: Edit / Suppress / Delete popup
## - drag the marker handle: roll back/forward (one merged undo step)
## Chips at index >= marker render dimmed+struck (rolled back); suppressed
## chips render dimmed.

var app: AppRoot = null

var _marker_btn: Button = null
var _dragging_marker := false
var _menu: PopupMenu = null
var _menu_feature := ""


func _ready() -> void:
	name = "TimelineBar"
	add_theme_constant_override("separation", 2)
	_menu = PopupMenu.new()
	_menu.name = "TimelineMenu"
	add_child(_menu)
	_menu.id_pressed.connect(_on_menu)


func refresh() -> void:
	for c in get_children():
		if c != _menu:
			remove_child(c)   # out of the tree NOW so name lookups see only
			c.queue_free()    # the fresh chips
	var marker: int = app.doc.timeline_marker
	for i in app.doc.features.size() + 1:
		if i == marker:
			_add_marker()
		if i < app.doc.features.size():
			_add_chip(app.doc.features[i], i)


func _add_marker() -> void:
	_marker_btn = Button.new()
	_marker_btn.name = "TimelineMarker"
	_marker_btn.text = "‖"
	_marker_btn.focus_mode = Control.FOCUS_NONE
	_marker_btn.tooltip_text = "Rollback marker — drag"
	_marker_btn.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_marker_btn.button_down.connect(func() -> void: _dragging_marker = true)
	_marker_btn.button_up.connect(_end_marker_drag)
	add_child(_marker_btn)


func _add_chip(f: Feature, index: int) -> void:
	var b := Button.new()
	b.name = "Chip_" + f.id
	b.text = f.name
	b.focus_mode = Control.FOCUS_NONE
	var rolled: bool = index >= app.doc.timeline_marker
	if f.suppressed or rolled:
		b.modulate = Color(1, 1, 1, 0.45)
	if rolled:
		b.text = "(" + f.name + ")"
	b.gui_input.connect(func(ev: InputEvent) -> void: _on_chip_input(f.id, ev))
	add_child(b)


func _on_chip_input(fid: String, ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		var f := app.doc.feature_by_id(fid)
		if f is SketchFeature and app.doc.features.find(f) < app.doc.timeline_marker:
			app.edit_sketch(fid)
		elif f is PlaneFeature:
			app.edit_plane_offset(fid)
		elif f is CanvasFeature:
			app.open_canvas_dialog(fid)
	elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		_menu_feature = fid
		_menu.clear()
		_menu.add_item("Edit Sketch", 0)
		var f := app.doc.feature_by_id(fid)
		_menu.add_item("Unsuppress" if f != null and f.suppressed else "Suppress", 1)
		_menu.add_item("Delete", 2)
		_menu.position = Vector2i(get_viewport().get_mouse_position()) \
			+ Vector2i(get_window().position)
		_menu.popup()


func _on_menu(id: int) -> void:
	var fid := _menu_feature
	match id:
		0:
			var f := app.doc.feature_by_id(fid)
			if f is SketchFeature:
				app.edit_sketch(fid)
			elif f is PlaneFeature:
				app.edit_plane_offset(fid)
			elif f is CanvasFeature:
				app.open_canvas_dialog(fid)
		1:
			var f := app.doc.feature_by_id(fid)
			if f != null:
				app.stack.push_no_merge(CmdSetFeatureFlag.new(fid,
					"suppressed", not f.suppressed))
		2:
			# Routed through the app so a construction plane that is still
			# referenced refuses deletion instead of orphaning its sketches.
			app.request_delete_feature(fid)


## Marker drag: while held, motion anywhere maps the pointer x to a slot.
func _input(ev: InputEvent) -> void:
	if not _dragging_marker or not (ev is InputEventMouseMotion):
		return
	var gx := (ev as InputEventMouseMotion).global_position.x
	var slot := _slot_for_x(gx)
	if slot != app.doc.timeline_marker:
		app.stack.push(CmdSetMarker.new(app.doc.timeline_marker, slot))


func _end_marker_drag() -> void:
	_dragging_marker = false
	# Seal the merge window so the NEXT drag is its own undo step.
	var top := app.stack.peek()
	if top is CmdSetMarker:
		(top as CmdSetMarker).open = false


func _slot_for_x(gx: float) -> int:
	var slot := 0
	var i := 0
	for c in get_children():
		if c == _menu or c == _marker_btn or not (c is Button):
			continue
		var r := (c as Button).get_global_rect()
		if gx > r.position.x + r.size.x * 0.5:
			slot = i + 1
		i += 1
	return slot
