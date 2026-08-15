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
## Selected constraint index in the active sketch (-1 = none).
var selected_constraint := -1
## Latest DOF analysis of the active sketch ({} when stale/unavailable).
var dof := {}
## Constraint badge hit rects from the last overlay draw: [{index, rect}].
var badge_hits: Array = []
## Dimension label hit rects from the last overlay draw: [{index, rect}].
var dim_hits: Array = []
var mode: Mode = Mode.MODEL
## Feature id of the sketch being edited ("" in model mode).
var active_sketch_id := ""
## True while "Create Sketch" waits for a plane click.
var picking_plane := false
## True while "Extrude" waits for a profile click.
var picking_profile := false
## Pending extrude target set by the profile click: {sketch_id, at}.
var _pending_extrude := {}

var world: CadWorld
var rig: OrbitCamera
var sketch_view: SketchView
var overlay: Control
var view_cube: ViewCube
var timeline: TimelineBar

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _tool_bar: HFlowContainer
var _constraint_bar: HFlowContainer
var _tool_buttons := {}
var _btn_create: Button
var _btn_extrude: Button
var _btn_finish: Button
var _extrude_dialog: Window
var _extrude_dist: LineEdit
var _btn_undo: Button
var _btn_redo: Button
var _status_mode: Label
var _status_hint: Label
var _status_dof: Label
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
	tools.register(SlotTool.new("center"))
	tools.register(SlotTool.new("overall"))
	tools.register(SlotTool.new("point"))
	tools.register(PointTool.new())
	tools.register(TrimTool.new())
	tools.register(ExtendTool.new())
	tools.register(OffsetTool.new())
	tools.register(MirrorTool.new())
	tools.register(FilletTool.new())
	tools.register(SmartDimensionTool.new())
	tools.overlay_needs_redraw.connect(func() -> void: overlay.queue_redraw())
	tools.active_changed.connect(func(_id: String) -> void: _refresh_ui())
	_build_ui()
	_refresh_ui()
	_maybe_start_automation()


func set_selection(ids: Array) -> void:
	selection.clear()
	for i in ids:
		selection.append(String(i))
	if not selection.is_empty():
		selected_constraint = -1
	overlay.queue_redraw()
	_refresh_ui()


## Apply a constraint to the CURRENT selection (validated). Constraint +
## follower solve = one sealed undo step. Returns "" or the refusal reason.
func apply_constraint(type: SketchConstraint.Type, value := NAN) -> String:
	var sk := active_sketch()
	if sk == null:
		return "not in a sketch"
	var sel: Array = []
	for id in selection:
		var e := sk.entity(id)
		if e != null:
			sel.append(e)
	var why := ConstraintRules.validate(sk, type, sel)
	if why != "":
		_status_hint.text = "Cannot apply: " + why
		return why
	var ops := ConstraintRules.operands(type, sel)
	var c := SketchConstraint.make(type, ops)
	if c.is_dimensional():
		c.value = value if not is_nan(value) \
			else ConstraintRules.measured_value(sk, type, ops)
	add_constraint(c)
	return ""


## Push a built constraint + its re-solve as one undo step.
func add_constraint(c: SketchConstraint) -> void:
	var sk := active_sketch()
	var batch := CmdMergeBatch.new("Constrain", [])
	stack.push_no_merge(batch)
	var after: Array = sk.constraints.duplicate()
	after.append(c)
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers()
	batch.seal()


func delete_constraint(index: int) -> void:
	var sk := active_sketch()
	if sk == null or index < 0 or index >= sk.constraints.size():
		return
	var after: Array = sk.constraints.duplicate()
	after.remove_at(index)
	var batch := CmdMergeBatch.new("Delete Constraint", [])
	stack.push_no_merge(batch)
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers()
	batch.seal()
	selected_constraint = -1


