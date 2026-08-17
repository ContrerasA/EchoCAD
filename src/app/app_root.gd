class_name AppRoot
extends Control
## The application root: owns the document, command stack, mode state, 3D
## viewport (model mode), and SketchView (sketch mode). UI is built in code —
## the .tscn is only this node. Fusion mode model: MODEL (orbit the world,
## pick planes) <-> SKETCH (camera locked normal to the plane, 2D editing).

enum Mode { MODEL, SKETCH }

## Bumped on every QA-fix pass; shown in the window title so a stale running
## instance (launched before the latest fixes) is identifiable at a glance.
const BUILD := "2026-08-16-r4"

## Editor chrome colours.
const COLOR_SELECTED := Color(1.0, 0.85, 0.3)
## Hover pre-highlight: the same amber, dimmer, so hovering reads as "this is
## what a click would take" without competing with an actual selection.
const COLOR_HOVER := Color(1.0, 0.85, 0.3, 0.5)
## Ceiling on an arc's on-screen radius when drawing chrome. Guards against a
## diverged solve producing a radius whose arc path costs whole frames to walk.
const ARC_DRAW_MAX_PX := 20000.0

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
## Sketch-mode sub-state: true while the camera has orbited OFF the sketch
## plane (Fusion's in-sketch orbit). The sketch stays open but editing is
## disabled; the plane's view-cube face (or Esc) flies back to locked 2D.
var sketch_orbit := false
## Feature id of the sketch being edited ("" in model mode).
var active_sketch_id := ""
## True while "Create Sketch" waits for a plane click.
var picking_plane := false
## True while "Extrude" waits for a profile click.
var picking_profile := false
## Pending extrude target set by the profile click: {sketch_id, at}.
var _pending_extrude := {}
## Camera state captured on entering sketch mode, so Finish Sketch animates
## back to the model view the user left rather than to a canned angle.
var _model_view_before_sketch := {}

var world: CadWorld
var rig: OrbitCamera
var sketch_view: SketchView
var overlay: Control
var view_cube: ViewCube
var timeline: TimelineBar
var browser: BrowserTree

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _tool_bar: HFlowContainer
## Snap/inference toggles — kept so RPC-driven pref changes can refresh them.
var _snap_check: CheckBox = null
var _infer_check: CheckBox = null
var _constraint_bar: HFlowContainer
var _tool_buttons := {}
var _btn_create: Button
var _btn_extrude: Button
var _btn_finish: Button
var _extrude_dialog: Window
var _extrude_dist: LineEdit
var _btn_undo: Button
var _btn_redo: Button
var _btn_save: Button
var _btn_open: Button
## Where the document lives on disk ("" = never saved). Ctrl+S reuses it.
var _save_path := ""
var _file_dialog: FileDialog = null
var _file_dialog_saving := false
var _pivot_pick: OptionButton
var _status_mode: Label
var _status_hint: Label
## Wall-clock ms until which a posted hint outranks the cursor readout.
var _hint_hold_until_ms := 0
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
	tools.register(ProjectTool.new())
	tools.register(SmartDimensionTool.new())
	tools.overlay_needs_redraw.connect(func() -> void: overlay.queue_redraw())
	tools.active_changed.connect(func(_id: String) -> void: _refresh_ui())
	_build_ui()
	_refresh_ui()
	_maybe_start_automation()
	get_window().title = "EchoCAD — build " + BUILD


## Drives the active tool's per-frame tick. Tools are RefCounted and have no
## _process of their own, and gestures that must not run faster than the
## display (drag re-solves) rely on this — see `SketchTool.tick`.
func _process(_dt: float) -> void:
	if mode == Mode.SKETCH and not sketch_orbit:
		tools.handle_tick()


## How long a posted hint holds the status bar against the live cursor readout.
const HINT_HOLD_MS := 4000

## Put a message in the status bar's hint slot. Tools use this to explain why
## they refused a gesture — a refusal the user cannot see reads as a bug.
func set_status_hint(text: String) -> void:
	if _status_hint != null:
		_status_hint.text = text
		_hint_hold_until_ms = Time.get_ticks_msec() + HINT_HOLD_MS


## Window-pixel rect of the 3D viewport. Automation projects world points
## through the camera (viewport pixels) and needs this offset to turn the
## result into a position it can click.
func viewport_rect() -> Rect2:
	return _viewport_container.get_global_rect()


