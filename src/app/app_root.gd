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
var tools: ToolManager
var snap: SnapEngine
## User toggles read by tools. Mutate via RPC action.set_pref or UI.
var prefs := {"inference": true}
## Selected entity ids in the active sketch.
var selection: Array[String] = []
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
var _tool_bar: HBoxContainer
var _tool_buttons := {}
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
	snap = SnapEngine.new()
	tools = ToolManager.new(self)
	tools.register(SelectTool.new())
	tools.register(LineTool.new())
	tools.register(RectTool.new())
	tools.register(CenterRectTool.new())
	tools.register(CircleTool.new())
	tools.register(ThreePointCircleTool.new())
	tools.register(ThreePointArcTool.new())
	tools.register(CenterArcTool.new())
	tools.register(TangentArcTool.new())
	tools.register(PointTool.new())
	tools.overlay_needs_redraw.connect(func() -> void: overlay.queue_redraw())
	tools.active_changed.connect(func(_id: String) -> void: _refresh_ui())
	_build_ui()
	_refresh_ui()
	_maybe_start_automation()


func set_selection(ids: Array) -> void:
	selection.clear()
	for i in ids:
		selection.append(String(i))
	overlay.queue_redraw()


## Exclusions persist across the mid-gesture rebuilds triggered by
## _on_stack_changed — otherwise the first command of a drag would clobber
## the drag's self-exclusion and the dragged point would snap to itself.
var _snap_exclude: Array = []


func rebuild_snap_index(exclude = []) -> void:
	_snap_exclude = exclude if exclude is Array else Array(exclude.keys())
	snap.build_index(active_sketch(), _snap_exclude)


## Re-solve the active sketch with `pinned` point ids held fixed, pushing
## follower moves onto the stack (they merge into an open CmdMergeBatch, so
## a drag plus its re-solve stays ONE undo step).
func solve_followers(pinned = []) -> void:
	var sk := active_sketch()
	if sk == null or sk.constraints.is_empty():
		return
	var res := ConstraintSolver.solve(sk, pinned)
	var pts: Dictionary = res["points"]
	var radii: Dictionary = res["radii"]
	if not pts.is_empty():
		stack.push(CmdMovePoints.new(active_sketch_id, pts))
	if not radii.is_empty():
		stack.push(CmdSetRadii.new(active_sketch_id, radii))


## Replace the whole document (open/new). History is cleared — a loaded file
## starts with a clean timeline of its own.
func load_document(new_doc: CadDocument) -> void:
	doc = new_doc
	stack.doc = new_doc
	stack.clear()
	active_sketch_id = ""
	picking_plane = false
	mode = Mode.MODEL
	sketch_view.visible = false
	world.set_planes_visible(true)
	world.rebuild_sketches(doc)
	mode_changed.emit(mode)
	_refresh_ui()


func _maybe_start_automation() -> void:
	var port := 0
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--automation-port="):
			port = arg.get_slice("=", 1).to_int()
	if port == 0 and OS.get_environment("ECHOCAD_AUTOMATION_PORT") != "":
		port = OS.get_environment("ECHOCAD_AUTOMATION_PORT").to_int()
	if port <= 0:
		return
	var server := AutomationServer.new()
	server.name = "AutomationServer"
	server.app = self
	add_child(server)
	server.start(port)


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
	_btn_create.name = "CreateSketchBtn"
	_btn_finish = _button(top, "Finish Sketch", _on_finish_sketch)
	_btn_finish.name = "FinishSketchBtn"
	_btn_undo = _button(top, "Undo", func() -> void: stack.undo())
	_btn_undo.name = "UndoBtn"
	_btn_redo = _button(top, "Redo", func() -> void: stack.redo())
	_btn_redo.name = "RedoBtn"
	_tool_bar = HBoxContainer.new()
	_tool_bar.name = "ToolBar"
	top.add_child(_tool_bar)
	var group := ButtonGroup.new()
	for tid: String in tools.tool_ids():
		var t := tools.get_tool(tid)
		var b := Button.new()
		var parts := tid.split("_")
		var pascal := ""
		for part in parts:
			pascal += part.substr(0, 1).to_upper() + part.substr(1)
		b.name = pascal + "ToolBtn"
		b.text = t.title
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: tools.set_active(tid))
		_tool_bar.add_child(b)
		_tool_buttons[tid] = b

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
	sketch_view.view_changed.connect(_on_sketch_view_changed)
	sketch_view.tool_input = _on_tool_input
	sketch_view.key_handler = handle_app_key
	stack_area.add_child(sketch_view)

	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_on_overlay_draw)
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
	b.focus_mode = Control.FOCUS_NONE   # keys belong to the canvas, not buttons
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
	set_selection([])
	tools.set_active("select")
	rebuild_snap_index()
	sketch_view.grab_focus()
	mode_changed.emit(mode)
	_refresh_ui()