## Drive a dimension from user text: a literal ("2.5", "10mm") sets the
## value in the display unit; anything else becomes a live EXPRESSION over
## the document parameters, stored with the unit space it was typed in.
## Edit + re-solve = one undo step (merges into an open batch if any).
## Returns "" or an error message.
func set_dimension_value(index: int, text: String) -> String:
	var sk := active_sketch()
	if sk == null or index < 0 or index >= sk.constraints.size():
		return "no such dimension"
	var c := sk.constraints[index]
	var unit_space: int = CadParameter.UNIT_SCALAR \
		if c.type == SketchConstraint.Type.ANGLE else int(doc.display_unit)
	var edited := c.duplicate_constraint()
	if CadExpression.is_literal(text):
		if c.type == SketchConstraint.Type.ANGLE:
			edited.value = text.to_float()
		else:
			var r := UnitConverter.parse(text, doc.display_unit)
			if not r["ok"]:
				return String(r["error"])
			edited.value = r["mm"]
		edited.expr = ""
	else:
		var r := _eval_dimension_text(text, unit_space)
		if not bool(r["ok"]):
			_status_hint.text = "Expression error: " + String(r["error"])
			return String(r["error"])
		edited.value = float(r["value"])
		edited.expr = text
		edited.expr_unit = unit_space
	var after: Array = sk.constraints.duplicate()
	after[index] = edited
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers()
	return ""


func set_dimension_driven(index: int, driven: bool) -> void:
	var sk := active_sketch()
	if sk == null or index < 0 or index >= sk.constraints.size():
		return
	var edited := sk.constraints[index].duplicate_constraint()
	edited.driven = driven
	var after: Array = sk.constraints.duplicate()
	after[index] = edited
	var batch := CmdMergeBatch.new("Driven", [])
	stack.push_no_merge(batch)
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers()
	batch.seal()


## Evaluate text in `unit_space` against the document parameters (angle
## dimensions are scalar degrees; lengths convert to canonical mm).
func _eval_dimension_text(text: String, unit_space: int) -> Dictionary:
	return CadExpression.eval_text(doc.parameters, text, unit_space)


## Replace the parameter list, re-value every expression-driven dimension in
## every sketch, and re-solve — ONE undo step (Fusion's parameter edit).
func set_parameters(new_params: Array) -> void:
	var batch := CmdMergeBatch.new("Parameters", [])
	stack.push_no_merge(batch)
	stack.push(CmdSetParameters.new(doc.parameters, new_params))
	for f in doc.features:
		if not (f is SketchFeature):
			continue
		var sk := (f as SketchFeature).sketch
		var changed := false
		var after: Array = sk.constraints.duplicate()
		for i in after.size():
			var c: SketchConstraint = after[i]
			if c.expr == "":
				continue
			var r := CadExpression.eval_text(doc.parameters, c.expr, c.expr_unit)
			if bool(r["ok"]) and absf(float(r["value"]) - c.value) > 1e-9:
				var edited := c.duplicate_constraint()
				edited.value = float(r["value"])
				after[i] = edited
				changed = true
		if changed:
			stack.push(CmdSetConstraints.new(f.id, sk.constraints, after))
			if f.id == active_sketch_id:
				solve_followers()
			else:
				var res := ConstraintSolver.solve(sk)
				if not (res["points"] as Dictionary).is_empty():
					stack.push(CmdMovePoints.new(f.id, res["points"]))
				if not (res["radii"] as Dictionary).is_empty():
					stack.push(CmdSetRadii.new(f.id, res["radii"]))
	batch.seal()