## Push `prefs`/snap state back onto the toolbar checkboxes, for callers that
## change it behind the UI's back (the automation server).
func sync_pref_checks() -> void:
	if _snap_check != null:
		_snap_check.set_pressed_no_signal(snap.grid_enabled)
	if _infer_check != null:
		_infer_check.set_pressed_no_signal(bool(prefs.get("inference", true)))


func set_selection(ids: Array) -> void:
	selection.clear()
	for i in ids:
		selection.append(String(i))
	if not selection.is_empty():
		selected_constraint = -1
	overlay.queue_redraw()
	_refresh_ui()


## Select a solid body in model mode ("" clears). View state, not model
## state — no command, no undo entry, matching Fusion.
func select_body(fid: String) -> void:
	if world.selected_body() == fid:
		return
	world.set_selected_body(fid)
	browser.refresh()
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
##
## A DIMENSION added to an already-determined system is redundant: it cannot
## drive anything, and left driving it just fights the constraints that got
## there first. Fusion's answer is to accept it as a DRIVEN (reference)
## dimension — it measures and displays instead. We do the same, inside the
## same undo step, and say so, because silently accepting a dimension that has
## no effect is the confusing outcome.
func add_constraint(c: SketchConstraint) -> void:
	var sk := active_sketch()
	var batch := CmdMergeBatch.new("Constrain", [])
	stack.push_no_merge(batch)
	var after: Array = sk.constraints.duplicate()
	after.append(c)
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	var demoted := ""
	if c.is_dimensional() and not c.driven:
		var a := DofAnalyzer.analyze(sk)
		var idx := sk.constraints.size() - 1
		if bool(a.get("analyzed", false)) \
				and (a["redundant"] as Array).has(idx):
			var driven_after: Array = sk.constraints.duplicate()
			var dc := c.duplicate_constraint()
			dc.driven = true
			driven_after[idx] = dc
			stack.push(CmdSetConstraints.new(active_sketch_id,
				sk.constraints, driven_after))
			demoted = SketchConstraint.Type.keys()[c.type]
	solve_followers()
	batch.seal()
	if demoted != "":
		_status_hint.text = ("%s is redundant here — kept as a DRIVEN "
			+ "reference dimension (it measures, it does not drive). Remove "
			+ "another dimension to make it driving.") % demoted.capitalize()


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
	Projector.refresh(doc)
	active_sketch_id = ""
	picking_plane = false
	mode = Mode.MODEL
	sketch_orbit = false
	sketch_view.visible = false
	world.set_planes_visible(false)
	world.set_grid_plane("XY")
	world.set_grid_unit(doc.display_unit)
	world.rebuild_sketches(doc)
	timeline.refresh()
	browser.refresh()
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
	_btn_save = _button(top, "Save", func() -> void: save_interactive(false))
	_btn_save.name = "SaveBtn"
	_btn_open = _button(top, "Open", open_interactive)
	_btn_open.name = "OpenBtn"
	# Orbit pivot: Fusion's body-center is the default, Blender-style
	# under-cursor and plain view-center are the alternatives.
	_pivot_pick = OptionButton.new()
	_pivot_pick.name = "PivotModeBtn"
	_pivot_pick.focus_mode = Control.FOCUS_NONE
	_pivot_pick.add_item("Orbit: Body Center", OrbitCamera.PivotMode.BODY_CENTER)
	_pivot_pick.add_item("Orbit: Under Cursor", OrbitCamera.PivotMode.ORBIT_POINT)
	_pivot_pick.add_item("Orbit: View Center", OrbitCamera.PivotMode.VIEW_CENTER)
	_pivot_pick.item_selected.connect(func(i: int) -> void:
		set_pivot_mode(_pivot_pick.get_item_id(i) as OrbitCamera.PivotMode))
	top.add_child(_pivot_pick)
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

	# Snap + inference toggles. These already existed as `prefs` entries that
	# only `action.set_pref` could reach, which made them unusable by hand and
	# unverifiable in manual QA. Both paths now drive the same state.
	var snap_box := CheckBox.new()
	snap_box.name = "GridSnapChk"
	snap_box.text = "Snap"
	snap_box.focus_mode = Control.FOCUS_NONE
	snap_box.button_pressed = snap.grid_enabled
	snap_box.toggled.connect(func(on: bool) -> void: snap.grid_enabled = on)
	_tool_bar.add_child(snap_box)
	_snap_check = snap_box

	var infer_box := CheckBox.new()
	infer_box.name = "InferenceChk"
	infer_box.text = "Infer"
	infer_box.focus_mode = Control.FOCUS_NONE
	infer_box.button_pressed = bool(prefs.get("inference", true))
	infer_box.toggled.connect(func(on: bool) -> void: prefs["inference"] = on)
	_tool_bar.add_child(infer_box)
	_infer_check = infer_box

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

	# Browser on the left, canvas on the right — the browser is a sibling of
	# the canvas, not an overlay on it, so it never eats viewport clicks.
	var body_row := HBoxContainer.new()
	body_row.name = "BodyRow"
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_theme_constant_override("separation", 0)
	vbox.add_child(body_row)

	browser = BrowserTree.new()
	browser.app = self
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(browser)

	var stack_area := Control.new()
	stack_area.name = "CanvasStack"
	stack_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack_area.clip_contents = true
	body_row.add_child(stack_area)

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
			view_cube.sync_orientation(rig.rotation)
		# Grid density follows the camera, like the sketch canvas's follows zoom.
		world.update_grid(rig.view_height_mm()))
	# Pivot sources: Fusion's body-center default and Blender's under-cursor
	# orbit point. VIEW_CENTER needs neither.
	rig.bounds_provider = func() -> AABB: return world.model_bounds()
	rig.orbit_point_provider = func(screen: Vector2) -> Dictionary:
		var r := rig.pixel_ray(screen)
		return world.pick_point(r[0], r[1])

	sketch_view = SketchView.new()
	sketch_view.name = "SketchView"
	sketch_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	sketch_view.bridge = bridge
	sketch_view.visible = false
	sketch_view.view_changed.connect(_on_sketch_view_changed)
	sketch_view.tool_input = _on_tool_input
	sketch_view.key_handler = handle_app_key
	sketch_view.orbit_request = _on_sketch_orbit_request
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
	# The rig already emitted `moved` from its own _ready, before this widget
	# existed — hand it the current orientation so it starts in agreement with
	# the 3/4 home view instead of facing front until the first orbit.
	view_cube.rotation_hint = rig.rotation
	stack_area.add_child(view_cube)

	timeline = TimelineBar.new()
	timeline.app = self
	vbox.add_child(timeline)
	timeline.refresh()
	browser.refresh()
	# The rig emitted `moved` from its own _ready, before the connect above.
	world.set_grid_unit(doc.display_unit)
	world.update_grid(rig.view_height_mm())

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
	if mode == Mode.MODEL:
		_model_view_before_sketch = rig.capture_view()
	active_sketch_id = feature_id
	picking_plane = false
	mode = Mode.SKETCH
	sketch_orbit = false
	sketch_view.grid_unit = doc.display_unit
	sketch_view.set_view(Vector2.ZERO, 4.0)
	sketch_view.show_sketch(feat.sketch, reference_sketches())
	# Fly the 3D camera square onto the plane FIRST, then swap in the 2D
	# canvas. Showing it up front would paint over the animation, which is
	# what made the transition read as an instant snap.
	# The grid moves onto the plane being drawn on, so the 3D scene behind the
	# canvas agrees with it — and so it is already right for the fly-in.
	world.set_grid_plane(feat.plane)
	world.set_grid_unit(doc.display_unit)
	var basis := SketchFeature.plane_basis(feat.plane)
	rig.frame_view(basis.z, basis.y, Vector3.ZERO, 500.0)
	_after_camera_move(func() -> void:
		if mode == Mode.SKETCH:
			sketch_view.visible = true
			sketch_view.grab_focus()
			# Match the 3D camera to the canvas now the fly-in has landed:
			# the sync is driven by `view_changed`, which does not fire on
			# entry, so without this the model behind the canvas keeps the
			# framing the tween chose rather than the sketch's own.
			_sync_camera_to_sketch_view())
	world.set_planes_visible(false)
	set_selection([])
	selected_constraint = -1
	tools.set_active("select")
	rebuild_snap_index()
	_refresh_dof()
	sketch_view.mark_dirty()
	mode_changed.emit(mode)
	_refresh_ui()