func finish_sketch() -> void:
	if mode != Mode.SKETCH:
		return
	tools.set_active("")
	set_selection([])
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
	if handle_app_key(k):
		get_viewport().set_input_as_handled()


## One key-routing funnel used by both the focused SketchView (gets Tab and
## Enter before focus traversal) and the unhandled fallback.
func handle_app_key(k: InputEventKey) -> bool:
	if k.keycode == KEY_Z and k.ctrl_pressed and k.shift_pressed:
		stack.redo()
		return true
	if k.keycode == KEY_Z and k.ctrl_pressed:
		stack.undo()
		return true
	if k.keycode == KEY_ESCAPE:
		if mode == Mode.SKETCH and tools.handle_cancel():
			return true
		if picking_plane:
			picking_plane = false
			world.set_plane_hover("")
			_refresh_ui()
			return true
		return false
	if (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and mode == Mode.SKETCH:
		return tools.handle_commit()
	if mode == Mode.SKETCH and not k.ctrl_pressed:
		# Type-in fields get first claim on keys (digits, Tab, units...).
		var active := tools.get_tool(tools.active_id())
		if active != null and active.key_input(k):
			overlay.queue_redraw()
			return true
		for tid: String in tools.tool_ids():
			if tools.get_tool(tid).shortcut == k.keycode:
				tools.set_active(tid)
				return true
	return false


func _on_tool_input(world_pos: Vector2, screen: Vector2, event: InputEvent) -> bool:
	if mode != Mode.SKETCH:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			return tools.handle_pointer_down(world_pos, screen, mb)
		return tools.handle_pointer_up(world_pos, screen, mb)
	if event is InputEventMouseMotion:
		_status_hint.text = "%s, %s" % [
			UnitConverter.format(world_pos.x, doc.display_unit),
			UnitConverter.format(world_pos.y, doc.display_unit)]
		return tools.handle_pointer_move(world_pos, screen,
			event as InputEventMouseMotion)
	return false


func _on_sketch_view_changed() -> void:
	overlay.queue_redraw()
	_refresh_ui()


## Editor chrome: sketch points, selection highlights, then the active
## tool's own overlay. Screen space; artwork itself is the ThorVG raster.
func _on_overlay_draw() -> void:
	if mode != Mode.SKETCH:
		return
	var sk := active_sketch()
	if sk == null:
		return
	var v := sketch_view
	for e in sk.entities():
		if e.kind() == "point":
			var p := v.world_to_screen((e as SketchPoint).pos)
			var sel := selection.has(e.id)
			var c := Color(1.0, 0.85, 0.3) if sel else Color(0.85, 0.88, 0.95)
			overlay.draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5, 5)), c)
	for id in selection:
		var e := sk.entity(id)
		if e == null:
			continue
		_draw_selected_entity(sk, e)
	tools.draw_overlay(overlay)


func _draw_selected_entity(sk: Sketch, e: SketchEntity) -> void:
	var v := sketch_view
	var c := Color(1.0, 0.85, 0.3)
	match e.kind():
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0)
			var b := sk.point(l.p1)
			if a != null and b != null:
				overlay.draw_line(v.world_to_screen(a.pos),
					v.world_to_screen(b.pos), c, 2.0)
		"circle":
			var ci := e as SketchCircle
			var cp := sk.point(ci.center)
			if cp != null:
				overlay.draw_arc(v.world_to_screen(cp.pos),
					ci.radius * v.zoom(), 0, TAU, 64, c, 2.0)
		"arc":
			var arc := e as SketchArc
			var cp := sk.point(arc.center)
			var sp := sk.point(arc.start)
			if cp != null and sp != null:
				var r := cp.pos.distance_to(sp.pos)
				var a0 := (sp.pos - cp.pos).angle()
				var sweep := SketchGeometry.arc_sweep(sk, arc)
				# Screen space is Y-down: angles negate.
				overlay.draw_arc(v.world_to_screen(cp.pos), r * v.zoom(),
					-a0, -(a0 + sweep), 48, c, 2.0)


func _on_stack_changed() -> void:
	if mode == Mode.SKETCH:
		var sk := active_sketch()
		# The active sketch may have been undone out of existence.
		if sk == null:
			finish_sketch()
		else:
			var live: Array[String] = []
			for id in selection:
				if sk.has(id):
					live.append(id)
			selection = live
			snap.build_index(sk, _snap_exclude)   # keep gesture exclusions
			sketch_view.mark_dirty()
			overlay.queue_redraw()
	else:
		world.rebuild_sketches(doc)
	_refresh_ui()


func _refresh_ui() -> void:
	var in_sketch := mode == Mode.SKETCH
	_btn_create.visible = not in_sketch
	_btn_finish.visible = in_sketch
	_tool_bar.visible = in_sketch
	for tid: String in _tool_buttons:
		(_tool_buttons[tid] as Button).set_pressed_no_signal(
			tid == tools.active_id())
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