func _refresh_dof() -> void:
	var sk := active_sketch()
	dof = DofAnalyzer.analyze(sk) if sk != null else {}
	var pts := {}
	for id in dof.get("constrained_points", []):
		pts[id] = true
	var circles := {}
	for id in dof.get("constrained_circles", []):
		circles[id] = true
	bridge.constrained = {"points": pts, "circles": circles}


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
	timeline.refresh()
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
	_btn_extrude = _button(top, "Extrude", _on_extrude_pressed)
	_btn_extrude.name = "ExtrudeBtn"
	_btn_finish = _button(top, "Finish Sketch", _on_finish_sketch)
	_btn_finish.name = "FinishSketchBtn"
	_btn_undo = _button(top, "Undo", func() -> void: stack.undo())
	_btn_undo.name = "UndoBtn"
	_btn_redo = _button(top, "Redo", func() -> void: stack.redo())
	_btn_redo.name = "RedoBtn"
	# Tools get their own row — one row would overflow the window and make
	# the tail buttons unreachable (for users AND automation clicks).
	_tool_bar = HFlowContainer.new()
	_tool_bar.name = "ToolBar"
	vbox.add_child(_tool_bar)
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

	_constraint_bar = HFlowContainer.new()
	_constraint_bar.name = "ConstraintBar"
	vbox.add_child(_constraint_bar)
	var cons_defs := [
		["Coincident", SketchConstraint.Type.COINCIDENT],
		["Horizontal", SketchConstraint.Type.HORIZONTAL],
		["Vertical", SketchConstraint.Type.VERTICAL],
		["Parallel", SketchConstraint.Type.PARALLEL],
		["Perpendicular", SketchConstraint.Type.PERPENDICULAR],
		["Collinear", SketchConstraint.Type.COLLINEAR],
		["Equal", SketchConstraint.Type.EQUAL],
		["Midpoint", SketchConstraint.Type.MIDPOINT],
		["Concentric", SketchConstraint.Type.CONCENTRIC],
		["Tangent", SketchConstraint.Type.TANGENT],
		["PointOn", SketchConstraint.Type.POINT_ON],
		["Fix", SketchConstraint.Type.FIX],
		["Symmetry", SketchConstraint.Type.SYMMETRY],
	]
	for def in cons_defs:
		var cb := _button(_constraint_bar, def[0],
			func() -> void: apply_constraint(def[1]))
		cb.name = String(def[0]) + "ConBtn"

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

	timeline = TimelineBar.new()
	timeline.app = self
	vbox.add_child(timeline)
	timeline.refresh()

	var status := HBoxContainer.new()
	status.name = "StatusBar"
	vbox.add_child(status)
	_status_mode = _label(status, "Model")
	_status_hint = _label(status, "")
	_status_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_dof = _label(status, "")
	_status_dof.name = "StatusDof"
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
	selected_constraint = -1
	tools.set_active("select")
	rebuild_snap_index()
	_refresh_dof()
	sketch_view.mark_dirty()
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
	picking_profile = false
	_refresh_ui()


func _on_extrude_pressed() -> void:
	picking_profile = true
	picking_plane = false
	_refresh_ui()


## Create an extrude feature from a profile hit (undoable). Returns the
## feature id or "" when no profile encloses `at`.
func extrude(sketch_id: String, at: Vector2, dist: float) -> String:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return ""
	if ProfileFinder.profile_at(sf.sketch, at).is_empty():
		return ""
	var f := ExtrudeFeature.make(sketch_id, at, dist)
	f.name = doc.auto_name("Extrude")
	f.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(f))
	return f.id


## Ray -> (sketch feature, uv on its plane) for the topmost live sketch
## whose profile contains the hit. {} when none.
func _profile_under_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	for f in doc.live_features():
		if not (f is SketchFeature):
			continue
		var sf := f as SketchFeature
		var xf := sf.plane_transform()
		var n: Vector3 = xf.basis.z
		var denom := dir.dot(n)
		if absf(denom) < 1e-9:
			continue
		var t := -origin.dot(n) / denom
		if t <= 0.0:
			continue
		var hit := origin + dir * t
		var uv := Vector2(hit.dot(xf.basis.x), hit.dot(xf.basis.y))
		if not ProfileFinder.profile_at(sf.sketch, uv).is_empty():
			return {"sketch_id": sf.id, "at": uv}
	return {}