## Run `done` when the rig's current move finishes — right away when there is
## no tween to wait on (headless tests, animation disabled).
func _after_camera_move(done: Callable) -> void:
	var tw := rig.active_tween()
	if tw == null:
		done.call()
		return
	tw.finished.connect(done, CONNECT_ONE_SHOT)


func finish_sketch() -> void:
	if mode != Mode.SKETCH:
		return
	tools.set_active("")
	set_selection([])
	active_sketch_id = ""
	mode = Mode.MODEL
	sketch_orbit = false
	rig.end_orbit()
	# Drop the 2D canvas immediately so the 3D scene is what animates: the
	# camera pulls back from the plane to the previous model view.
	sketch_view.visible = false
	world.set_planes_visible(false)
	# Model mode is a 3D space again: perspective back on, so solids read with
	# depth. (Sketch mode runs orthographic — see `_sync_camera_to_sketch_view`.)
	rig.set_perspective()
	# Back to the ground plane: the grid is XY whenever no sketch is open.
	world.set_grid_plane("XY")
	world.rebuild_sketches(doc)
	if _model_view_before_sketch.is_empty():
		rig.frame_view(Vector3(0.5, -0.7, 0.5), Vector3(0, 0, 1))
	else:
		rig.restore_view(_model_view_before_sketch)
	_model_view_before_sketch = {}
	mode_changed.emit(mode)
	_refresh_ui()


