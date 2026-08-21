class_name FeatureDialog
extends Window
## M39 — the one dialog shell every feature command uses (extrude, revolve,
## sweep, loft, and everything volume 3 adds). Rows are label + control;
## Enter confirms from any field, Esc cancels, the first field takes focus
## on popup, errors show inline (not only in the status bar), and the
## Targets row arms the app's body picker (arm-then-pick, hover feedback)
## and lists the picked bodies as removable chips.
##
## Control names are the RPC contract (tests click `ExtrudeOkBtn` etc.), so
## every add_* takes the control's name explicitly.

signal confirmed
signal cancelled

var app: AppRoot = null
var _rows: VBoxContainer = null
var _error: Label = null
var _ok: Button = null
var _cancel: Button = null
var _first_field: Control = null
var _fields := {}          # name -> Control
var _row_of := {}          # name -> HBoxContainer
## Targets rows: name -> {chips: HBoxContainer, ids: Array, pick: Button,
##                        label_none: Label}
var _targets := {}
var _label_w := 0.0


static func create(p_app: AppRoot, p_name: String, p_title: String) -> FeatureDialog:
	var d := FeatureDialog.new()
	d.app = p_app
	d.name = p_name
	d.title = p_title
	d.exclusive = false
	d.unresizable = true
	# Size to the rows: the window wraps its content (rows toggle per
	# operation, errors appear under them), min width keeps fields usable.
	d.wrap_controls = true
	d.min_size = Vector2i(int(ThemeService.metric("dialog_min_w", 300.0)), 0)
	d._build()
	return d


func _build() -> void:
	_label_w = ThemeService.metric("dialog_label_w", 84.0)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	var pad := int(ThemeService.metric("dialog_pad", 10.0))
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, pad)
	add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", int(ThemeService.metric("dialog_gap", 6.0)))
	margin.add_child(outer)
	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.add_theme_constant_override("separation", int(ThemeService.metric("dialog_gap", 6.0)))
	outer.add_child(_rows)
	_error = Label.new()
	_error.name = name + "Error"
	_error.theme_type_variation = "DialogErrorLabel"
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.visible = false
	outer.add_child(_error)
	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", int(ThemeService.metric("dialog_gap", 6.0)))
	outer.add_child(buttons)
	_cancel = Button.new()
	_cancel.name = name + "CancelBtn"
	_cancel.text = "Cancel"
	_cancel.focus_mode = Control.FOCUS_NONE
	_cancel.pressed.connect(cancel)
	buttons.add_child(_cancel)
	_ok = Button.new()
	_ok.text = "OK"
	_ok.theme_type_variation = "PrimaryButton"
	_ok.focus_mode = Control.FOCUS_NONE
	_ok.pressed.connect(func() -> void: confirmed.emit())
	buttons.add_child(_ok)
	close_requested.connect(cancel)
	# Esc anywhere in the dialog cancels; Enter confirms (LineEdits also
	# submit through text_submitted, which lands in the same place).
	window_input.connect(_on_window_input)


func set_ok_name(ok_name: String) -> void:
	_ok.name = ok_name


func set_ok_text(text: String) -> void:
	_ok.text = text


func _on_window_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not (ev as InputEventKey).pressed:
		return
	var k := ev as InputEventKey
	if k.keycode == KEY_ESCAPE:
		cancel()
		set_input_as_handled()
	elif (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) \
			and not (get_viewport().gui_get_focus_owner() is TextEdit):
		confirmed.emit()
		set_input_as_handled()


func cancel() -> void:
	hide()
	cancelled.emit()


## --- rows -------------------------------------------------------------------