func _open_extrude_dialog() -> void:
	if _extrude_dialog == null:
		_extrude_dialog = Window.new()
		_extrude_dialog.name = "ExtrudeDialog"
		_extrude_dialog.title = "Extrude"
		_extrude_dialog.size = Vector2i(220, 90)
		_extrude_dialog.exclusive = false
		_extrude_dialog.close_requested.connect(
			func() -> void: _extrude_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_extrude_dialog.add_child(box)
		_extrude_dist = LineEdit.new()
		_extrude_dist.name = "ExtrudeDistEdit"
		_extrude_dist.placeholder_text = "Distance (e.g. 0.5in)"
		box.add_child(_extrude_dist)
		var okb := Button.new()
		okb.name = "ExtrudeOkBtn"
		okb.text = "OK"
		okb.pressed.connect(_commit_extrude)
		box.add_child(okb)
		_extrude_dist.text_submitted.connect(
			func(_t: String) -> void: _commit_extrude())
		add_child(_extrude_dialog)
	_extrude_dist.text = ""
	_extrude_dialog.popup_centered()
	_extrude_dist.grab_focus()


func _commit_extrude() -> void:
	var r := UnitConverter.parse(_extrude_dist.text, doc.display_unit)
	if not r["ok"]:
		_status_hint.text = "Extrude: enter a distance"
		return
	_extrude_dialog.hide()
	if not _pending_extrude.is_empty():
		extrude(_pending_extrude["sketch_id"], _pending_extrude["at"],
			float(r["mm"]))
	_pending_extrude = {}


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
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_profile:
			var ray2 := rig.pixel_ray(mb.position)
			var hit := _profile_under_ray(ray2[0], ray2[1])
			if not hit.is_empty():
				picking_profile = false
				_pending_extrude = hit
				_open_extrude_dialog()
				_refresh_ui()
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
		if picking_plane or picking_profile:
			picking_plane = false
			picking_profile = false
			world.set_plane_hover("")
			_refresh_ui()
			return true
		return false
	if (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and mode == Mode.SKETCH:
		return tools.handle_commit()
	if k.keycode == KEY_DELETE and mode == Mode.SKETCH:
		if selected_constraint >= 0:
			delete_constraint(selected_constraint)
			return true
		if not selection.is_empty():
			var doomed := selection.duplicate()
			set_selection([])
			var batch := CmdMergeBatch.new("Delete", [])
			stack.push_no_merge(batch)
			stack.push(CmdDeleteEntities.new(active_sketch_id, doomed))
			solve_followers()
			batch.seal()
			return true
		return false
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
	var constrained_pts := {}
	for id in dof.get("constrained_points", []):
		constrained_pts[id] = true
	for e in sk.entities():
		if e.kind() == "point":
			var p := v.world_to_screen((e as SketchPoint).pos)
			var c := Color(0.85, 0.88, 0.95)
			if selection.has(e.id):
				c = Color(1.0, 0.85, 0.3)
			elif constrained_pts.has(e.id):
				c = RenderBridge.COLOR_CONSTRAINED
			overlay.draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5, 5)), c)
	for id in selection:
		var e := sk.entity(id)
		if e == null:
			continue
		_draw_selected_entity(sk, e)
	badge_hits = ConstraintOverlay.draw(overlay, v, sk, dof, selected_constraint)
	dim_hits = DimensionOverlay.draw(overlay, v, sk, dof, selected_constraint,
		doc.display_unit)
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
			if selected_constraint >= sk.constraints.size():
				selected_constraint = -1
			snap.build_index(sk, _snap_exclude)   # keep gesture exclusions
			_refresh_dof()
			sketch_view.mark_dirty()
			overlay.queue_redraw()
	else:
		world.rebuild_sketches(doc)
	timeline.refresh()
	_refresh_ui()


func _refresh_ui() -> void:
	var in_sketch := mode == Mode.SKETCH
	_btn_create.visible = not in_sketch
	_btn_extrude.visible = not in_sketch
	_btn_finish.visible = in_sketch
	_tool_bar.visible = in_sketch
	_constraint_bar.visible = in_sketch
	if in_sketch and not dof.is_empty():
		var sk := active_sketch()
		_status_dof.text = DofAnalyzer.summary(sk) if sk != null else ""
	else:
		_status_dof.text = ""
	for tid: String in _tool_buttons:
		(_tool_buttons[tid] as Button).set_pressed_no_signal(
			tid == tools.active_id())
	_btn_undo.disabled = not stack.can_undo()
	_btn_redo.disabled = not stack.can_redo()
	_status_mode.text = "Sketch" if in_sketch else "Model"
	if picking_plane:
		_status_hint.text = "Select a plane (Esc to cancel)"
	elif picking_profile:
		_status_hint.text = "Select a closed profile (Esc to cancel)"
	elif in_sketch:
		var f := doc.sketch_feature(active_sketch_id)
		_status_hint.text = "%s on %s" % [f.name, f.plane] if f != null else ""
	else:
		_status_hint.text = ""
	_status_zoom.text = "%d%%" % roundi(sketch_view.zoom() * 25.0) if in_sketch else ""