func active_sketch() -> Sketch:
	var f := doc.sketch_feature(active_sketch_id)
	return f.sketch if f != null else null


## Sketches drawn dimmed behind the one being edited: every other LIVE sketch
## sharing its plane. Coplanar only — geometry on a different plane projects
## onto the canvas as a meaningless smear, and it is the coplanar case
## (tracing over, lining up with what is already drawn) that the user needs.
## Suppressed and rolled-back sketches are excluded by `live_features`, so
## reference geometry always matches what the 3D view shows.
func reference_sketches() -> Array:
	var out: Array = []
	for sf in reference_features():
		out.append((sf as SketchFeature).sketch)
	return out


## The FEATURES behind `reference_sketches` — the Project tool needs the
## feature identity (plane, id) as well as the sketch, since a projection
## links to its source by feature id.
func reference_features() -> Array:
	var out: Array = []
	var feat := doc.sketch_feature(active_sketch_id)
	if feat == null:
		return out
	for f in doc.live_features():
		var sf := f as SketchFeature
		if sf == null or sf.id == feat.id or sf.plane != feat.plane:
			continue
		# A sketch unticked in the browser stays hidden here too — one tick,
		# one meaning, whichever mode you are in.
		if not world.sketch_shown(sf.id):
			continue
		out.append(sf)
	return out


## Browser-tree visibility toggle for a sketch. View state, never undoable —
## same contract as body visibility. Refreshes the 2D canvas as well as the 3D
## view, since reference geometry obeys the same flag.
func set_sketch_shown(fid: String, shown: bool) -> void:
	world.set_sketch_shown(fid, shown)
	if mode == Mode.SKETCH:
		sketch_view.show_sketch(active_sketch(), reference_sketches())


## --- input & handlers --------------------------------------------------------

func _on_create_sketch() -> void:
	picking_plane = true
	picking_profile = false
	# Planes stay out of sight until there is a reason to aim at one.
	world.set_planes_visible(true)
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


## --- save / open ---------------------------------------------------------------

## Write the document to `path` (.ecad). Returns true on success.
func save_to(path: String) -> bool:
	if not path.to_lower().ends_with(".ecad"):
		path += ".ecad"
	if not Serializer.save(doc, path):
		set_status_hint("Save failed: " + path)
		return false
	_save_path = path
	stack.mark_saved()
	set_status_hint("Saved " + path)
	return true


## Load `path` and replace the document. Returns true on success.
func open_from(path: String) -> bool:
	var loaded := Serializer.load_file(path)
	if loaded == null:
		set_status_hint("Open failed: " + path)
		return false
	if mode == Mode.SKETCH:
		finish_sketch()
	load_document(loaded)
	_save_path = path
	stack.mark_saved()
	set_status_hint("Opened " + path)
	return true


## Ctrl+S / Save button. Saves in place when the document has a path;
## `force_dialog` (Ctrl+Shift+S) always asks where.
func save_interactive(force_dialog := false) -> void:
	if _save_path != "" and not force_dialog:
		save_to(_save_path)
		return
	_open_file_dialog(true)