func _row(name: String, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row_" + name
	row.add_theme_constant_override("separation", int(ThemeService.metric("dialog_gap", 6.0)))
	var lab := Label.new()
	lab.text = label
	lab.theme_type_variation = "DialogLabel"
	lab.custom_minimum_size = Vector2(_label_w, 0)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	_rows.add_child(row)
	_row_of[name] = row
	return row


## A text field. `placeholder` documents the expected input (unit-suffixed
## lengths parse through UnitConverter at commit time).
func add_field(name: String, label: String, control_name: String,
		placeholder := "", initial := "") -> LineEdit:
	var row := _row(name, label)
	var edit := LineEdit.new()
	edit.name = control_name
	edit.placeholder_text = placeholder
	edit.text = initial
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(ThemeService.metric("dialog_field_w", 170.0), 0)
	edit.text_submitted.connect(func(_t: String) -> void: confirmed.emit())
	row.add_child(edit)
	_fields[name] = edit
	if _first_field == null:
		_first_field = edit
	return edit


func add_option(name: String, label: String, control_name: String,
		items: Array, selected := 0) -> OptionButton:
	var row := _row(name, label)
	var pick := OptionButton.new()
	pick.name = control_name
	pick.focus_mode = Control.FOCUS_NONE
	for i in items.size():
		pick.add_item(String(items[i]), i)
	if pick.item_count > 0:
		pick.select(clampi(selected, 0, pick.item_count - 1))
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.custom_minimum_size = Vector2(ThemeService.metric("dialog_field_w", 170.0), 0)
	row.add_child(pick)
	_fields[name] = pick
	return pick


func add_check(name: String, label: String, control_name: String,
		text := "", on := false) -> CheckBox:
	var row := _row(name, label)
	var cb := CheckBox.new()
	cb.name = control_name
	cb.text = text
	cb.button_pressed = on
	cb.focus_mode = Control.FOCUS_NONE
	row.add_child(cb)
	_fields[name] = cb
	return cb


## A read-only line (e.g. "Profile: Sketch2 region").
func add_info(name: String, label: String, text := "") -> Label:
	var row := _row(name, label)
	var lab := Label.new()
	lab.name = name.capitalize().replace(" ", "") + "Info"
	lab.text = text
	lab.theme_type_variation = "DialogLabel"
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(lab)
	_fields[name] = lab
	return lab


## Body targets row: "Auto (touching)" until the user picks; a Pick button
## arms the app's multi-body picker (hover highlight, click toggles,
## Enter / right-click returns), picked bodies show as chips with a ×.
func add_targets(name: String, label: String, control_name: String) -> void:
	var row := _row(name, label)
	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(wrap)
	var top := HBoxContainer.new()
	wrap.add_child(top)
	var none := Label.new()
	none.name = control_name + "Auto"
	none.text = "Auto (bodies it touches)"
	none.theme_type_variation = "DialogLabel"
	none.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(none)
	var pick := Button.new()
	pick.name = control_name
	pick.text = "Pick…"
	pick.tooltip_text = "Click bodies in the viewport to choose the targets (Enter or right-click when done)"
	pick.focus_mode = Control.FOCUS_NONE
	pick.toggle_mode = true
	top.add_child(pick)
	var chips := HFlowContainer.new()
	chips.name = control_name + "Chips"
	wrap.add_child(chips)
	_targets[name] = {"chips": chips, "ids": [], "pick": pick, "label_none": none,
		"control_name": control_name}
	pick.toggled.connect(func(on: bool) -> void:
		if on:
			_begin_target_pick(name)
		else:
			app.end_target_pick())


func _begin_target_pick(name: String) -> void:
	var rec: Dictionary = _targets[name]
	app.begin_target_pick(rec["ids"].duplicate(),
		func(ids: Array) -> void:
			set_targets(name, ids),
		func() -> void:
			(rec["pick"] as Button).set_pressed_no_signal(false)
			_sync_targets(name))


func set_targets(name: String, ids: Array) -> void:
	var rec: Dictionary = _targets[name]
	rec["ids"] = ids.duplicate()
	_sync_targets(name)


func targets(name: String) -> Array:
	return (_targets[name]["ids"] as Array).duplicate()


func _sync_targets(name: String) -> void:
	var rec: Dictionary = _targets[name]
	var chips: HFlowContainer = rec["chips"]
	for c in chips.get_children():
		c.queue_free()
	var ids: Array = rec["ids"]
	(rec["label_none"] as Label).visible = ids.is_empty()
	for id in ids:
		var chip := Button.new()
		chip.name = String(rec["control_name"]) + "Chip_" + String(id)
		chip.text = app.body_display_name(String(id)) + "  ×"
		chip.tooltip_text = "Remove %s from the targets" % app.body_display_name(String(id))
		chip.theme_type_variation = "TargetChip"
		chip.focus_mode = Control.FOCUS_NONE
		chip.pressed.connect(func() -> void:
			rec["ids"].erase(id)
			_sync_targets(name)
			app.set_target_marks(rec["ids"]))
		chips.add_child(chip)
	app.set_target_marks(ids)


## Source row (pattern / mirror): what the command acts on — a BODY (click
## it) or a FEATURE (click one of its faces; every face of that feature
## pre-highlights). Shows the chosen name as a chip and a Pick… toggle that
## arms the app's picker.
## -> the row; read with source_kind(name) / source_id(name).
var _sources := {}     # name -> {kind: OptionButton, chip: Label, pick: Button, id: String}


func add_source(name: String, label: String, control_name: String) -> void:
	var row := _row(name, label)
	var kind := OptionButton.new()
	kind.name = control_name + "Kind"
	kind.focus_mode = Control.FOCUS_NONE
	kind.add_item("Body", 0)
	kind.add_item("Feature", 1)
	kind.tooltip_text = "Body: repeat a whole body. Feature: repeat one cut/join (click one of its faces)."
	row.add_child(kind)
	var chip := Label.new()
	chip.name = control_name + "Name"
	chip.theme_type_variation = "DialogLabel"
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(chip)
	var pick := Button.new()
	pick.name = control_name
	pick.text = "Pick…"
	pick.toggle_mode = true
	pick.focus_mode = Control.FOCUS_NONE
	row.add_child(pick)
	_sources[name] = {"kind": kind, "chip": chip, "pick": pick, "id": ""}
	kind.item_selected.connect(func(_i: int) -> void:
		set_source(name, "")
		# Switching Body <-> Feature re-arms the pick in the new kind.
		if pick.button_pressed:
			_arm_source(name)
		else:
			pick.button_pressed = true)
	pick.toggled.connect(func(on: bool) -> void:
		if on:
			_arm_source(name)
		else:
			app.end_source_pick())
	_sync_source(name)


func _arm_source(name: String) -> void:
	var rec: Dictionary = _sources[name]
	var pick: Button = rec["pick"]
	app.begin_source_pick(source_kind(name),
		func(id: String) -> void:
			set_source(name, id),
		func() -> void:
			pick.set_pressed_no_signal(false))


func set_source(name: String, id: String, kind := "") -> void:
	var rec: Dictionary = _sources[name]
	rec["id"] = id
	if kind != "":
		(rec["kind"] as OptionButton).select(1 if kind == "feature" else 0)
	_sync_source(name)


func source_id(name: String) -> String:
	return String(_sources[name]["id"])


func source_kind(name: String) -> String:
	return "feature" if (_sources[name]["kind"] as OptionButton).selected == 1 else "body"


func _sync_source(name: String) -> void:
	var rec: Dictionary = _sources[name]
	var id := String(rec["id"])
	var chip: Label = rec["chip"]
	if id == "":
		chip.text = "— none picked —"
	else:
		chip.text = app.body_display_name(id) if source_kind(name) == "body" \
			else app.feature_display_name(id)
	app.set_target_marks([id] if id != "" and source_kind(name) == "body" else [])


## --- state ------------------------------------------------------------------

func field(name: String) -> Control:
	return _fields.get(name)


func row(name: String) -> Control:
	return _row_of.get(name)


func set_row_visible(name: String, on: bool) -> void:
	var r: Control = _row_of.get(name)
	if r != null:
		r.visible = on
	_shrink()


## Re-wrap the window around its rows (a hidden row or a cleared error
## would otherwise leave dead space at the bottom).
func _shrink() -> void:
	size = Vector2i(maxi(size.x, min_size.x), 0)


func text_of(name: String) -> String:
	var c: Control = _fields.get(name)
	return (c as LineEdit).text.strip_edges() if c is LineEdit else ""


func selected(name: String) -> int:
	var c: Control = _fields.get(name)
	return (c as OptionButton).selected if c is OptionButton else -1


func checked(name: String) -> bool:
	var c: Control = _fields.get(name)
	return (c as CheckBox).button_pressed if c is CheckBox else false


## Inline error under the rows (also a status-bar hint, so it reads from
## anywhere). "" hides it.
func set_error(msg: String) -> void:
	_error.text = msg
	_error.visible = msg != ""
	if msg != "" and app != null:
		app.set_status_hint(title + ": " + msg)
	_shrink()


## Show docked at the viewport's top-right (Fusion's placement — the model
## stays clear for the picks the dialog asks for), first field focused,
## errors cleared.
func open() -> void:
	set_error("")
	_shrink()
	show()
	var vr: Rect2 = app.viewport_rect() if app != null else get_parent().get_viewport().get_visible_rect()
	var gap := int(ThemeService.metric("dialog_gap", 6.0)) * 2
	position = Vector2i(maxi(int(vr.end.x) - size.x - gap, 0), maxi(int(vr.position.y) + gap, 0))
	if _first_field != null:
		_first_field.grab_focus()
		if _first_field is LineEdit:
			(_first_field as LineEdit).select_all()


func close() -> void:
	hide()
	for name in _targets:
		((_targets[name] as Dictionary)["pick"] as Button).set_pressed_no_signal(false)
	for name in _sources:
		((_sources[name] as Dictionary)["pick"] as Button).set_pressed_no_signal(false)
	if app != null:
		app.end_target_pick()
		app.end_source_pick()
		app.set_target_marks([])
