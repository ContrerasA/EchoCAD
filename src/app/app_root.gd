class_name AppRoot
extends Control
## The application root: owns the document, command stack, mode state, 3D
## viewport (model mode), and SketchView (sketch mode). UI is built in code —
## the .tscn is only this node. Fusion mode model: MODEL (orbit the world,
## pick planes) <-> SKETCH (camera locked normal to the plane, 2D editing).

enum Mode { MODEL, SKETCH }

signal mode_changed(mode: Mode)

var doc: CadDocument
var stack: CommandStack
var bridge: RenderBridge
var mode: Mode = Mode.MODEL
## Feature id of the sketch being edited ("" in model mode).
var active_sketch_id := ""
## True while "Create Sketch" waits for a plane click.
var picking_plane := false

var world: CadWorld
var rig: OrbitCamera
var sketch_view: SketchView
var overlay: Control
var view_cube: ViewCube

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _btn_create: Button
var _btn_finish: Button
var _btn_undo: Button
var _btn_redo: Button
var _status_mode: Label
var _status_hint: Label
var _status_zoom: Label


func _ready() -> void:
	doc = CadDocument.new()
	bridge = RenderBridge.new()
	stack = CommandStack.new(doc)
	stack.changed.connect(_on_stack_changed)
	_build_ui()
	_refresh_ui()


## --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var vbox := VBoxContainer.new()
	vbox.name = "Root"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	var top := HBoxContainer.new()
	top.name = "TopBar"
	vbox.add_child(top)
	_btn_create = _button(top, "Create Sketch", _on_create_sketch)
	_btn_finish = _button(top, "Finish Sketch", _on_finish_sketch)
	_btn_undo = _button(top, "Undo", func() -> void: stack.undo())
	_btn_redo = _button(top, "Redo", func() -> void: stack.redo())

	var stack_area := Control.new()
	stack_area.name = "CanvasStack"
	stack_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack_area.clip_contents = true
	vbox.add_child(stack_area)

	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "ViewportContainer"
	_viewport_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_viewport_container.stretch = true
	_viewport_container.gui_input.connect(_on_viewport_input)
	stack_area.add_child(_viewport_container)
	_viewport = SubViewport.new()
	_viewport.name = "VP3D"
	_viewport_container.add_child(_viewport)
	world = CadWorld.new()
	world.name = "World"
	_viewport.add_child(world)
	rig = OrbitCamera.new()
	rig.name = "Rig"
	_viewport.add_child(rig)
	rig.moved.connect(func() -> void:
		if view_cube != null:
			view_cube.sync_orientation(rig.rotation))

	sketch_view = SketchView.new()
	sketch_view.name = "SketchView"
	sketch_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	sketch_view.bridge = bridge
	sketch_view.visible = false
	sketch_view.view_changed.connect(_refresh_ui)
	stack_area.add_child(sketch_view)

	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack_area.add_child(overlay)

	view_cube = ViewCube.new()
	view_cube.name = "ViewCube"
	view_cube.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	view_cube.position = Vector2(-ViewCube.SIZE_PX - 8, 8)
	view_cube.face_picked.connect(_on_cube_face)
	stack_area.add_child(view_cube)

	var status := HBoxContainer.new()
	status.name = "StatusBar"
	vbox.add_child(status)
	_status_mode = _label(status, "Model")
	_status_hint = _label(status, "")
	_status_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_zoom = _label(status, "")


func _button(parent: Control, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	parent.add_child(l)
	return l


## --- mode transitions --------------------------------------------------------

## Create a NEW sketch on `plane_name` (undoable) and enter sketch mode.
func create_sketch(plane_name: String) -> String:
	var feat := SketchFeature.make(doc.auto_name("Sketch"), plane_name)
	feat.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(feat))
	edit_sketch(feat.id)
	return feat.id


## Enter sketch mode on an EXISTING sketch feature.
func edit_sketch(feature_id: String) -> void:
	var feat := doc.sketch_feature(feature_id)
	if feat == null:
		push_error("[AppRoot] no sketch feature %s" % feature_id)
		return
	active_sketch_id = feature_id
	picking_plane = false
	mode = Mode.SKETCH
	var basis := SketchFeature.plane_basis(feat.plane)
	rig.frame_view(basis.z, basis.y, Vector3.ZERO, 500.0)
	sketch_view.grid_unit = doc.display_unit
	sketch_view.set_view(Vector2.ZERO, 4.0)
	sketch_view.show_sketch(feat.sketch)
	sketch_view.visible = true
	world.set_planes_visible(false)
	mode_changed.emit(mode)
	_refresh_ui()


func finish_sketch() -> void:
	if mode != Mode.SKETCH:
		return
	active_sketch_id = ""
	mode = Mode.MODEL
	sketch_view.visible = false
	world.set_planes_visible(true)
	world.rebuild_sketches(doc)
	mode_changed.emit(mode)
	_refresh_ui()


func active_sketch() -> Sketch:
	var f := doc.sketch_feature(active_sketch_id)
	return f.sketch if f != null else null


## --- input & handlers --------------------------------------------------------

func _on_create_sketch() -> void:
	picking_plane = true
	_refresh_ui()


func _on_finish_sketch() -> void:
	finish_sketch()


func _on_cube_face(normal: Vector3, up: Vector3) -> void:
	if mode == Mode.MODEL:
		rig.frame_view(normal, up)


func _on_viewport_input(event: InputEvent) -> void:
	if mode != Mode.MODEL:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			rig.zoom(1.0 / 1.1)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			rig.zoom(1.1)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_plane:
			var ray := rig.pixel_ray(mb.position)
			var plane := world.pick_plane(ray[0], ray[1])
			if plane != "":
				create_sketch(plane)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			if mm.shift_pressed:
				rig.orbit(mm.relative.x, mm.relative.y)
			else:
				rig.pan(mm.relative.x, mm.relative.y)
		elif picking_plane:
			var ray := rig.pixel_ray(mm.position)
			world.set_plane_hover(world.pick_plane(ray[0], ray[1]))


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	if k.keycode == KEY_Z and k.ctrl_pressed and k.shift_pressed:
		stack.redo()
	elif k.keycode == KEY_Z and k.ctrl_pressed:
		stack.undo()
	elif k.keycode == KEY_ESCAPE and picking_plane:
		picking_plane = false
		world.set_plane_hover("")
		_refresh_ui()


func _on_stack_changed() -> void:
	if mode == Mode.SKETCH:
		var sk := active_sketch()
		# The active sketch may have been undone out of existence.
		if sk == null:
			finish_sketch()
		else:
			sketch_view.mark_dirty()
	else:
		world.rebuild_sketches(doc)
	_refresh_ui()


func _refresh_ui() -> void:
	var in_sketch := mode == Mode.SKETCH
	_btn_create.visible = not in_sketch
	_btn_finish.visible = in_sketch
	_btn_undo.disabled = not stack.can_undo()
	_btn_redo.disabled = not stack.can_redo()
	_status_mode.text = "Sketch" if in_sketch else "Model"
	if picking_plane:
		_status_hint.text = "Select a plane (Esc to cancel)"
	elif in_sketch:
		var f := doc.sketch_feature(active_sketch_id)
		_status_hint.text = "%s on %s" % [f.name, f.plane] if f != null else ""
	else:
		_status_hint.text = ""
	_status_zoom.text = "%d%%" % roundi(sketch_view.zoom() * 25.0) if in_sketch else ""