func open_interactive() -> void:
	_open_file_dialog(false)


func _open_file_dialog(saving: bool) -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.name = "EcadFileDialog"
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.filters = ["*.ecad ; EchoCAD documents"]
		_file_dialog.size = Vector2i(640, 420)
		_file_dialog.file_selected.connect(func(path: String) -> void:
			if _file_dialog_saving:
				save_to(path)
			else:
				open_from(path))
		add_child(_file_dialog)
	_file_dialog_saving = saving
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if saving \
		else FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.title = "Save As" if saving else "Open"
	if _save_path != "":
		_file_dialog.current_path = _save_path
	_file_dialog.popup_centered()


## Set the orbit pivot mode (view preference, not model state — not undoable).
func set_pivot_mode(m: OrbitCamera.PivotMode) -> void:
	rig.pivot_mode = m
	if _pivot_pick != null:
		var idx := _pivot_pick.get_item_index(m)
		if idx >= 0:
			_pivot_pick.selected = idx


## Shift+MMB pressed inside the locked 2D sketch view: orbit away from the
## plane, Fusion-style. The canvas yields the screen and the active sketch
## renders in 3D on its plane; editing stays disabled until the camera returns
## square (see `return_to_sketch_plane`).
func _on_sketch_orbit_request(screen: Vector2) -> void:
	if mode != Mode.SKETCH or sketch_orbit:
		return
	sketch_orbit = true
	sketch_view.visible = false
	# The in-edit sketch gets the same 3D line-mesh treatment as every other
	# live sketch — the world's meshes may be stale mid-edit, so rebuild now.
	world.rebuild_sketches(doc)
	rig.to_perspective_preserving()
	rig.begin_orbit(screen)
	_refresh_ui()


## Fly back square onto the active sketch's plane and re-enter locked 2D
## editing at the exact pan/zoom the user left (the canvas kept them).
func return_to_sketch_plane() -> void:
	if mode != Mode.SKETCH or not sketch_orbit:
		return
	var feat := doc.sketch_feature(active_sketch_id)
	if feat == null:
		return
	rig.end_orbit()
	var basis := SketchFeature.plane_basis(feat.plane)
	var pan := sketch_view.pan()
	rig.frame_view(basis.z, basis.y, basis * Vector3(pan.x, pan.y, 0.0),
		rig.distance)
	_after_camera_move(func() -> void:
		if mode != Mode.SKETCH:
			return
		sketch_orbit = false
		sketch_view.visible = true
		sketch_view.grab_focus()
		# Ortho + exact registration with the canvas, as on sketch entry.
		_sync_camera_to_sketch_view()
		_refresh_ui())
	_refresh_ui()


func _on_cube_face(normal: Vector3, up: Vector3) -> void:
	if mode == Mode.MODEL:
		rig.frame_view(normal, up)
	elif sketch_orbit:
		# The active plane's own face is the way home; any other face just
		# reorients the off-axis view.
		var feat := doc.sketch_feature(active_sketch_id)
		if feat != null \
				and normal.dot(SketchFeature.plane_basis(feat.plane).z) > 0.999:
			return_to_sketch_plane()
		else:
			rig.frame_view(normal, up)


func _on_viewport_input(event: InputEvent) -> void:
	# Off-axis sketch orbit routes here too (the 2D canvas is hidden), but
	# only for NAVIGATION — LMB picking stays a model-mode affair.
	var nav_only := mode == Mode.SKETCH and sketch_orbit
	if mode != Mode.MODEL and not nav_only:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			# Shift at press time selects orbit; the choice sticks until the
			# button is released, even if Shift is let go mid-drag.
			if mb.pressed and mb.shift_pressed:
				rig.begin_orbit(mb.position)
			elif not mb.pressed:
				rig.end_orbit()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			rig.zoom(1.0 / 1.1)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			rig.zoom(1.1)
		elif nav_only:
			pass
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
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# Plain click in model mode: pick a body, or clear on a miss.
			var ray3 := rig.pixel_ray(mb.position)
			select_body(world.pick_body(ray3[0], ray3[1]))
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			# The gesture's kind is decided by Shift at MMB-press time and
			# stays put for the whole drag: releasing Shift mid-orbit keeps
			# orbiting rather than flipping to pan.
			if rig.is_orbiting():
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
	if k.keycode == KEY_S and k.ctrl_pressed:
		save_interactive(k.shift_pressed)
		return true
	if k.keycode == KEY_O and k.ctrl_pressed:
		open_interactive()
		return true
	if k.keycode == KEY_ESCAPE:
		if sketch_orbit:
			# Same way home as the plane's view-cube face.
			return_to_sketch_plane()
			return true
		if mode == Mode.SKETCH:
			# Esc ends the gesture AND drops back to Select, Fusion-style —
			# a cancelled draw should not leave the tool armed for another
			# shape. Select is exempt: its own Esc clears the selection, and
			# falling through there would make repeated Esc cycle pointlessly.
			var was := tools.active_id()
			var consumed := tools.handle_cancel()
			if was != "select" and was != "":
				tools.set_active("select")
				return true
			if consumed:
				return true
		if picking_plane or picking_profile:
			picking_plane = false
			picking_profile = false
			world.set_plane_hover("")
			world.set_planes_visible(false)
			_refresh_ui()
			return true
		return false
	if (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) \
			and mode == Mode.SKETCH and not sketch_orbit:
		# Enter goes to the tool's TYPE-IN handler first, and only then counts
		# as "finish the gesture". Routing it straight to handle_commit meant
		# the tool's key_input never saw it, so a value typed into a selected
		# dimension was silently discarded: the digits arrived, the field held
		# them, and Enter went somewhere else entirely — which is exactly what
		# made editing an existing dimension look completely broken.
		var active_kt := tools.get_tool(tools.active_id())
		if active_kt != null and active_kt.key_input(k):
			overlay.queue_redraw()
			return true
		return tools.handle_commit()
	if k.keycode == KEY_DELETE and mode == Mode.SKETCH and not sketch_orbit:
		if selected_constraint >= 0:
			delete_constraint(selected_constraint)
			return true
		if not selection.is_empty():
			var sk_del := active_sketch()
			var doomed: Array[String] = []
			for id in selection:
				# The origin is a datum: selectable and dimensionable, but not
				# deletable — losing it would strand every dimension drawn from it.
				if sk_del != null and sk_del.is_origin(id):
					continue
				doomed.append(id)
			set_selection([])
			if doomed.is_empty():
				return true
			doomed = _with_orphaned_points(sk_del, doomed)
			var batch := CmdMergeBatch.new("Delete", [])
			stack.push_no_merge(batch)
			stack.push(CmdDeleteEntities.new(active_sketch_id, doomed))
			solve_followers()
			batch.seal()
			return true
		return false
	if mode == Mode.SKETCH and not k.ctrl_pressed and not sketch_orbit:
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


## `doomed` plus every point that would be left with nothing referencing it.
##
## Deleting a line used to leave its two endpoints behind as loose dots, and —
## worse — any DIMENSION on that line survived too, because a distance
## dimension references the POINTS, not the line, so pruning by the line's id
## never touched it. The user was left cleaning up debris by hand, and a
## dimension measuring geometry that no longer exists.
##
## A point is kept if any surviving entity still refers to it, so shared corners
## and welded joints are never dragged out from under the geometry that uses
## them. The origin is never removed.
func _with_orphaned_points(sk: Sketch, doomed: Array[String]) -> Array[String]:
	if sk == null:
		return doomed
	var dying := {}
	for id in doomed:
		dying[id] = true
	# Points the doomed entities reference, as candidates for removal.
	var candidates := {}
	for id in doomed:
		var e := sk.entity(id)
		if e == null or e.kind() == "point":
			continue
		for pid in e.point_refs():
			if not dying.has(pid) and not sk.is_origin(pid):
				candidates[pid] = true
	if candidates.is_empty():
		return doomed
	# Anything still referenced by a SURVIVING entity stays.
	for e in sk.entities():
		if dying.has(e.id) or e.kind() == "point":
			continue
		for pid in e.point_refs():
			candidates.erase(pid)
	var out := doomed.duplicate()
	for pid: String in candidates:
		out.append(pid)
	return out


func _on_tool_input(world_pos: Vector2, screen: Vector2, event: InputEvent) -> bool:
	if mode != Mode.SKETCH:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			return tools.handle_pointer_down(world_pos, screen, mb)
		return tools.handle_pointer_up(world_pos, screen, mb)
	if event is InputEventMouseMotion:
		# The live cursor readout must not wipe a message a tool just posted —
		# the very next mouse move would erase it, so a refused gesture would
		# look like nothing happened at all. Sticky hints win for a few seconds.
		if Time.get_ticks_msec() >= _hint_hold_until_ms:
			_status_hint.text = "%s, %s" % [
				UnitConverter.format(world_pos.x, doc.display_unit),
				UnitConverter.format(world_pos.y, doc.display_unit)]
		return tools.handle_pointer_move(world_pos, screen,
			event as InputEventMouseMotion)
	return false


func _on_sketch_view_changed() -> void:
	overlay.queue_redraw()
	_sync_camera_to_sketch_view()
	_refresh_ui()


## Keep the 3D camera aimed at whatever the 2D canvas is showing.
##
## The model renders BEHIND the sketch canvas (see `SketchView._draw`), but the
## two had entirely independent cameras: panning or zooming the sketch moved
## the 2D geometry while the solid behind it stayed put, so the model read as a
## ghost image stuck to the screen rather than as part of the drawing. Pointing
## the 3D camera at the sketch's pan centre, from a distance that makes its
## on-screen scale match the 2D zoom, makes the two move as one.
func _sync_camera_to_sketch_view() -> void:
	if mode != Mode.SKETCH or sketch_orbit or rig == null:
		return
	var feat := doc.sketch_feature(active_sketch_id)
	if feat == null:
		return
	# Do not fight the fly-in: while the entry tween is running it owns the
	# camera, and this would snap it to the destination mid-animation.
	if rig.active_tween() != null:
		return
	var basis := SketchFeature.plane_basis(feat.plane)
	# Square onto the plane. The fly-in leaves the camera here, but a
	# view-cube click or a stray orbit can leave it off-axis, and then the
	# model behind the canvas is a skewed projection that no longer lines up
	# with the 2D geometry drawn over it.
	var yp := OrbitCamera.yaw_pitch_for(basis.z, basis.y)
	rig.yaw = yp.x
	rig.pitch = yp.y
	# The sketch point at the panel centre, in world space.
	var pan := sketch_view.pan()
	rig.target = basis * Vector3(pan.x, pan.y, 0.0)
	# ORTHOGRAPHIC, sized so one world mm covers exactly `zoom` pixels — the
	# same mapping `SketchView.world_to_screen` uses. Under perspective the two
	# could only ever agree at the centre of the screen: everything else was
	# foreshortened, so the model behind the canvas drifted out of register
	# with the 2D geometry drawn over it the further out you looked. With a
	# parallel projection the agreement is exact everywhere.
	var vh := float(_viewport.size.y)
	if vh > 0.0 and sketch_view.zoom() > 0.0:
		rig.set_orthographic(vh / sketch_view.zoom())
		# `camera.size` does not fire the rig's `moved` signal, so the grid
		# would otherwise never hear about a sketch zoom — leaving its
		# level cross-fade frozen and the popping back.
		world.update_grid(rig.view_height_mm())


## Editor chrome: sketch points, selection highlights, then the active
## tool's own overlay. Screen space; artwork itself is the ThorVG raster.
func _on_overlay_draw() -> void:
	if mode != Mode.SKETCH or sketch_orbit:
		return
	var sk := active_sketch()
	if sk == null:
		return
	var v := sketch_view
	var constrained_pts := {}
	for id in dof.get("constrained_points", []):
		constrained_pts[id] = true
	# Hover pre-highlight. Any tool that picks reports one — Select, Dimension,
	# and whatever picking tools come later — so this reads from the ACTIVE
	# tool rather than naming one; a tool that does not pick leaves hover_id
	# empty. An entity that is both hovered and selected is skipped here, so it
	# reads as selected rather than as two overlapping cues.
	var active_tool := tools.get_tool(tools.active_id())
	var hov := ""
	if active_tool != null and not selection.has(active_tool.hover_id):
		hov = active_tool.hover_id
	if hov != "":
		var he := sk.entity(hov)
		if he != null:
			_draw_entity_outline(sk, he, COLOR_HOVER, 3.0)
	# Point markers go ON TOP of the hover highlight: the highlight for a point
	# is a larger filled square behind it, so drawing the marker afterwards
	# leaves the point itself crisp with a halo around it. Drawing them the
	# other way round hid the halo completely under the 5 px marker, which is
	# why hovering a point appeared to do nothing at all.
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
		_draw_entity_outline(sk, e, COLOR_SELECTED, 2.0)
	badge_hits = ConstraintOverlay.draw(overlay, v, sk, dof, selected_constraint)
	dim_hits = DimensionOverlay.draw(overlay, v, sk, dof, selected_constraint,
		doc.display_unit)
	tools.draw_overlay(overlay)


## Trace an entity's outline in `c` at `w` px — the shared shape used for both
## the selection highlight and the hover pre-highlight, so the two can never
## disagree about where an entity is.
func _draw_entity_outline(sk: Sketch, e: SketchEntity, c: Color, w: float) -> void:
	var v := sketch_view
	match e.kind():
		"point":
			# Points are drawn as small 5 px squares in the pass above, so an
			# outline traced ON one is lost against it. Draw a FILLED, larger
			# square instead: at hover's half-alpha a thin ring around a small
			# square reads as noise, whereas the point plainly growing and
			# brightening is unmistakable — which is the whole job here.
			var pp := v.world_to_screen((e as SketchPoint).pos)
			var half := 4.0 + w
			overlay.draw_rect(Rect2(pp - Vector2(half, half),
				Vector2(half * 2.0, half * 2.0)), c)
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0)
			var b := sk.point(l.p1)
			if a != null and b != null:
				overlay.draw_line(v.world_to_screen(a.pos),
					v.world_to_screen(b.pos), c, w)
		"circle":
			var ci := e as SketchCircle
			var cp := sk.point(ci.center)
			if cp != null:
				overlay.draw_arc(v.world_to_screen(cp.pos),
					ci.radius * v.zoom(), 0, TAU, 64, c, w)
		"arc":
			var arc := e as SketchArc
			var cp := sk.point(arc.center)
			var sp := sk.point(arc.start)
			if cp != null and sp != null:
				var r := cp.pos.distance_to(sp.pos)
				var a0 := (sp.pos - cp.pos).angle()
				var sweep := SketchGeometry.arc_sweep(sk, arc)
				# A runaway solve can hand us an astronomically large radius.
				# draw_arc's cost scales with the path it walks, so an
				# unclamped screen radius pins the CPU on every later frame —
				# and kept doing so even after the offending arc was deleted,
				# because the redraw itself was what was slow. Clamped: the
				# arc leaves the window either way, so nothing is lost.
				var rs := minf(r * v.zoom(), ARC_DRAW_MAX_PX)
				# Screen space is Y-down: angles negate.
				overlay.draw_arc(v.world_to_screen(cp.pos), rs,
					-a0, -(a0 + sweep), 48, c, w)


func _on_stack_changed() -> void:
	# Projections are derived state: recompute them from their sources on
	# EVERY model change (edits, undo, redo, parameter changes), so linked
	# geometry follows its source and dead links break with a message.
	var proj_msgs := Projector.refresh(doc)
	if not proj_msgs.is_empty():
		set_status_hint(proj_msgs[0])
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
			# Off-axis the 3D line meshes ARE the sketch display, so undo/redo
			# must rebuild them just as model mode does.
			if sketch_orbit:
				world.rebuild_sketches(doc)
	else:
		world.rebuild_sketches(doc)
	timeline.refresh()
	browser.refresh()
	_refresh_ui()


func _refresh_ui() -> void:
	var in_sketch := mode == Mode.SKETCH
	_btn_create.visible = not in_sketch
	_btn_extrude.visible = not in_sketch
	_btn_finish.visible = in_sketch
	# Off-axis the sketch is view-only: the editing bars go away with the
	# canvas, so a disabled tool cannot even be aimed at.
	_tool_bar.visible = in_sketch and not sketch_orbit
	_constraint_bar.visible = in_sketch and not sketch_orbit
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
	elif in_sketch and sketch_orbit:
		var fo := doc.sketch_feature(active_sketch_id)
		_status_hint.text = ("Orbiting — click the %s face on the view cube "
			+ "(or press Esc) to return to the sketch") \
			% (fo.plane if fo != null else "plane")
	elif in_sketch:
		var f := doc.sketch_feature(active_sketch_id)
		_status_hint.text = "%s on %s" % [f.name, f.plane] if f != null else ""
	else:
		_status_hint.text = ""
	_status_zoom.text = "%d%%" % roundi(sketch_view.zoom() * 25.0) if in_sketch else ""
