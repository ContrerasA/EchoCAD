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
static func COLOR_SELECTED() -> Color:
	return ThemeService.col("sk_selected")
## Hover pre-highlight: the same amber, dimmer, so hovering reads as "this is
## what a click would take" without competing with an actual selection.
static func COLOR_HOVER() -> Color:
	return ThemeService.col("sk_hover")
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
## True while a continuous gesture (drag) is feeding the stack every frame.
## Per-change derived work that is O(sketch) or worse — the DOF analysis and
## the projection refresh — is deferred until the gesture ends: running an
## O(n^3) Jacobian rank pass per pointer frame is what pegged a core and
## heated the CPU 20 °C on a large sketch (§M16 QA finding).
var live_gesture := false
## Latest DOF analysis of the active sketch ({} when stale/unavailable).
var dof := {}
## Constraint indices whose badge read "unsolved" at the last at-rest repaint
## (see the repaint site — frozen during live gestures, like `dof`).
var _badge_unsolved := {}
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
## Revolve (M23): profile pick, then axis pick, then the dialog.
var picking_revolve := false
var picking_revolve_axis := false
var _pending_revolve := {}
var _btn_revolve: Button
var _revolve_dialog: Window
var _revolve_angle: LineEdit
var _revolve_op: OptionButton
var _revolve_axis := ""
## True while "Offset Plane" waits for a BASE plane click (M22).
var picking_offset_base := false
var _btn_offset_plane: Button
var _plane_dialog: Window
var _plane_dist: LineEdit
var _plane_dialog_base := ""    # base plane ref while creating
var _plane_dialog_edit := ""    # plane feature id while editing (else "")
## Pending extrude target set by the profile click: {sketch_id, at}.
var _pending_extrude := {}
## Camera state captured on entering sketch mode, so Finish Sketch animates
## back to the model view the user left rather than to a canned angle.
var _model_view_before_sketch := {}

var world: CadWorld
var rig: OrbitCamera
## Worker-thread solver for drag re-solves (M16). Falls back to the
## synchronous path when unavailable.
var threaded_solver: ThreadedSolver = null
var sketch_view: SketchView
var overlay: Control
var view_cube: ViewCube
var timeline: TimelineBar
var browser: BrowserTree

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _tool_bar: Control
## Snap/inference toggles — kept so RPC-driven pref changes can refresh them.
var _snap_check: CheckBox = null
var _infer_check: CheckBox = null
var _construction_check: CheckBox = null
## While true, drawing tools mint CONSTRUCTION curves (Fusion's sticky
## construction toggle). See stamp_construction in the tool base.
var construction_mode := false
var _constraint_bar: Control
var _tool_buttons := {}
var _con_buttons := {}       # SketchConstraint.Type -> ribbon button
var _btn_create: Button
var _btn_extrude: Button
var _btn_finish: Button
var _extrude_dialog: Window
var _extrude_dist: LineEdit
var _extrude_op: OptionButton
var _params_dialog: Window
var _params_tree: Tree
var _param_name: LineEdit
var _param_expr: LineEdit
var _param_unit: OptionButton
var _param_err: Label
var _btn_undo: Button
var _btn_redo: Button
var _btn_save: Button
var _btn_open: Button
## Where the document lives on disk ("" = never saved). Ctrl+S reuses it.
var _save_path := ""
var _file_dialog: FileDialog = null
var _file_dialog_saving := false
var _pivot_pick: OptionButton
## M26 shelf: group panels by caption, for mode-based show/hide.
var _shelf_groups := {}
## M36 shell pieces whose footprint follows theme metrics.
var _ribbon: PanelContainer = null
var _menu_panel: PanelContainer = null
var _browser_panel: PanelContainer = null
var _timeline_panel: PanelContainer = null
var _status_panel: PanelContainer = null
## Every ribbon tool button with its title — one uniform look, titles shown
## under the icon only when ThemeService.show_tool_names is on.
var _ribbon_buttons: Array = []      # [{btn, title}]
var _ribbon_grids: Array = []        # [{grid, columns}]
## Collapsible tool strips (CHANGES #1): when the window is too narrow for
## every group, strips give up their trailing tools into a "more" flyout
## instead of wrapping the ribbon onto a second row.
## [{host: GridContainer, flow: Control, more: Button, popup, col}]
var _overflow_groups: Array = []
var _ribbon_layout_pending := false
## Flyout stacks (Fusion-style): one ribbon button fronting several related
## tools; right-click or long-press opens the list, the pick becomes the
## button's face. [{btn, popup, mark, variants: [{id, title, icon, handler,
## btn}], current}]
var _stacks: Array = []
var _flyout_timer: Timer = null
var _flyout_armed: Dictionary = {}
var _flyout_suppress := false
var _stack_marks: Array = []
var _tool_names_check: CheckBox = null
var _model_ribbon: Control = null
var _ribbon_rows: Control = null
var _ribbon_tail: HBoxContainer = null
var _hud: HBoxContainer = null
var _menu_bar: MenuBar = null
var _view_menu: PopupMenu = null
var _view_menu_ortho_idx := -1
var _theme_menu_first := 0
var _brand_mark: ColorRect = null
var _doc_label: Label = null
var _unit_badge: Label = null
var _timeline_count: Label = null
var _prefs_dialog: Window = null
var _theme_pick: OptionButton = null
## M27 viewing: Look At pick state, projection toggle, named views, units.
var picking_look_at := false
var _btn_ortho: Button = null
var _views_pick: OptionButton = null
var _unit_pick: OptionButton = null
var _status_measure: Label = null
## M30 canvases: import dialog, placement editor, calibration pick state.
var _canvas_file_dialog: FileDialog = null
var _canvas_dialog: Window = null
var _canvas_dialog_fid := ""
var _canvas_fields := {}
var picking_calibrate := false
var _calib_fid := ""
var _calib_picks: Array = []
var _calib_dialog: Window = null
var _calib_dist: LineEdit = null
var _status_mode: Label
var _status_hint: Label
## Wall-clock ms until which a posted hint outranks the cursor readout.
var _hint_hold_until_ms := 0
var _status_dof: Label
var _status_zoom: Label
## Identity readout: id / kind / index of the selection (or the hover).
var _status_ids: Label = null


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
	tools.register(SplineTool.new())
	tools.register(PolygonTool.new())
	tools.register(PointTool.new())
	tools.register(TrimTool.new())
	tools.register(ExtendTool.new())
	tools.register(OffsetTool.new())
	tools.register(MirrorTool.new())
	tools.register(FilletTool.new())
	tools.register(ChamferTool.new())
	tools.register(RectPatternTool.new())
	tools.register(CircPatternTool.new())
	tools.register(ProjectTool.new())
	tools.register(SmartDimensionTool.new())
	tools.register(ConstraintTool.new())   # hidden: armed by the constraint buttons
	tools.overlay_needs_redraw.connect(func() -> void: overlay.queue_redraw())
	tools.active_changed.connect(func(_id: String) -> void: _refresh_ui())
	threaded_solver = ThreadedSolver.new()
	threaded_solver.name = "ThreadedSolver"
	add_child(threaded_solver)
	_build_ui()
	_apply_model_projection()
	_refresh_ui()
	_maybe_start_automation()
	get_window().title = "EchoCAD — build " + BUILD


## Static GDScript vars are torn down AFTER the servers at exit, so any
## engine resources still held there (the theme icon textures, a compiled
## RegEx) are reported as leaked RIDs / unreferenced StringNames on the
## way out (QA §M31 shutdown note). Drop them while the tree is alive.
func _exit_tree() -> void:
	ThemeService.drop_static_caches()
	CadExpression.drop_static_caches()


## Drives the active tool's per-frame tick. Tools are RefCounted and have no
## _process of their own, and gestures that must not run faster than the
## display (drag re-solves) rely on this — see `SketchTool.tick`.
func _process(_dt: float) -> void:
	if mode == Mode.SKETCH:
		tools.handle_tick()
		_update_ids_label()
	_poll_threaded_solver()


## Apply whatever the worker-thread solver finished this frame. Results land
## inside the drag's open CmdMergeBatch, so the undo story is unchanged;
## stale results (older than the newest request) never come back from
## `take_result` at all.
func _poll_threaded_solver() -> void:
	if threaded_solver == null:
		return
	var res := threaded_solver.take_result()
	if res.is_empty():
		return
	if mode != Mode.SKETCH or String(res["sketch_id"]) != active_sketch_id:
		return
	var pts: Dictionary = res["points"]
	var radii: Dictionary = res["radii"]
	if not pts.is_empty():
		stack.push(CmdMovePoints.new(active_sketch_id, pts))
	if not radii.is_empty():
		stack.push(CmdSetRadii.new(active_sketch_id, radii))


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
	_update_measure_label()
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


## A constraint button was pressed (CHANGES #6). With a selection that
## already validates the constraint applies at once — select-first still
## works. Otherwise the ConstraintTool arms for this type and the user picks
## the operands with the tool live (hover + click), Fusion-style.
func arm_constraint(type: SketchConstraint.Type, type_title: String) -> void:
	var sk := active_sketch()
	if sk == null:
		return
	var sel: Array = []
	for id in selection:
		var e := sk.entity(id)
		if e != null:
			sel.append(e)
	if not sel.is_empty() and ConstraintRules.validate(sk, type, sel) == "":
		apply_constraint(type)
		_refresh_ui()   # the button is a toggle; give it back to the live tool
		return
	var ct := tools.get_tool("constraint") as ConstraintTool
	ct.arm(type, type_title)
	if tools.active_id() != "constraint":
		tools.set_active("constraint")
	else:
		ct.activate()
	_refresh_ui()


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
	solve_followers_prefer_points(_pins_outside_components(sk, [c]))
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
	# Component pins from the constraint being deleted, taken BEFORE the
	# delete rewires anything.
	var del_pins := _pins_outside_components(sk, [sk.constraints[index]])
	# A grouped dimension deletes with its whole group — the hidden members
	# would otherwise keep driving the geometry with no visible dimension.
	var grp := (sk.constraints[index] as SketchConstraint).group
	if grp != "":
		var keep: Array = []
		for c: SketchConstraint in after:
			if c.group != grp:
				keep.append(c)
		after = keep
	else:
		after.remove_at(index)
	var batch := CmdMergeBatch.new("Delete Constraint", [])
	stack.push_no_merge(batch)
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers(del_pins)
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
	# Grouped dimensions (an offset's per-edge gaps) share one value: editing
	# the shown one re-drives every member, or the ring would tear (§M19.2).
	if c.group != "":
		for i in after.size():
			var oc: SketchConstraint = after[i]
			if i == index or oc.group != c.group:
				continue
			var mate := oc.duplicate_constraint()
			mate.value = edited.value
			mate.expr = edited.expr
			mate.expr_unit = edited.expr_unit
			after[i] = mate
	stack.push(CmdSetConstraints.new(active_sketch_id, sk.constraints, after))
	solve_followers(_pins_outside_components(sk, [c]))
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
	solve_followers(_pins_outside_components(sk, [edited]))
	batch.seal()


## Evaluate text in `unit_space` against the document parameters (angle
## dimensions are scalar degrees; lengths convert to canonical mm).
func _eval_dimension_text(text: String, unit_space: int) -> Dictionary:
	return CadExpression.eval_text(doc.parameters, text, unit_space)


## Replace the parameter list, re-value every expression-driven dimension in
## every sketch, and re-solve — ONE undo step (Fusion's parameter edit).
## Create or update a named parameter (Parameters dialog, M20). Returns ""
## on success or the reason it was refused. Mirrors action.set_parameter.
func upsert_parameter(pname: String, expr: String, unit: int) -> String:
	if not CadExpression.valid_name(pname):
		return ("Invalid name '%s' — letters, digits and _ only, " % pname) \
			+ "not starting with a digit"
	var new_list: Array = []
	var found := false
	for prm in doc.parameters:
		if prm.name == pname:
			var np := prm.duplicate_parameter()
			np.expr = expr
			np.unit = unit
			new_list.append(np)
			found = true
		else:
			new_list.append(prm)
	if not found:
		new_list.append(CadParameter.make(pname, expr, unit))
	var resolved := CadExpression.evaluate_params(new_list)
	var errs: Dictionary = resolved["errors"]
	if errs.has(pname):
		return "%s: %s" % [pname, String(errs[pname])]
	for prm: CadParameter in new_list:
		prm.value = float((resolved["values"] as Dictionary).get(prm.name, 0.0))
	set_parameters(new_list)
	return ""


## Delete a parameter — refused while anything still references it, because
## silently zeroing every dependent is how documents rot. "" on success.
func remove_parameter(pname: String) -> String:
	for prm in doc.parameters:
		if prm.name != pname \
				and CadExpression.identifiers(prm.expr).has(pname):
			return "'%s' is used by parameter '%s'" % [pname, prm.name]
	for f in doc.features:
		if not (f is SketchFeature):
			continue
		for c in (f as SketchFeature).sketch.constraints:
			if c.expr != "" and CadExpression.identifiers(c.expr).has(pname):
				return "'%s' is used by a dimension in %s" % [pname, f.name]
	var new_list: Array = []
	for prm in doc.parameters:
		if prm.name != pname:
			new_list.append(prm)
	if new_list.size() == doc.parameters.size():
		return "No parameter named '%s'" % pname
	set_parameters(new_list)
	return ""


func set_parameters(new_params: Array) -> void:
	var batch := CmdMergeBatch.new("Parameters", [])
	stack.push_no_merge(batch)
	stack.push(CmdSetParameters.new(doc.parameters, new_params))
	for f in doc.features:
		if not (f is SketchFeature):
			continue
		var sk := (f as SketchFeature).sketch
		var changed := false
		var changed_cons: Array = []
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
				changed_cons.append(edited)
		if changed:
			stack.push(CmdSetConstraints.new(f.id, sk.constraints, after))
			# Solve scoped to the components the changed dimensions touch —
			# a parameter edit must not disturb unrelated geometry.
			var pins := _pins_outside_components(sk, changed_cons)
			if f.id == active_sketch_id:
				solve_followers(pins)
			else:
				var res := ConstraintSolver.solve(sk, pins)
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


## Point ids OUTSIDE the constraint-connected component(s) of `cons` — the
## solve after editing a dimension may only move geometry actually coupled to
## it. The relax solver nudges everything it visits by residual dust, and on
## stiff tangent-arc chains those nudges accumulated into visible drift (an
## arc resizing because an UNRELATED line's dimension changed — QA §M19).
func _pins_outside_components(sk: Sketch, cons: Array) -> Array:
	var parent := {}
	var find := func(x: String) -> String:
		var r := x
		while parent.get(r, r) != r:
			r = parent[r]
		return r
	var union := func(a: String, b: String) -> void:
		var ra: String = find.call(a)
		var rb: String = find.call(b)
		if ra != rb:
			parent[rb] = ra
	var ent_pts := func(id: String) -> Array:
		var e := sk.entity(id)
		if e == null:
			return []
		if e.kind() == "point":
			return [e.id]
		return e.point_refs()
	for e in sk.entities():
		if e.kind() == "point":
			parent[e.id] = e.id
	for e in sk.entities():
		var pts: Array = e.point_refs()
		for i in range(1, pts.size()):
			union.call(pts[0], pts[i])
	for cc in sk.constraints:
		var all: Array = []
		for op in cc.operands:
			all.append_array(ent_pts.call(String(op)))
		for i in range(1, all.size()):
			union.call(all[0], all[i])
	var seed_roots := {}
	for c: SketchConstraint in cons:
		for op in c.operands:
			for pid: String in ent_pts.call(String(op)):
				seed_roots[find.call(pid)] = true
	var pins: Array = []
	for e in sk.entities():
		if e.kind() == "point" and not seed_roots.has(find.call(e.id)):
			pins.append(e.id)
	return pins


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


## The APPLY-time variant of `solve_followers`: constraining geometry should
## move POINTS onto the constraint, not resize circles — the free solve split
## a Point-On's residual between the point and the circle's radius, so
## applying Point-On visibly inflated the circle (surfaced by the QA §M17-5
## fixture: r=20 grew to r=34). Try the solve with every radius pinned first;
## only when that cannot satisfy the constraints (a tangency that genuinely
## needs the radius to give) fall back to the free solve.
func solve_followers_prefer_points(pinned = []) -> void:
	var sk := active_sketch()
	if sk == null or sk.constraints.is_empty():
		return
	var all_radii: Array = []
	for e in sk.entities():
		if e.kind() == "circle":
			all_radii.append(e.id)
	if all_radii.is_empty():
		solve_followers(pinned)
		return
	var res := ConstraintSolver.solve(sk, pinned, all_radii)
	var ok := not bool(res.get("diverged", false))
	if ok:
		# Judge the radius-pinned result on a clone carrying its moves.
		var clone := Sketch.from_dict(sk.to_dict())
		for pid: String in res["points"]:
			clone.point(pid).pos = res["points"][pid]
		for c in clone.constraints:
			if c.driven:
				continue
			if ConstraintSolver.error_of(clone, c) > 0.01:
				ok = false
				break
	if not ok:
		solve_followers(pinned)
		return
	if not (res["points"] as Dictionary).is_empty():
		stack.push(CmdMovePoints.new(active_sketch_id, res["points"]))


## The drag-time variant of `solve_followers`: hand the solve to the worker
## thread and return immediately — `_poll_threaded_solver` applies whichever
## result lands, and only the newest ever does. Falls back to the synchronous
## solve when the thread is unavailable. Gesture END must not use this: the
## final state has to be exact before the batch seals, so pointer_up runs
## `threaded_solver.cancel()` + a synchronous `solve_followers`.
func solve_followers_async(pinned = []) -> void:
	var sk := active_sketch()
	if sk == null or sk.constraints.is_empty():
		return
	if threaded_solver == null or not threaded_solver.available():
		solve_followers(pinned)
		return
	threaded_solver.request(active_sketch_id, sk, pinned)


## Replace the whole document (open/new). History is cleared — a loaded file
## starts with a clean timeline of its own.
func load_document(new_doc: CadDocument) -> void:
	doc = new_doc
	stack.doc = new_doc
	stack.clear()
	Projector.refresh(doc)
	active_sketch_id = ""
	picking_plane = false
	picking_offset_base = false
	picking_look_at = false
	mode = Mode.MODEL
	sketch_orbit = false
	sketch_view.clear_projection_3d()
	sketch_view.visible = false
	world.set_planes_visible(false)
	world.set_grid_plane("XY")
	world.set_grid_unit(doc.display_unit)
	world.rebuild_sketches(doc)
	timeline.refresh()
	browser.refresh()
	_refresh_views_pick()
	if _unit_pick != null:
		_unit_pick.select(_unit_pick.get_item_index(doc.display_unit))
	# A file that remembers its camera reopens exactly where it was left.
	if not doc.camera.is_empty():
		apply_named_view(doc.camera, false)
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
	# Theme before any control exists, so everything is born themed (M26).
	ThemeService.load_settings()
	theme = ThemeService.build_theme()
	# Themed backdrop behind everything: the space around the shelf groups is
	# otherwise the engine's dark clear color (QA §M26.5). A Panel re-reads
	# its stylebox on theme change.
	var backdrop := Panel.new()
	backdrop.name = "Backdrop"
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	# Every lazily-created dialog is a raw Window with the same dark clear
	# color problem — give each one a themed backdrop as it enters the tree.
	child_entered_tree.connect(_on_child_entered)
	var vbox := VBoxContainer.new()
	vbox.name = "Root"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	_build_menu_bar(vbox)
	_build_ribbon(vbox)

	# Browser on the left, canvas on the right — the browser is a sibling of
	# the canvas, not an overlay on it, so it never eats viewport clicks.
	var body_row := HBoxContainer.new()
	body_row.name = "BodyRow"
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_theme_constant_override("separation", 0)
	vbox.add_child(body_row)

	_build_browser_panel(body_row)

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
		world.update_grid(rig.view_height_mm(), rig.target)
		# Off-axis sketching projects the overlay chrome (vertex markers,
		# selection, badges) through this camera — every camera move must
		# repaint it, or the points trail the 3D lines until the orbit ends.
		if sketch_orbit and overlay != null:
			overlay.queue_redraw())
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
	# Reference images on the active sketch plane (M30).
	sketch_view.canvases_provider = func() -> Array:
		var out: Array = []
		if mode != Mode.SKETCH:
			return out
		var sf := doc.sketch_feature(active_sketch_id)
		if sf == null:
			return out
		for f in doc.live_features():
			var cf := f as CanvasFeature
			if cf == null or cf.plane != sf.plane \
					or not world.canvas_shown(cf.id):
				continue
			out.append({"tex": cf.texture(), "center": cf.center,
				"width_mm": cf.width_mm, "height_mm": cf.height_mm(),
				"rotation": cf.rotation, "opacity": cf.opacity})
		return out
	stack_area.add_child(sketch_view)

	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_on_overlay_draw)
	stack_area.add_child(overlay)

	# Viewing controls float over the canvas as HUD pills (M36 design) —
	# the canvas keeps every pixel the ribbon does not need.
	_build_hud(stack_area)

	view_cube = ViewCube.new()
	view_cube.name = "ViewCube"
	view_cube.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	view_cube.position = Vector2(-ViewCube.SIZE_PX - 8,
		ThemeService.metric("hud_height") + 8)
	view_cube.face_picked.connect(_on_cube_face)
	view_cube.nav_requested.connect(_on_cube_nav)
	# The rig already emitted `moved` from its own _ready, before this widget
	# existed — hand it the current orientation so it starts in agreement with
	# the 3/4 home view instead of facing front until the first orbit.
	view_cube.rotation_hint = rig.rotation
	stack_area.add_child(view_cube)

	_build_timeline_panel(vbox)
	timeline.refresh()
	browser.refresh()
	# Boolean bakes land a frame after the model change — re-list bodies when
	# they do, or the browser shows stale rows (deferred: the rebuild can be
	# triggered from inside a Tree mouse callback, where refresh must not run).
	world.bodies_rebuilt.connect(func() -> void:
		browser.refresh.call_deferred())
	# The rig emitted `moved` from its own _ready, before the connect above.
	world.set_grid_unit(doc.display_unit)
	world.update_grid(rig.view_height_mm(), rig.target)

	_build_status_bar(vbox)
	_apply_theme_metrics()


## Menu bar (M36): brand mark, File / Edit / View / Help menus that mirror
## the ribbon's actions, and the document unit at the right edge.
func _build_menu_bar(parent: Control) -> void:
	_menu_panel = PanelContainer.new()
	_menu_panel.name = "MenuBarPanel"
	_menu_panel.theme_type_variation = "MenuBarPanel"
	parent.add_child(_menu_panel)
	var row := HBoxContainer.new()
	row.name = "MenuRow"
	row.add_theme_constant_override("separation", 6)
	_menu_panel.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size.x = 4
	row.add_child(pad)
	var mark := ColorRect.new()
	mark.name = "BrandMark"
	mark.custom_minimum_size = Vector2(14, 14)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mark.color = ThemeService.col("accent")
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)
	_brand_mark = mark
	# Everything in the bar sits on one centre line: labels centre their
	# text, the MenuBar shrinks to its own height (QA §M36 — the menus used
	# to hang from the top edge beside vertically centred labels).
	var brand := Label.new()
	brand.name = "BrandLabel"
	brand.text = "EchoCAD"
	brand.theme_type_variation = "BrandLabel"
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(brand)
	_doc_label = Label.new()
	_doc_label.name = "DocLabel"
	_doc_label.theme_type_variation = "DimLabel"
	_doc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_doc_label)

	_menu_bar = MenuBar.new()
	_menu_bar.name = "MenuBar"
	_menu_bar.flat = true
	_menu_bar.focus_mode = Control.FOCUS_NONE
	_menu_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Shortcuts in the menus are accelerators for DISPLAY (right-aligned, in
	# the dim accelerator colour); key routing stays with the canvas
	# (handle_app_key), so the bar must not fire them a second time.
	_menu_bar.set_process_shortcut_input(false)
	row.add_child(_menu_bar)

	var file := PopupMenu.new()
	file.name = "File"
	_menu_add(file, "Open…", open_interactive, "Ctrl+O")
	_menu_add(file, "Save", func() -> void: save_interactive(false), "Ctrl+S")
	_menu_add(file, "Save As…", func() -> void: save_interactive(true),
		"Ctrl+Shift+S")
	file.add_separator()
	_menu_add(file, "Import DXF…", import_dxf_interactive)
	_menu_add(file, "Import SVG…", import_svg_interactive)
	_menu_add(file, "Insert Canvas…", import_canvas_interactive)
	file.add_separator()
	_menu_add(file, "Export DXF…", export_dxf_interactive)
	_menu_add(file, "Export STL…", func() -> void: export_stl_interactive())
	file.add_separator()
	_menu_add(file, "Preferences…", _open_prefs_dialog)
	_menu_bar.add_child(file)

	var edit := PopupMenu.new()
	edit.name = "Edit"
	_menu_add(edit, "Undo", func() -> void: stack.undo(), "Ctrl+Z")
	_menu_add(edit, "Redo", func() -> void: stack.redo(), "Ctrl+Shift+Z")
	edit.add_separator()
	_menu_add(edit, "Parameters…", _open_params_dialog)
	_menu_bar.add_child(edit)

	var view := PopupMenu.new()
	view.name = "View"
	_menu_add(view, "Fit to View", fit_view, "F")
	_menu_add(view, "Look At…", _on_look_at_pressed)
	_menu_add(view, "Orthographic", func() -> void:
		set_model_projection(not ThemeService.model_ortho), "P")
	view.set_item_as_checkable(view.item_count - 1, true)
	_view_menu_ortho_idx = view.item_count - 1
	view.add_separator("Theme")
	_theme_menu_first = view.item_count
	_menu_bar.add_child(view)
	_view_menu = view
	_rebuild_theme_menu()

	var help := PopupMenu.new()
	help.name = "Help"
	_menu_add(help, "Theming guide (docs/THEMING.md)", func() -> void:
		OS.shell_open(ProjectSettings.globalize_path("res://docs/THEMING.md")))
	_menu_add(help, "About EchoCAD", _show_about)
	_menu_bar.add_child(help)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_unit_badge = Label.new()
	_unit_badge.name = "UnitBadge"
	_unit_badge.theme_type_variation = "DimLabel"
	_unit_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_unit_badge)
	var pad2 := Control.new()
	pad2.custom_minimum_size.x = 6
	row.add_child(pad2)


## Add a menu entry whose handler lives in the item metadata. The shortcut
## text is a hint only — the canvas owns key routing (handle_app_key).
func _menu_add(menu: PopupMenu, label: String, handler: Callable,
		shortcut := "") -> void:
	var idx := menu.item_count
	menu.add_item(label, idx, _accel_from_text(shortcut))
	menu.set_item_metadata(idx, handler)
	if not menu.id_pressed.is_connected(_on_menu_id):
		menu.id_pressed.connect(_on_menu_id.bind(menu))


## "Ctrl+Shift+S" -> the Key bitmask PopupMenu renders as a right-aligned
## accelerator. Unknown text yields KEY_NONE (no accelerator column).
func _accel_from_text(text: String) -> Key:
	if text == "":
		return KEY_NONE
	var mask := 0
	var key := KEY_NONE
	for part in text.split("+"):
		match part.to_lower():
			"ctrl": mask |= KEY_MASK_CTRL
			"shift": mask |= KEY_MASK_SHIFT
			"alt": mask |= KEY_MASK_ALT
			_: key = OS.find_keycode_from_string(part)
	if key == KEY_NONE:
		return KEY_NONE
	return (key | mask) as Key


func _on_menu_id(id: int, menu: PopupMenu) -> void:
	var idx := menu.get_item_index(id)
	if idx < 0:
		return
	var h = menu.get_item_metadata(idx)
	if h is Callable:
		(h as Callable).call()


## View ▸ Theme: one radio entry per discovered theme, so a user can flip
## themes without opening Preferences.
func _rebuild_theme_menu() -> void:
	if _view_menu == null:
		return
	while _view_menu.item_count > _theme_menu_first:
		_view_menu.remove_item(_view_menu.item_count - 1)
	for t: Dictionary in ThemeService.available_themes():
		var idx := _view_menu.item_count
		var label := String(t["name"]) + ("" if bool(t["builtin"]) else "  (user)")
		_view_menu.add_radio_check_item(label, idx)
		_view_menu.set_item_checked(idx, t["id"] == ThemeService.theme_id)
		var id := String(t["id"])
		_view_menu.set_item_metadata(idx, func() -> void: set_theme_id(id))
	if _view_menu_ortho_idx >= 0:
		_view_menu.set_item_checked(_view_menu_ortho_idx, ThemeService.model_ortho)


func _show_about() -> void:
	var d := AcceptDialog.new()
	d.name = "AboutDialog"
	d.title = "About EchoCAD"
	d.dialog_text = ("EchoCAD — parametric CAD in Godot %s\n\nTheme: %s\n"
		+ "UI font: Archivo (SIL OFL)") % [Engine.get_version_info()["string"],
		ThemeService.theme_id]
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()


## Related sketch tools that share one ribbon button (QA §M36): the head
## tool fronts the stack, the rest open on right-click / long-press.
const TOOL_STACKS := {
	"rect": ["rect", "center_rect"],
	"circle": ["circle", "circle3"],
	"arc3": ["arc3", "center_arc", "tangent_arc"],
	"slot": ["slot", "slot_overall", "slot_center"],
	"rect_pattern": ["rect_pattern", "circ_pattern"],
}


## The ribbon (M36): a 92px strip of captioned groups. Model and sketch mode
## each own a row of groups; _refresh_ui swaps them. Every button is the same
## icon square (title under it when "Show tool names" is on), and every
## group is a single row of them.
func _build_ribbon(parent: Control) -> void:
	_ribbon = PanelContainer.new()
	_ribbon.name = "Ribbon"
	_ribbon.theme_type_variation = "Ribbon"
	parent.add_child(_ribbon)
	# [ mode rows (expand) | undo/redo tail ]
	var ribbon_row := HBoxContainer.new()
	ribbon_row.name = "RibbonRow"
	ribbon_row.add_theme_constant_override("separation", 0)
	_ribbon.add_child(ribbon_row)
	var rows := Control.new()
	rows.name = "RibbonRows"
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ribbon_row.add_child(rows)
	_ribbon_rows = rows
	# The mode flows overlay each other inside a plain Control, which hides
	# their wrapped height — track it so a narrow window grows the ribbon
	# instead of clipping the second row of groups.
	rows.resized.connect(_fit_ribbon_height)
	rows.resized.connect(request_ribbon_layout)
	_flyout_timer = Timer.new()
	_flyout_timer.name = "FlyoutTimer"
	_flyout_timer.one_shot = true
	_flyout_timer.wait_time = 0.45
	_flyout_timer.timeout.connect(_on_flyout_timeout)
	add_child(_flyout_timer)

	# --- model mode ----------------------------------------------------------
	# One row, never wrapping: groups that do not fit collapse their trailing
	# tools into a "more" flyout (see _layout_ribbon).
	var model := HBoxContainer.new()
	model.name = "TopBar"
	model.set_anchors_preset(Control.PRESET_FULL_RECT)
	model.add_theme_constant_override("separation", 0)
	rows.add_child(model)
	_model_ribbon = model
	model.minimum_size_changed.connect(_fit_ribbon_height)

	var g_create := _tool_grid(_shelf_group(model, "Create"), 4)
	_btn_create = _tool_button(g_create, "New Sketch", _on_create_sketch,
		"create_sketch")
	_btn_create.name = "CreateSketchBtn"
	_btn_create.tooltip_text = "Create Sketch: pick a plane or flat face"
	_btn_extrude = _tool_button(g_create, "Extrude", _on_extrude_pressed, "extrude")
	_btn_extrude.name = "ExtrudeBtn"
	_btn_revolve = _tool_button(g_create, "Revolve", _on_revolve_pressed, "revolve")
	_btn_revolve.name = "RevolveBtn"
	var sweepb := _tool_button(g_create, "Sweep", _on_sweep_pressed, "sweep")
	sweepb.name = "SweepBtn"
	sweepb.tooltip_text = "Sweep a profile along a sketch path"
	var loftb := _tool_button(g_create, "Loft", _on_loft_pressed, "loft")
	loftb.name = "LoftBtn"
	loftb.tooltip_text = "Loft between two or more profiles"
	var mirrb := _tool_button(g_create, "Mirror Body", _on_mirror_body_pressed,
		"mirror_body")
	mirrb.name = "MirrorBodyBtn"
	mirrb.tooltip_text = "Mirror the selected body across a plane"
	var pattb := _tool_button(g_create, "Pattern",
		func() -> void: open_pattern_dialog(""), "pattern_body")
	pattb.name = "PatternBodyBtn"
	pattb.tooltip_text = "Linear/circular pattern of the selected body"

	_divider(model)
	var g_modify := _tool_grid(_shelf_group(model, "Modify"), 2)
	var filb := _tool_button(g_modify, "Fillet", func() -> void:
		open_edge_treat_dialog("", EdgeTreatFeature.KIND_FILLET), "fillet_3d")
	filb.name = "FilletEdgesBtn"
	filb.tooltip_text = ("Round edges of a plain extrude: select the body, "
		+ "then click the edges to round")
	var chab := _tool_button(g_modify, "Chamfer", func() -> void:
		open_edge_treat_dialog("", EdgeTreatFeature.KIND_CHAMFER), "chamfer_3d")
	chab.name = "ChamferEdgesBtn"
	chab.tooltip_text = ("Chamfer edges of a plain extrude: select the body, "
		+ "then click the edges to cut")
	var moveb := _tool_button(g_modify, "Move Body",
		func() -> void: open_move_dialog(""), "move_body")
	moveb.name = "MoveBodyBtn"
	moveb.tooltip_text = "Move/rotate the selected body (a timeline feature)"
	var copyb := _tool_button(g_modify, "Copy Body",
		func() -> void: open_copy_dialog(""), "copy_body")
	copyb.name = "CopyBodyBtn"
	copyb.tooltip_text = "Parametric copy of the selected body at an offset"

	_divider(model)
	var g_construct := _shelf_group(model, "Construct")
	_btn_offset_plane = _tool_button(g_construct, "Offset Plane",
		_on_offset_plane_pressed, "offset_plane")
	_btn_offset_plane.name = "OffsetPlaneBtn"

	_divider(model)
	var g_insert := _tool_grid(_shelf_group(model, "Insert"), 2)
	var dxfi := _tool_button(g_insert, "Import DXF", import_dxf_interactive,
		"import_dxf")
	dxfi.name = "ImportDxfBtn"
	var svgi := _tool_button(g_insert, "Import SVG", import_svg_interactive,
		"import_svg")
	svgi.name = "ImportSvgBtn"
	var canvb := _tool_button(g_insert, "Canvas", import_canvas_interactive,
		"canvas")
	canvb.name = "ImportCanvasBtn"
	canvb.tooltip_text = "Insert a reference image (PNG/JPEG) on a plane"

	_divider(model)
	var g_make := _tool_grid(_shelf_group(model, "Make"), 2)
	var stlb := _tool_button(g_make, "Export STL",
		func() -> void: export_stl_interactive(), "export_stl")
	stlb.name = "ExportStlBtn"
	var dxfb := _tool_button(g_make, "Export DXF", export_dxf_interactive,
		"export_dxf")
	dxfb.name = "ExportDxfBtn"
	# Save / Open live in the File menu (QA §M36: no File group in the
	# ribbon). The buttons stay as hidden, named controls so Ctrl+S/Ctrl+O
	# tooltips and RPC lookups keep working.
	_btn_save = _tool_button(g_make, "Save",
		func() -> void: save_interactive(false), "save")
	_btn_save.name = "SaveBtn"
	_btn_save.tooltip_text = "Save (Ctrl+S)"
	_btn_save.visible = false
	_btn_open = _tool_button(g_make, "Open", open_interactive, "open")
	_btn_open.name = "OpenBtn"
	_btn_open.tooltip_text = "Open (Ctrl+O)"
	_btn_open.visible = false

	# --- sketch mode --------------------------------------------------------
	var sketch := HBoxContainer.new()
	sketch.name = "ToolBar"
	sketch.set_anchors_preset(Control.PRESET_FULL_RECT)
	sketch.add_theme_constant_override("separation", 0)
	rows.add_child(sketch)
	_tool_bar = sketch
	sketch.minimum_size_changed.connect(_fit_ribbon_height)

	var g_select := _shelf_group(sketch, "Select")
	_divider(sketch)
	var g_sk_create := _shelf_group(sketch, "SketchCreate", "Create")
	_divider(sketch)
	var g_sk_modify := _shelf_group(sketch, "SketchModify", "Modify")
	_divider(sketch)
	var g_constrain := _shelf_group(sketch, "Constrain")
	_constraint_bar = _shelf_groups["Constrain"]
	var group := ButtonGroup.new()
	var create_grid := _tool_grid(g_sk_create, 4)
	var modify_grid := _tool_grid(g_sk_modify, 4)
	var cons_grid := _tool_grid(g_constrain, 7)
	var stacked := {}
	for head: String in TOOL_STACKS:
		for tid: String in TOOL_STACKS[head]:
			stacked[tid] = head
	for tid: String in tools.tool_ids():
		if stacked.has(tid) and stacked[tid] != tid:
			continue   # lives in its head's flyout
		var home := _tool_group_for(tid, g_select, g_sk_create, g_sk_modify,
			g_constrain)
		var parent_ctl: Control = home
		if home == g_sk_create:
			parent_ctl = create_grid
		elif home == g_sk_modify:
			parent_ctl = modify_grid
		elif home == g_constrain:
			parent_ctl = cons_grid
		if stacked.has(tid):
			var variants: Array = []
			for vid: String in TOOL_STACKS[tid]:
				var vt := tools.get_tool(vid)
				variants.append({"id": vid, "title": vt.title, "icon": vid,
					"tooltip": _tool_tooltip(vt),
					"handler": func() -> void: tools.set_active(vid)})
			var st := _tool_stack(parent_ctl, variants, group)
			_tool_buttons[tid] = st["btn"]
			for v: Dictionary in st["variants"]:
				if v["id"] != tid:
					_tool_buttons[v["id"]] = v["btn"]
			continue
		var t := tools.get_tool(tid)
		var b := _tool_button(parent_ctl, t.title, Callable(), tid)
		b.name = _pascal(tid) + "ToolBtn"
		b.tooltip_text = _tool_tooltip(t)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: tools.set_active(tid))
		_tool_buttons[tid] = b

	var cons_defs := [
		["Coincident", SketchConstraint.Type.COINCIDENT, "const_coincident"],
		["Horizontal", SketchConstraint.Type.HORIZONTAL, "const_horizontal"],
		["Vertical", SketchConstraint.Type.VERTICAL, "const_vertical"],
		["Parallel", SketchConstraint.Type.PARALLEL, "const_parallel"],
		["Perpendicular", SketchConstraint.Type.PERPENDICULAR,
			"const_perpendicular"],
		["Collinear", SketchConstraint.Type.COLLINEAR, "const_collinear"],
		["Equal", SketchConstraint.Type.EQUAL, "const_equal"],
		["Midpoint", SketchConstraint.Type.MIDPOINT, "const_midpoint"],
		["Concentric", SketchConstraint.Type.CONCENTRIC, "const_concentric"],
		["Tangent", SketchConstraint.Type.TANGENT, "const_tangent"],
		["PointOn", SketchConstraint.Type.POINT_ON, "const_point_on"],
		["Fix", SketchConstraint.Type.FIX, "const_fix"],
		["Symmetry", SketchConstraint.Type.SYMMETRY, "const_symmetry"],
	]
	for def in cons_defs:
		var cb := _tool_button(cons_grid, def[0],
			func() -> void: arm_constraint(def[1], String(def[0])), String(def[2]))
		cb.name = String(def[0]) + "ConBtn"
		cb.toggle_mode = true
		cb.button_group = group
		_con_buttons[def[1]] = cb

	# Snap + inference toggles. These already existed as `prefs` entries that
	# only `action.set_pref` could reach, which made them unusable by hand and
	# unverifiable in manual QA. Both paths now drive the same state.
	_divider(sketch)
	var g_opts := _shelf_group(sketch, "Options")
	var opts_col := VBoxContainer.new()
	opts_col.name = "OptionsColumn"
	opts_col.add_theme_constant_override("separation", 0)
	g_opts.add_child(opts_col)
	var snap_box := CheckBox.new()
	snap_box.name = "GridSnapChk"
	snap_box.text = "Snap to grid"
	snap_box.focus_mode = Control.FOCUS_NONE
	snap_box.button_pressed = snap.grid_enabled
	snap_box.toggled.connect(func(on: bool) -> void: snap.grid_enabled = on)
	opts_col.add_child(snap_box)
	_snap_check = snap_box

	var infer_box := CheckBox.new()
	infer_box.name = "InferenceChk"
	infer_box.text = "Infer constraints"
	infer_box.focus_mode = Control.FOCUS_NONE
	infer_box.button_pressed = bool(prefs.get("inference", true))
	infer_box.toggled.connect(func(on: bool) -> void: prefs["inference"] = on)
	opts_col.add_child(infer_box)
	_infer_check = infer_box

	# Construction MODE: newly drawn curves come out as construction geometry
	# while this is on (M21 QA fix). X with nothing selected toggles it too,
	# so X mid-line-chain flips the segments still to come.
	var cons_box := CheckBox.new()
	cons_box.name = "ConstructionChk"
	cons_box.text = "Construction mode"
	cons_box.focus_mode = Control.FOCUS_NONE
	cons_box.button_pressed = construction_mode
	cons_box.toggled.connect(func(on: bool) -> void: construction_mode = on)
	opts_col.add_child(cons_box)
	_construction_check = cons_box

	_divider(sketch)
	var g_finish := _shelf_group(sketch, "Sketch")
	_btn_finish = _button(g_finish, "Finish Sketch", _on_finish_sketch,
		"finish_sketch")
	_btn_finish.name = "FinishSketchBtn"
	_btn_finish.theme_type_variation = "PrimaryButton"
	_btn_finish.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_finish.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	_btn_finish.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_btn_finish.custom_minimum_size = Vector2(
		ThemeService.metric("big_button_w") + 14, ThemeService.metric("big_button_h"))

	# --- shared tail: undo / redo at the right edge of either row --------------
	var tail_wrap := MarginContainer.new()
	tail_wrap.name = "RibbonTailWrap"
	tail_wrap.add_theme_constant_override("margin_left", 10)
	tail_wrap.add_theme_constant_override("margin_right", 10)
	tail_wrap.add_theme_constant_override("margin_top", 6)
	ribbon_row.add_child(tail_wrap)
	_ribbon_tail = HBoxContainer.new()
	_ribbon_tail.name = "RibbonTail"
	_ribbon_tail.add_theme_constant_override("separation", 2)
	_ribbon_tail.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tail_wrap.add_child(_ribbon_tail)
	_btn_undo = _tool_button(_ribbon_tail, "Undo",
		func() -> void: stack.undo(), "undo", false)
	_btn_undo.name = "UndoBtn"
	_btn_undo.tooltip_text = "Undo (Ctrl+Z)"
	_btn_redo = _tool_button(_ribbon_tail, "Redo",
		func() -> void: stack.redo(), "redo", false)
	_btn_redo.name = "RedoBtn"
	_btn_redo.tooltip_text = "Redo (Ctrl+Shift+Z)"
	# Parameters matter in both modes (dimensions drive them), so the single
	# button lives in the shared tail rather than in a per-mode group.
	var pbtn := _tool_button(_ribbon_tail, "Parameters", _open_params_dialog,
		"parameters", false)
	pbtn.name = "ParametersBtn"
	pbtn.tooltip_text = "Parameters: named values for dimensions"
	_apply_tool_labels()


## Ribbon height = theme metric, or the visible flow's wrapped height when
## groups spilled onto a second row (narrow windows).
func _fit_ribbon_height() -> void:
	if _ribbon_rows == null or _ribbon == null:
		return
	var flow: Control = _tool_bar if mode == Mode.SKETCH else _model_ribbon
	var want := ThemeService.metric("ribbon_height")
	if flow != null:
		# +5 top content margin of the Ribbon panel, +1 bottom border.
		want = maxf(want, flow.get_combined_minimum_size().y + 6.0)
	if not is_equal_approx(_ribbon.custom_minimum_size.y, want):
		_ribbon.custom_minimum_size.y = want


## Browser side panel (M36): a captioned header over the BrowserTree.
func _build_browser_panel(parent: Control) -> void:
	_browser_panel = PanelContainer.new()
	_browser_panel.name = "BrowserPanel"
	_browser_panel.theme_type_variation = "SidePanel"
	_browser_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_browser_panel)
	var col := VBoxContainer.new()
	col.name = "BrowserColumn"
	col.add_theme_constant_override("separation", 0)
	_browser_panel.add_child(col)
	var header := PanelContainer.new()
	header.name = "BrowserHeader"
	header.theme_type_variation = "PanelHeader"
	header.custom_minimum_size.y = 26
	col.add_child(header)
	var hl := Label.new()
	hl.name = "BrowserHeaderLabel"
	hl.text = "BROWSER"
	hl.theme_type_variation = "HeaderLabel"
	hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(hl)
	browser = BrowserTree.new()
	browser.app = self
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(browser)


## Viewport HUD (M36): the viewing controls as translucent pills in the
## canvas's top-left corner — orbit pivot, Look At, Fit | projection |
## named views | preferences. Same control names as the old View shelf group.
func _build_hud(parent: Control) -> void:
	var hud := HBoxContainer.new()
	hud.name = "Hud"
	hud.position = Vector2(10, 10)
	hud.add_theme_constant_override("separation", 6)
	parent.add_child(hud)
	_hud = hud

	var nav := _hud_pill(hud, "NavPill")
	# Orbit pivot: Fusion's body-center is the default, Blender-style
	# under-cursor and plain view-center are the alternatives.
	_pivot_pick = OptionButton.new()
	_pivot_pick.name = "PivotModeBtn"
	_pivot_pick.focus_mode = Control.FOCUS_NONE
	_pivot_pick.theme_type_variation = "HudButton"
	_pivot_pick.flat = true
	_pivot_pick.add_item("Orbit: Body Center", OrbitCamera.PivotMode.BODY_CENTER)
	_pivot_pick.add_item("Orbit: Under Cursor", OrbitCamera.PivotMode.ORBIT_POINT)
	_pivot_pick.add_item("Orbit: View Center", OrbitCamera.PivotMode.VIEW_CENTER)
	_pivot_pick.item_selected.connect(func(i: int) -> void:
		set_pivot_mode(_pivot_pick.get_item_id(i) as OrbitCamera.PivotMode))
	nav.add_child(_pivot_pick)
	var lookb := _hud_button(nav, "Look At", _on_look_at_pressed, "look_at")
	lookb.name = "LookAtBtn"
	lookb.tooltip_text = "Look At: square the view to a plane or flat face"
	var fitb := _hud_button(nav, "Fit", fit_view, "fit_view")
	fitb.name = "FitBtn"
	fitb.tooltip_text = "Fit the model in view (F)"

	var proj := _hud_pill(hud, "ProjectionPill")
	_btn_ortho = _hud_button(proj, "ORTHO", func() -> void:
		set_model_projection(_btn_ortho.button_pressed), "camera_ortho")
	_btn_ortho.name = "OrthoBtn"
	_btn_ortho.toggle_mode = true
	_btn_ortho.tooltip_text = "Orthographic projection (P)"

	var views := _hud_pill(hud, "ViewsPill")
	_views_pick = OptionButton.new()
	_views_pick.name = "ViewsPick"
	_views_pick.focus_mode = Control.FOCUS_NONE
	_views_pick.theme_type_variation = "HudButton"
	_views_pick.flat = true
	_views_pick.fit_to_longest_item = false
	_views_pick.item_selected.connect(_on_views_pick)
	views.add_child(_views_pick)
	_refresh_views_pick()

	var prefs_pill := _hud_pill(hud, "PrefsPill")
	var prefb := _hud_button(prefs_pill, "", _open_prefs_dialog, "preferences")
	prefb.name = "PreferencesBtn"
	prefb.tooltip_text = "Preferences: theme, units"


func _hud_pill(parent: Control, pname: String) -> HBoxContainer:
	var pill := PanelContainer.new()
	pill.name = pname
	pill.theme_type_variation = "HudPanel"
	pill.custom_minimum_size.y = ThemeService.metric("hud_height")
	parent.add_child(pill)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	pill.add_child(row)
	return row


func _hud_button(parent: Control, text: String, handler: Callable,
		icon_name := "") -> Button:
	var b := Button.new()
	b.text = text
	b.icon = ThemeService.icon(icon_name)
	b.tooltip_text = text
	b.theme_type_variation = "HudButton"
	b.focus_mode = Control.FOCUS_NONE
	if not handler.is_null():
		b.pressed.connect(handler)
	parent.add_child(b)
	return b


## Timeline strip (M36): the feature chips inside a bordered 52px panel with
## an operation count at the right.
func _build_timeline_panel(parent: Control) -> void:
	_timeline_panel = PanelContainer.new()
	_timeline_panel.name = "TimelinePanel"
	_timeline_panel.theme_type_variation = "TimelinePanel"
	parent.add_child(_timeline_panel)
	var row := HBoxContainer.new()
	row.name = "TimelineRow"
	row.add_theme_constant_override("separation", 8)
	_timeline_panel.add_child(row)
	var scroll := ScrollContainer.new()
	scroll.name = "TimelineScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(scroll)
	timeline = TimelineBar.new()
	timeline.app = self
	timeline.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scroll.add_child(timeline)
	_timeline_count = Label.new()
	_timeline_count.name = "TimelineCount"
	_timeline_count.theme_type_variation = "StatusKeyLabel"
	_timeline_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_timeline_count)


## Status bar (M36): MODE · hint · measure · DOF · zoom.
func _build_status_bar(parent: Control) -> void:
	_status_panel = PanelContainer.new()
	_status_panel.name = "StatusPanel"
	_status_panel.theme_type_variation = "StatusPanel"
	parent.add_child(_status_panel)
	var status := HBoxContainer.new()
	status.name = "StatusBar"
	status.add_theme_constant_override("separation", 14)
	_status_panel.add_child(status)
	_status_mode = _label(status, "MODEL")
	_status_mode.name = "StatusMode"
	_status_mode.theme_type_variation = "StatusKeyLabel"
	_status_hint = _label(status, "")
	_status_hint.name = "StatusHint"
	_status_hint.theme_type_variation = "StatusLabel"
	_status_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_ids = _label(status, "")
	_status_ids.name = "StatusIds"
	_status_ids.theme_type_variation = "StatusIdLabel"
	_status_measure = _label(status, "")
	_status_measure.name = "StatusMeasure"
	_status_measure.theme_type_variation = "StatusLabel"
	_status_dof = _label(status, "")
	_status_dof.name = "StatusDof"
	_status_dof.theme_type_variation = "StatusLabel"
	_status_zoom = _label(status, "")
	_status_zoom.name = "StatusZoom"
	_status_zoom.theme_type_variation = "StatusKeyLabel"
	for l in [_status_mode, _status_hint, _status_ids, _status_measure,
			_status_dof, _status_zoom]:
		(l as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER


## A plain themed button (dialogs, misc). Ribbon buttons use _tool_button so
## their footprint follows theme metrics and the tool-names preference.
func _button(parent: Control, text: String, handler: Callable,
		icon_name := "") -> Button:
	var b := Button.new()
	b.text = text
	b.icon = ThemeService.icon(icon_name)
	b.tooltip_text = text
	b.focus_mode = Control.FOCUS_NONE   # keys belong to the canvas, not buttons
	if not handler.is_null():
		b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _pascal(tid: String) -> String:
	var out := ""
	for part in tid.split("_"):
		out += part.substr(0, 1).to_upper() + part.substr(1)
	return out


func _tool_tooltip(t: SketchTool) -> String:
	return t.title if t.shortcut == KEY_NONE \
		else "%s (%s)" % [t.title, OS.get_keycode_string(t.shortcut)]


## Ribbon tool button: the one button style of the ribbon (QA §M36 — every
## button is the same icon square; the title appears under the icon only when
## "Show tool names" is on). `labelled` false keeps a button icon-only for
## good (the undo/redo tail).
func _tool_button(parent: Control, text: String, handler: Callable,
		icon_name := "", labelled := true) -> Button:
	var b := _button(parent, text, handler, icon_name)
	b.theme_type_variation = "ToolButton"
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.expand_icon = false
	b.clip_text = true
	if b.icon != null:
		b.text = ""
	b.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	b.custom_minimum_size = Vector2(ThemeService.metric("small_button_w"),
		ThemeService.metric("small_button_h"))
	if labelled:
		_ribbon_buttons.append({"btn": b, "title": text})
	return b


## The tool strip inside a group's button row. Every group lays its tools
## out in ONE row (QA round 2: two-row grids shrank the icons to fit; a
## single row lets them run at icon_big). `columns` is kept as the
## historical wrap width for callers but no longer wraps — it is recorded
## for the RPC layout query only.
func _tool_grid(row: Control, columns: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 64
	g.add_theme_constant_override("h_separation", 1)
	g.add_theme_constant_override("v_separation", 1)
	g.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(g)
	_ribbon_grids.append({"grid": g, "columns": columns})
	_make_overflow(g, row)
	return g


## The "more" button + flyout a tool strip collapses into. Built hidden at
## the end of `host`; _layout_ribbon moves tools in and out of the flyout.
func _make_overflow(host: GridContainer, row: Control) -> void:
	var more := _tool_button(host, "More", Callable(), "more")
	# Unique per group ("SketchCreateMoreBtn") so RPC clients can find the
	# owner of a collapsed tool's flyout.
	var panel := row.get_parent().get_parent() as Control
	more.name = String(panel.name).trim_suffix("Group") + "MoreBtn"
	more.tooltip_text = "More tools (not enough room in the ribbon)"
	more.visible = false
	var popup := PopupPanel.new()
	popup.name = "Flyout"
	var col := GridContainer.new()
	col.name = "Overflow"
	col.columns = 6
	col.add_theme_constant_override("h_separation", 1)
	col.add_theme_constant_override("v_separation", 1)
	popup.add_child(col)
	more.add_child(popup)
	var g := {"host": host, "row": row, "more": more, "popup": popup, "col": col}
	more.pressed.connect(func() -> void: _open_overflow(g))
	more.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			more.accept_event()
			_open_overflow(g))
	_overflow_groups.append(g)


func _open_overflow(g: Dictionary) -> void:
	var more := g["more"] as Button
	var popup := g["popup"] as PopupPanel
	var col := g["col"] as GridContainer
	col.columns = clampi(col.get_child_count(), 1, 6)
	popup.position = Vector2i(more.get_screen_position() + Vector2(0, more.size.y + 2))
	popup.popup()


## The mode flow a ribbon control lives in (TopBar or ToolBar).
func _flow_of(c: Node) -> Control:
	while c != null and c != _ribbon_rows:
		if c == _model_ribbon or c == _tool_bar:
			return c
		c = c.get_parent()
	return null


## Re-layout on the next idle frame (coalesces resize bursts).
func request_ribbon_layout() -> void:
	if _ribbon_layout_pending:
		return
	_ribbon_layout_pending = true
	_layout_ribbon.call_deferred()


## Fit the visible mode row into the ribbon's width WITHOUT wrapping: start
## from every tool shown, then while the row overflows take the last tool
## of the fullest strip into its "more" flyout — so every shelf keeps as
## many tools as the window allows and the widest shelves give first.
func _layout_ribbon() -> void:
	_ribbon_layout_pending = false
	if _ribbon_rows == null:
		return
	var flow: Control = _tool_bar if mode == Mode.SKETCH else _model_ribbon
	if flow == null:
		return
	var avail := _ribbon_rows.size.x
	if avail <= 0.0:
		return
	var groups: Array = []
	for g: Dictionary in _overflow_groups:
		if _flow_of(g["host"]) == flow:
			groups.append(g)
			_overflow_restore(g)
	var guard := 0
	while _flow_width(flow) > avail and guard < 256:
		guard += 1
		var best: Dictionary = {}
		var best_n := 1
		for g: Dictionary in groups:
			var n := _overflow_shown(g).size()
			if n > best_n:
				best_n = n
				best = g
		if best.is_empty():
			break
		_overflow_take_last(best)
	_fit_ribbon_height.call_deferred()


## Tools currently on the strip (visible ones, minus the "more" button).
func _overflow_shown(g: Dictionary) -> Array:
	var out: Array = []
	for c in (g["host"] as Control).get_children():
		if c != g["more"] and (c as Control).visible:
			out.append(c)
	return out


func _overflow_restore(g: Dictionary) -> void:
	var host := g["host"] as Control
	var col := g["col"] as Control
	var more := g["more"] as Button
	(g["popup"] as PopupPanel).hide()
	for c in col.get_children():
		col.remove_child(c)
		host.add_child(c)
	host.move_child(more, -1)
	more.visible = false


func _overflow_take_last(g: Dictionary) -> void:
	var shown := _overflow_shown(g)
	if shown.size() <= 1:
		return
	var b := shown[-1] as Control
	var host := g["host"] as Control
	var col := g["col"] as Control
	host.remove_child(b)
	col.add_child(b)
	col.move_child(b, 0)   # flyout keeps the strip's order
	(g["more"] as Button).visible = true


## Width the flow needs for its visible children, from their minimum sizes
## (layout has not run yet when this is asked, so measure by hand).
func _flow_width(flow: Control) -> float:
	var w := 0.0
	for c in flow.get_children():
		var ctl := c as Control
		if ctl == null or not ctl.visible:
			continue
		if ctl is MarginContainer and ctl.name.ends_with("Group"):
			w += _group_width(ctl)
		else:
			w += ctl.get_combined_minimum_size().x
	return w


func _group_width(panel: Control) -> float:
	var v := panel.get_child(0) as Control
	var row := v.get_node_or_null("Buttons") as Control
	var cap := v.get_node_or_null("Caption") as Control
	var margins := 20.0
	if row == null:
		return margins + panel.get_combined_minimum_size().x
	var row_w := 0.0
	var n := 0
	for c in row.get_children():
		var ctl := c as Control
		if ctl == null or not ctl.visible:
			continue
		n += 1
		if ctl is GridContainer:
			var gw := 0.0
			var gn := 0
			for b in ctl.get_children():
				var bc := b as Control
				if bc == null or not bc.visible:
					continue
				gn += 1
				gw += bc.get_combined_minimum_size().x
			row_w += gw + maxf(gn - 1, 0) * 1.0
		else:
			row_w += ctl.get_combined_minimum_size().x
	row_w += maxf(n - 1, 0) * 2.0
	var cap_w := cap.get_combined_minimum_size().x if cap != null else 0.0
	return margins + maxf(row_w, cap_w)


## Push the "Show tool names" preference into every ribbon button: titles
## under icons (wider, taller buttons; the ribbon grows to fit) or the
## default icon-only squares.
func _apply_tool_labels() -> void:
	var show := ThemeService.show_tool_names
	var sz := Vector2(ThemeService.metric("big_button_w"),
		ThemeService.metric("big_button_h")) if show \
		else Vector2(ThemeService.metric("small_button_w"),
			ThemeService.metric("small_button_h"))
	for e: Dictionary in _ribbon_buttons:
		var b := e["btn"] as Button
		if not is_instance_valid(b):
			continue
		b.text = String(e["title"]) if (show or b.icon == null) else ""
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP if show \
			else VERTICAL_ALIGNMENT_CENTER
		b.custom_minimum_size = sz
	for st: Dictionary in _stacks:
		_stack_show(st, String(st["current"]))
	if _tool_names_check != null:
		_tool_names_check.set_pressed_no_signal(show)
	request_ribbon_layout()


func set_show_tool_names(on: bool) -> void:
	ThemeService.show_tool_names = on
	ThemeService.save_settings()
	_apply_tool_labels()


## --- flyout stacks ------------------------------------------------------------

## One ribbon button fronting several related commands. `variants` entries:
## {id, title, icon, tooltip, handler}. The first is the face at start; a
## right-click or a long press lists them all, and the pick becomes the face
## (Fusion's Circle ▸ 3-Point Circle behaviour). Tool stacks pass the sketch
## ButtonGroup so the face toggles like any tool button.
func _tool_stack(parent: Control, variants: Array, group: ButtonGroup = null) -> Dictionary:
	var head: Dictionary = variants[0]
	var st := {"btn": null, "popup": null, "mark": null, "variants": variants,
		"current": head["id"]}
	var b := _tool_button(parent, String(head["title"]), Callable(),
		String(head["icon"]))
	b.name = _pascal(String(head["id"])) + "ToolBtn"
	b.tooltip_text = String(head.get("tooltip", head["title"])) \
		+ "\nRight-click or hold for more"
	if group != null:
		b.toggle_mode = true
		b.button_group = group
	b.pressed.connect(func() -> void:
		if _flyout_suppress:
			_flyout_suppress = false
			_refresh_ui()
			return
		for v: Dictionary in st["variants"]:
			if v["id"] == st["current"]:
				(v["handler"] as Callable).call())
	b.button_down.connect(func() -> void:
		_flyout_armed = st
		_flyout_timer.start())
	b.button_up.connect(func() -> void:
		if _flyout_armed == st:
			_flyout_timer.stop()
			_flyout_armed = {})
	b.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			b.accept_event()
			_open_flyout(st))
	st["btn"] = b
	# Corner mark: the little triangle that says "there is more in here".
	var mark := Control.new()
	mark.name = "StackMark"
	mark.set_anchors_preset(Control.PRESET_FULL_RECT)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.draw.connect(func() -> void:
		var s := mark.size
		var c := ThemeService.col("text_dim")
		mark.draw_colored_polygon(PackedVector2Array([
			Vector2(s.x - 3, s.y - 8), Vector2(s.x - 3, s.y - 3),
			Vector2(s.x - 8, s.y - 3)]), c))
	b.add_child(mark)
	st["mark"] = mark
	_stack_marks.append(mark)
	# The flyout: a popup listing every variant with icon + title.
	var popup := PopupPanel.new()
	popup.name = "Flyout"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	popup.add_child(col)
	for v: Dictionary in variants:
		var vb := Button.new()
		vb.name = _pascal(String(v["id"])) + ("VariantBtn" if v["id"] == head["id"]
			else "ToolBtn")
		vb.text = String(v["title"])
		vb.icon = ThemeService.icon(String(v["icon"]))
		vb.tooltip_text = String(v.get("tooltip", v["title"]))
		vb.theme_type_variation = "FlyoutButton"
		vb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		vb.focus_mode = Control.FOCUS_NONE
		vb.pressed.connect(func() -> void:
			popup.hide()
			_stack_show(st, String(v["id"]))
			(v["handler"] as Callable).call()
			_refresh_ui())
		col.add_child(vb)
		v["btn"] = vb
	b.add_child(popup)
	st["popup"] = popup
	_stacks.append(st)
	return st


## Make variant `id` the face of the stack.
func _stack_show(st: Dictionary, id: String) -> void:
	var b := st["btn"] as Button
	for v: Dictionary in st["variants"]:
		if v["id"] != id:
			continue
		st["current"] = id
		b.icon = ThemeService.icon(String(v["icon"]))
		b.tooltip_text = String(v.get("tooltip", v["title"])) \
			+ "\nRight-click or hold for more"
		if ThemeService.show_tool_names:
			b.text = String(v["title"])
		return


func _open_flyout(st: Dictionary) -> void:
	var b := st["btn"] as Button
	var popup := st["popup"] as PopupPanel
	popup.position = Vector2i(b.get_screen_position() + Vector2(0, b.size.y + 2))
	popup.popup()


func _on_flyout_timeout() -> void:
	if _flyout_armed.is_empty():
		return
	var st: Dictionary = _flyout_armed
	_flyout_armed = {}
	# The release that follows must not fire the face's command.
	_flyout_suppress = true
	_open_flyout(st)


## The stack (if any) whose variants include tool `tid`.
func _stack_for_tool(tid: String) -> Dictionary:
	for st: Dictionary in _stacks:
		for v: Dictionary in st["variants"]:
			if v["id"] == tid:
				return st
	return {}


func _divider(parent: Control) -> void:
	var wrap := MarginContainer.new()
	wrap.name = "Divider"
	wrap.add_theme_constant_override("margin_top", 8)
	wrap.add_theme_constant_override("margin_bottom", 12)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var d := Panel.new()
	d.theme_type_variation = "Divider"
	d.custom_minimum_size = Vector2(1, 0)
	d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(d)
	parent.add_child(wrap)


## A ribbon group: the button row (big buttons and small grids side by side)
## over an uppercase caption, like the design's CREATE › / MODIFY › labels.
## The panel is registered under `key` so _refresh_ui and tests can reach
## whole groups; `caption` defaults to the key.
func _shelf_group(parent: Control, key: String, caption := "") -> HBoxContainer:
	var panel := MarginContainer.new()
	panel.name = key + "Group"
	panel.add_theme_constant_override("margin_left", 10)
	panel.add_theme_constant_override("margin_right", 10)
	panel.add_theme_constant_override("margin_top", 0)
	panel.add_theme_constant_override("margin_bottom", 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 2)
	v.add_child(row)
	var cap := Label.new()
	cap.name = "Caption"
	cap.text = (caption if caption != "" else key).to_upper() + "  ›"
	cap.theme_type_variation = "CaptionLabel"
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(cap)
	parent.add_child(panel)
	_shelf_groups[key] = panel
	return row


func _tool_group_for(tid: String, g_select: Control, g_create: Control,
		g_modify: Control, g_dim: Control) -> Control:
	if tid == "select":
		return g_select
	if tid == "dimension":
		return g_dim
	if tid in ["trim", "extend", "offset", "mirror", "fillet", "chamfer",
			"rect_pattern", "circ_pattern", "project"]:
		return g_modify
	return g_create


## Raw Window dialogs clear to the engine's dark default rather than the
## theme (a plain Window paints no panel of its own). Slip a themed Panel
## under each one's content the moment it joins the tree — deferred, because
## the incoming node is still being set up inside this signal. Window
## SUBCLASSES (AcceptDialog/FileDialog alerts, PopupMenus) draw their own
## themed panel and must not get an opaque child shoved under their items.
func _on_child_entered(node: Node) -> void:
	if node != null and node.get_class() == "Window":
		_add_dialog_backdrop.call_deferred(node)


func _add_dialog_backdrop(win: Window) -> void:
	if not is_instance_valid(win) or win.has_node("ThemeBackdrop"):
		return
	var p := Panel.new()
	p.name = "ThemeBackdrop"
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(p)
	win.move_child(p, 0)


## --- theme + preferences (M26, file-driven themes M36) -----------------------

## Switch to a theme by id (a file stem under res://themes or user://themes).
## Returns the id that actually loaded (unknown ids fall back to the default).
func set_theme_id(id: String) -> String:
	var loaded := ThemeService.load_theme(id)
	ThemeService.save_settings()
	apply_theme()
	return loaded


## Convenience kept from M26: flip between the dark and light variant of the
## active theme family. A theme without a sibling variant falls back to the
## Modernist pair.
func set_dark_theme(on: bool) -> void:
	if ThemeService.dark == on:
		return
	var want := _sibling_theme(ThemeService.theme_id, on)
	set_theme_id(want)


## The dark/light twin of `id`: same stem with the "-dark"/"-light" suffix
## swapped when such a theme exists, else the Modernist default of that
## appearance.
func _sibling_theme(id: String, want_dark: bool) -> String:
	var ids := {}
	for t: Dictionary in ThemeService.available_themes():
		ids[t["id"]] = t["appearance"]
	var stem := id.trim_suffix("-dark").trim_suffix("-light")
	var cand := stem + ("-dark" if want_dark else "-light")
	if ids.has(cand):
		return cand
	return ThemeService.LEGACY_DARK if want_dark else ThemeService.LEGACY_LIGHT


## Push the current ThemeService tokens everywhere they are consumed.
func apply_theme() -> void:
	theme = ThemeService.build_theme()
	if world != null:
		world.apply_theme()
		world.rebuild_sketches(doc)
	if sketch_view != null:
		sketch_view.mark_dirty()
		sketch_view.queue_redraw()
	if overlay != null:
		overlay.queue_redraw()
	if view_cube != null:
		view_cube.apply_theme()
	if timeline != null:
		timeline.refresh()
	if browser != null:
		browser.refresh()
	_apply_theme_metrics()
	_sync_theme_pick()
	_rebuild_theme_menu()
	if _brand_mark != null:
		_brand_mark.color = ThemeService.col("accent")


## Controls whose footprint comes from theme metrics (ribbon button sizes,
## panel widths) re-read them here so a theme with a denser scale reflows.
func _apply_theme_metrics() -> void:
	_apply_tool_labels()
	for m in _stack_marks:
		if is_instance_valid(m):
			(m as Control).queue_redraw()
	if _ribbon != null:
		_ribbon.custom_minimum_size.y = ThemeService.metric("ribbon_height")
		_fit_ribbon_height.call_deferred()
	if _browser_panel != null:
		_browser_panel.custom_minimum_size.x = ThemeService.metric("browser_width")
	if _menu_panel != null:
		_menu_panel.custom_minimum_size.y = ThemeService.metric("menubar_height")
	if _timeline_panel != null:
		_timeline_panel.custom_minimum_size.y = ThemeService.metric("timeline_height")
	if _status_panel != null:
		_status_panel.custom_minimum_size.y = ThemeService.metric("status_height")


func _sync_theme_pick() -> void:
	if _theme_pick == null:
		return
	_theme_pick.clear()
	var sel := 0
	var i := 0
	for t: Dictionary in ThemeService.available_themes():
		var label := String(t["name"])
		if not bool(t["builtin"]):
			label += "  (user)"
		_theme_pick.add_item(label)
		_theme_pick.set_item_metadata(i, t["id"])
		if t["id"] == ThemeService.theme_id:
			sel = i
		i += 1
	_theme_pick.select(sel)


func _open_prefs_dialog() -> void:
	if _prefs_dialog == null:
		_prefs_dialog = Window.new()
		_prefs_dialog.name = "PrefsDialog"
		_prefs_dialog.title = "Preferences"
		_prefs_dialog.size = Vector2i(360, 220)
		_prefs_dialog.exclusive = false
		_prefs_dialog.close_requested.connect(
			func() -> void: _prefs_dialog.hide())
		var margin := MarginContainer.new()
		margin.set_anchors_preset(Control.PRESET_FULL_RECT)
		for side in ["left", "right", "top", "bottom"]:
			margin.add_theme_constant_override("margin_" + side, 12)
		_prefs_dialog.add_child(margin)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		margin.add_child(box)
		var row := HBoxContainer.new()
		box.add_child(row)
		var lab := Label.new()
		lab.text = "Theme"
		lab.custom_minimum_size.x = 64
		row.add_child(lab)
		_theme_pick = OptionButton.new()
		_theme_pick.name = "ThemePick"
		_theme_pick.focus_mode = Control.FOCUS_NONE
		_theme_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_theme_pick.item_selected.connect(func(i: int) -> void:
			set_theme_id(String(_theme_pick.get_item_metadata(i))))
		row.add_child(_theme_pick)
		var trow := HBoxContainer.new()
		box.add_child(trow)
		var spacer := Control.new()
		spacer.custom_minimum_size.x = 64
		trow.add_child(spacer)
		var openb := Button.new()
		openb.name = "OpenThemesBtn"
		openb.text = "Open themes folder"
		openb.tooltip_text = ("Drop a .json theme here (or copy one from the "
			+ "built-in themes/ folder to edit) — it appears in the list on Reload")
		openb.focus_mode = Control.FOCUS_NONE
		openb.pressed.connect(func() -> void:
			OS.shell_open(ThemeService.user_theme_dir()))
		trow.add_child(openb)
		var reloadb := Button.new()
		reloadb.name = "ReloadThemesBtn"
		reloadb.text = "Reload"
		reloadb.tooltip_text = "Rescan theme folders and re-apply the current theme"
		reloadb.focus_mode = Control.FOCUS_NONE
		reloadb.pressed.connect(func() -> void: set_theme_id(ThemeService.theme_id))
		trow.add_child(reloadb)
		var nrow := HBoxContainer.new()
		box.add_child(nrow)
		var nspacer := Control.new()
		nspacer.custom_minimum_size.x = 64
		nrow.add_child(nspacer)
		_tool_names_check = CheckBox.new()
		_tool_names_check.name = "ToolNamesChk"
		_tool_names_check.text = "Show tool names in the ribbon"
		_tool_names_check.focus_mode = Control.FOCUS_NONE
		_tool_names_check.button_pressed = ThemeService.show_tool_names
		_tool_names_check.toggled.connect(set_show_tool_names)
		nrow.add_child(_tool_names_check)
		var urow := HBoxContainer.new()
		box.add_child(urow)
		var ulab := Label.new()
		ulab.text = "Units"
		ulab.custom_minimum_size.x = 64
		urow.add_child(ulab)
		_unit_pick = OptionButton.new()
		_unit_pick.name = "UnitPick"
		_unit_pick.focus_mode = Control.FOCUS_NONE
		_unit_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_unit_pick.add_item("Millimeters", UnitConverter.Unit.MM)
		_unit_pick.add_item("Centimeters", UnitConverter.Unit.CM)
		_unit_pick.add_item("Inches", UnitConverter.Unit.IN)
		_unit_pick.add_item("Feet", UnitConverter.Unit.FT)
		_unit_pick.item_selected.connect(func(i: int) -> void:
			set_display_unit(_unit_pick.get_item_id(i) as UnitConverter.Unit))
		urow.add_child(_unit_pick)
		var okb := Button.new()
		okb.name = "PrefsCloseBtn"
		okb.text = "Close"
		okb.theme_type_variation = "PrimaryButton"
		okb.focus_mode = Control.FOCUS_NONE
		okb.size_flags_horizontal = Control.SIZE_SHRINK_END
		okb.pressed.connect(func() -> void: _prefs_dialog.hide())
		box.add_child(okb)
		add_child(_prefs_dialog)
	_sync_theme_pick()
	_unit_pick.select(_unit_pick.get_item_index(doc.display_unit))
	_prefs_dialog.popup_centered()


## --- viewing: projection, look-at, fit, named views, units (M27) -------------

func set_model_projection(ortho: bool) -> void:
	ThemeService.model_ortho = ortho
	ThemeService.save_settings()
	# Sketch mode owns its projection (always ortho; off-axis perspective) —
	# the preference lands when the camera is the model-mode one.
	if mode == Mode.MODEL:
		rig.set_projection_ortho(ortho)
	if _btn_ortho != null:
		_btn_ortho.set_pressed_no_signal(ortho)


func _apply_model_projection() -> void:
	rig.set_projection_ortho(ThemeService.model_ortho)
	if _btn_ortho != null:
		_btn_ortho.set_pressed_no_signal(ThemeService.model_ortho)


func _on_look_at_pressed() -> void:
	if mode != Mode.MODEL:
		return
	picking_look_at = true
	world.set_planes_visible(true)
	_refresh_ui()


## Square the camera onto a plane/face normal (Look At).
func look_at_normal(normal: Vector3, up_hint := Vector3(0, 0, 1)) -> void:
	rig.frame_view(normal, up_hint)


func fit_view() -> void:
	if mode != Mode.MODEL:
		return
	rig.fit_bounds(world.model_bounds())


func _plane_transform_for(key: String) -> Transform3D:
	if SketchFeature.PLANES.has(key):
		return Transform3D(SketchFeature.plane_basis(key), Vector3.ZERO)
	var pf := doc.plane_feature(key)
	return pf.transform() if pf != null else Transform3D.IDENTITY


## The Views dropdown: Home + the document's named views + "Save View".
const _VIEWS_ID_HOME := -1
const _VIEWS_ID_SAVE := -2

func _refresh_views_pick() -> void:
	if _views_pick == null:
		return
	_views_pick.clear()
	_views_pick.add_item("Views", -3)
	_views_pick.set_item_disabled(0, true)
	_views_pick.add_item("Home", _VIEWS_ID_HOME)
	for i in doc.named_views.size():
		_views_pick.add_item(String(doc.named_views[i].get("name", "View")), i)
	_views_pick.add_item("Save View", _VIEWS_ID_SAVE)
	_views_pick.select(0)


func _on_views_pick(index: int) -> void:
	var id := _views_pick.get_item_id(index)
	_views_pick.select(0)   # it acts as a menu, not a state holder
	if mode != Mode.MODEL:
		return
	if id == _VIEWS_ID_SAVE:
		save_named_view()
	elif id == _VIEWS_ID_HOME:
		go_home_view()
	elif id >= 0 and id < doc.named_views.size():
		apply_named_view(doc.named_views[id])


## Camera bookmarks live in the document (outside the command stack, like
## display_unit — they are viewport state that rides along in the file).
func save_named_view(view_name := "") -> Dictionary:
	var d := camera_dict()
	d["name"] = view_name if view_name != "" \
		else "View%d" % (doc.named_views.size() + 1)
	doc.named_views.append(d)
	_refresh_views_pick()
	set_status_hint("Saved %s" % d["name"])
	return d


func apply_named_view(d: Dictionary, animate := true) -> void:
	var t: Array = d.get("target", [0, 0, 0])
	rig.set_projection_ortho(bool(d.get("ortho", false)))
	if _btn_ortho != null:
		_btn_ortho.set_pressed_no_signal(rig.is_orthographic())
	rig.restore_view({"yaw": float(d.get("yaw", 0.0)),
		"pitch": float(d.get("pitch", 0.0)),
		"target": Vector3(float(t[0]), float(t[1]), float(t[2])),
		"distance": float(d.get("distance", 800.0))}, animate)


## The MODEL-mode camera as a plain dictionary (file-ready). Inside a sketch
## that is the view the user left behind, not the square-on sketch camera.
func camera_dict() -> Dictionary:
	var v := rig.capture_view()
	var ortho := rig.is_orthographic()
	if mode == Mode.SKETCH and not _model_view_before_sketch.is_empty():
		v = _model_view_before_sketch
		ortho = ThemeService.model_ortho
	return {"yaw": v["yaw"], "pitch": v["pitch"],
		"target": [v["target"].x, v["target"].y, v["target"].z],
		"distance": v["distance"], "ortho": ortho}


## Stash the current camera on the document so it rides along in the file
## (CHANGES #4). Called by every save path (UI + RPC) right before writing.
func stash_camera() -> void:
	doc.camera = camera_dict()


## Display unit (M27): UI-boundary only — model/solver/RPC stay mm. Reaches
## every formatter: grids, dimension labels, measure readout, dialogs.
func set_display_unit(u: UnitConverter.Unit) -> void:
	if doc.display_unit == u:
		return
	doc.display_unit = u
	world.set_grid_unit(u)
	sketch_view.grid_unit = u
	sketch_view.queue_redraw()
	overlay.queue_redraw()
	_update_measure_label()
	if _unit_pick != null:
		_unit_pick.select(_unit_pick.get_item_index(u))
	_refresh_ui()


func _update_measure_label() -> void:
	if _status_measure == null:
		return
	_status_measure.text = "" if mode != Mode.SKETCH \
		else Measure.describe(active_sketch(), selection, doc.display_unit)
	_update_ids_label()


## Identity slot: id / kind / index of what is selected — or, with nothing
## selected, of what the cursor is over. `_process` re-runs this every frame
## in sketch mode, because a hover change is reported by no signal; the
## string is rebuilt but `Label.set_text` early-outs when it is unchanged, so
## an idle cursor costs one compare and no relayout.
func _update_ids_label() -> void:
	if _status_ids == null:
		return
	var sk := active_sketch() if mode == Mode.SKETCH else null
	if sk == null:
		_status_ids.text = ""
		return
	var hov := ""
	if selection.is_empty():
		var t := tools.get_tool(tools.active_id())
		if t != null:
			hov = t.hover_id
	_status_ids.text = SelectionReadout.describe(sk, selection, hov,
			selected_constraint)


## --- reference images / canvases (M30) ---------------------------------------

## Insert an image file as a canvas feature. Plane defaults to the active
## sketch's plane (or XY in model mode). Returns the feature id or "".
func import_canvas(path: String, plane := "", width := 0.0) -> String:
	var cf := CanvasFeature.new()
	var err := cf.load_file(path)
	if err != "":
		set_status_hint("Canvas: " + err)
		return ""
	cf.id = doc.next_feature_id()
	cf.name = doc.auto_name("Canvas")
	if plane != "":
		if not SketchFeature.PLANES.has(plane) \
				and doc.plane_feature(plane) == null:
			set_status_hint("Canvas: no such plane %s" % plane)
			return ""
		cf.plane = plane
	elif mode == Mode.SKETCH:
		var sf := doc.sketch_feature(active_sketch_id)
		cf.plane = sf.plane if sf != null else "XY"
	if width > 0.0:
		cf.width_mm = width
	stack.push_no_merge(CmdAddFeature.new(cf))
	set_status_hint("%s inserted on %s (double-click its chip to edit)"
		% [cf.name, cf.plane_label()])
	return cf.id


func import_canvas_interactive() -> void:
	if _canvas_file_dialog == null:
		_canvas_file_dialog = FileDialog.new()
		_canvas_file_dialog.name = "CanvasFileDialog"
		_canvas_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_canvas_file_dialog.filters = ["*.png, *.jpg, *.jpeg ; Images"]
		_canvas_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_canvas_file_dialog.size = Vector2i(640, 440)
		_canvas_file_dialog.file_selected.connect(func(p: String) -> void:
			var fid := import_canvas(p)
			if fid != "":
				open_canvas_dialog(fid))
		add_child(_canvas_file_dialog)
	_canvas_file_dialog.popup_centered()


## Placement editor: center / width / rotation / opacity / lock. Numeric
## fields commit on Enter or Apply; every commit is one merged undo step.
func open_canvas_dialog(fid: String) -> void:
	var cf := doc.feature_by_id(fid) as CanvasFeature
	if cf == null:
		return
	_canvas_dialog_fid = fid
	if _canvas_dialog == null:
		_canvas_dialog = Window.new()
		_canvas_dialog.name = "CanvasDialog"
		_canvas_dialog.size = Vector2i(280, 230)
		_canvas_dialog.exclusive = false
		_canvas_dialog.close_requested.connect(
			func() -> void: _canvas_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_canvas_dialog.add_child(box)
		_canvas_fields = {}
		for def: Array in [["Center X", "cx"], ["Center Y", "cy"],
				["Width", "w"], ["Rotation °", "rot"], ["Opacity", "op"]]:
			var row := HBoxContainer.new()
			box.add_child(row)
			var lab := Label.new()
			lab.text = def[0]
			lab.custom_minimum_size = Vector2(80, 0)
			row.add_child(lab)
			var edit := LineEdit.new()
			edit.name = "Canvas" + String(def[1]).capitalize() + "Edit"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_submitted.connect(
				func(_t: String) -> void: _commit_canvas_dialog())
			row.add_child(edit)
			_canvas_fields[def[1]] = edit
		var lock := CheckBox.new()
		lock.name = "CanvasLockChk"
		lock.text = "Lock"
		lock.focus_mode = Control.FOCUS_NONE
		box.add_child(lock)
		_canvas_fields["lock"] = lock
		var brow := HBoxContainer.new()
		box.add_child(brow)
		var calb := Button.new()
		calb.name = "CanvasCalibrateBtn"
		calb.text = "Calibrate"
		calb.focus_mode = Control.FOCUS_NONE
		calb.pressed.connect(func() -> void:
			_canvas_dialog.hide()
			start_canvas_calibrate(_canvas_dialog_fid))
		brow.add_child(calb)
		var okb := Button.new()
		okb.name = "CanvasApplyBtn"
		okb.text = "Apply"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_canvas_dialog)
		brow.add_child(okb)
		add_child(_canvas_dialog)
	_canvas_dialog.title = cf.name
	var u := doc.display_unit
	(_canvas_fields["cx"] as LineEdit).text = UnitConverter.format(cf.center.x, u)
	(_canvas_fields["cy"] as LineEdit).text = UnitConverter.format(cf.center.y, u)
	(_canvas_fields["w"] as LineEdit).text = UnitConverter.format(cf.width_mm, u)
	(_canvas_fields["rot"] as LineEdit).text = "%.1f" % rad_to_deg(cf.rotation)
	(_canvas_fields["op"] as LineEdit).text = "%.2f" % cf.opacity
	(_canvas_fields["lock"] as CheckBox).set_pressed_no_signal(cf.locked)
	_canvas_dialog.popup_centered()


func _commit_canvas_dialog() -> void:
	var cf := doc.feature_by_id(_canvas_dialog_fid) as CanvasFeature
	if cf == null:
		return
	var u := doc.display_unit
	var props := {}
	var cx := UnitConverter.parse((_canvas_fields["cx"] as LineEdit).text, u)
	var cy := UnitConverter.parse((_canvas_fields["cy"] as LineEdit).text, u)
	if cx["ok"] and cy["ok"]:
		props["center"] = Vector2(float(cx["mm"]), float(cy["mm"]))
	var w := UnitConverter.parse((_canvas_fields["w"] as LineEdit).text, u)
	if w["ok"] and float(w["mm"]) > 0.0:
		props["width_mm"] = float(w["mm"])
	var rot_text := (_canvas_fields["rot"] as LineEdit).text
	if rot_text.is_valid_float():
		props["rotation"] = deg_to_rad(rot_text.to_float())
	var op_text := (_canvas_fields["op"] as LineEdit).text
	if op_text.is_valid_float():
		props["opacity"] = clampf(op_text.to_float(), 0.05, 1.0)
	props["locked"] = (_canvas_fields["lock"] as CheckBox).button_pressed
	stack.push_no_merge(CmdSetCanvasProps.new(_canvas_dialog_fid, props))
	_canvas_dialog.hide()


## Calibrate: two picks on the image + a real distance rescale the canvas
## about the FIRST pick (so the picked feature stays put).
func start_canvas_calibrate(fid: String) -> void:
	var cf := doc.feature_by_id(fid) as CanvasFeature
	if cf == null:
		return
	if mode != Mode.SKETCH:
		set_status_hint("Calibrate: open a sketch on %s first"
			% cf.plane_label())
		return
	picking_calibrate = true
	_calib_fid = fid
	_calib_picks = []
	set_status_hint("Calibrate: click two points a known distance apart "
		+ "(Esc to cancel)")


func _on_calibrate_pick(world_pos: Vector2) -> void:
	_calib_picks.append(world_pos)
	if _calib_picks.size() < 2:
		set_status_hint("Calibrate: click the second point")
		return
	picking_calibrate = false
	# Ask for the real distance.
	if _calib_dialog == null:
		_calib_dialog = Window.new()
		_calib_dialog.name = "CalibrateDialog"
		_calib_dialog.title = "Calibrate"
		_calib_dialog.size = Vector2i(240, 84)
		_calib_dialog.exclusive = false
		_calib_dialog.close_requested.connect(
			func() -> void: _calib_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_calib_dialog.add_child(box)
		_calib_dist = LineEdit.new()
		_calib_dist.name = "CalibrateDistEdit"
		_calib_dist.placeholder_text = "Real distance (e.g. 2.5in)"
		box.add_child(_calib_dist)
		var okb := Button.new()
		okb.name = "CalibrateOkBtn"
		okb.text = "OK"
		okb.pressed.connect(_commit_calibrate)
		box.add_child(okb)
		_calib_dist.text_submitted.connect(
			func(_t: String) -> void: _commit_calibrate())
		add_child(_calib_dialog)
	_calib_dist.text = ""
	_calib_dialog.popup_centered()
	_calib_dist.grab_focus()


func _commit_calibrate() -> void:
	var r := UnitConverter.parse(_calib_dist.text, doc.display_unit)
	if not r["ok"] or float(r["mm"]) <= 0.0:
		set_status_hint("Calibrate: enter the real distance")
		return
	_calib_dialog.hide()
	apply_canvas_calibration(_calib_fid, _calib_picks[0], _calib_picks[1],
		float(r["mm"]))


## Pure calibration math + command push (shared with RPC): scale the canvas
## so |a-b| measures `real_mm`, holding `a` fixed on the plane.
func apply_canvas_calibration(fid: String, a: Vector2, b: Vector2,
		real_mm: float) -> String:
	var cf := doc.feature_by_id(fid) as CanvasFeature
	if cf == null:
		return "no such canvas"
	var picked := a.distance_to(b)
	if picked < 1e-6 or real_mm <= 0.0:
		return "degenerate calibration"
	var s := real_mm / picked
	stack.push_no_merge(CmdSetCanvasProps.new(fid, {
		"width_mm": cf.width_mm * s,
		"center": a + (cf.center - a) * s,
	}))
	set_status_hint("Calibrated %s (×%.4f)" % [cf.name, s])
	return ""


## Browser eye for canvases (M30).
func set_canvas_shown(fid: String, shown: bool) -> void:
	world.set_canvas_shown(fid, shown)
	sketch_view.queue_redraw()


## Body properties popup (M27): volume + bounding box, in the display unit.
func show_body_properties(body_id: String) -> void:
	var bodies: Array = await BodyBuilder.build(doc, self)
	for b: Dictionary in bodies:
		if String(b["id"]) != body_id:
			continue
		var mesh: ArrayMesh = b["mesh"]
		var box := mesh.get_aabb()
		var u := doc.display_unit
		var per := UnitConverter.to_mm(1.0, u)
		var dlg := AcceptDialog.new()
		dlg.name = "BodyPropsDialog"
		dlg.title = String(b["name"])
		dlg.dialog_text = "Volume: %.3f %s³\nSize: %s × %s × %s" % [
			BodyBuilder.mesh_volume(mesh) / (per * per * per),
			UnitConverter.unit_to_string(u),
			UnitConverter.format(box.size.x, u),
			UnitConverter.format(box.size.y, u),
			UnitConverter.format(box.size.z, u)]
		add_child(dlg)
		dlg.close_requested.connect(dlg.queue_free)
		dlg.confirmed.connect(dlg.queue_free)
		dlg.popup_centered()
		return
	set_status_hint("No such body")


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
	picking_offset_base = false
	world.clear_face_hover()
	world.set_plane_hover("")
	mode = Mode.SKETCH
	sketch_orbit = false
	timeline.refresh()   # the active sketch's chip lights up (M36)
	sketch_view.grid_unit = doc.display_unit
	# Carry the 3D framing into the sketch (CHANGES #3): the canvas opens
	# centred on where the camera was looking, at the zoom the model view
	# had, instead of snapping to origin @ 4 px/mm every time.
	var xf := feat.plane_transform()
	var entry := _sketch_entry_view(xf)
	sketch_view.set_view(entry["pan"], entry["zoom"])
	sketch_view.show_sketch(feat.sketch, reference_sketches())
	# Fly the 3D camera square onto the plane FIRST, then swap in the 2D
	# canvas. Showing it up front would paint over the animation, which is
	# what made the transition read as an instant snap.
	# The grid moves onto the plane being drawn on, so the 3D scene behind the
	# canvas agrees with it — and so it is already right for the fly-in.
	world.set_grid_plane(feat.plane, xf)
	world.set_grid_unit(doc.display_unit)
	var pan: Vector2 = entry["pan"]
	rig.frame_view(xf.basis.z, xf.basis.y, xf * Vector3(pan.x, pan.y, 0.0),
		entry["distance"])
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


## Where the canvas should open so the sketch matches the 3D view the user
## was just in: pan = the camera target dropped onto the plane, zoom = the
## px/mm the model view showed, distance = the eye standoff that keeps that
## height under the current projection. Falls back to origin @ 4 px/mm when
## the viewport has no size yet (headless before the first frame).
func _sketch_entry_view(xf: Transform3D) -> Dictionary:
	var local := xf.affine_inverse() * rig.target
	var pan := Vector2(local.x, local.y)
	var vh_mm := rig.view_height_mm()
	var vp_h := float(_viewport.size.y) if _viewport != null else 0.0
	var zoom := 4.0
	if vp_h > 0.0 and vh_mm > 0.0:
		zoom = vp_h / vh_mm
	var dist := rig.distance
	if not rig.is_orthographic():
		dist = rig.distance_for_height(vh_mm)
	return {"pan": pan, "zoom": zoom, "distance": dist}


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
	timeline.refresh()
	sketch_view.clear_projection_3d()
	rig.end_orbit()
	# Drop the 2D canvas immediately so the 3D scene is what animates: the
	# camera pulls back from the plane to the previous model view.
	sketch_view.visible = false
	world.set_planes_visible(false)
	# Model mode is a 3D space again: back to the user's chosen projection
	# (M27). (Sketch mode runs orthographic — see `_sync_camera_to_sketch_view`.)
	_apply_model_projection()
	# Back to the ground plane: the grid is XY whenever no sketch is open.
	world.set_grid_plane("XY")
	world.rebuild_sketches(doc)
	if _model_view_before_sketch.is_empty():
		rig.frame_home()
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
	# Coplanarity is judged on the RESOLVED transforms (M22): two different
	# plane refs can land on the same plane (a face plane over an offset
	# plane), and reference rendering reuses the sketch's own uv mapping, so
	# the whole transform must match — not just the plane.
	var my_xf := feat.plane_transform()
	for f in doc.live_features():
		var sf := f as SketchFeature
		if sf == null or sf.id == feat.id \
				or not sf.plane_transform().is_equal_approx(my_xf):
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
	picking_offset_base = false
	world.clear_profile_hover()
	# Planes stay out of sight until there is a reason to aim at one.
	world.set_planes_visible(true)
	_refresh_ui()


func _on_extrude_pressed() -> void:
	picking_profile = true
	picking_plane = false
	picking_offset_base = false
	picking_revolve = false
	picking_revolve_axis = false
	world.clear_face_hover()
	world.clear_axis_hover()
	world.hide_axis_candidates()
	_refresh_ui()


## "Revolve" (M23): pick a region, then an axis line, then the dialog.
func _on_revolve_pressed() -> void:
	picking_revolve = true
	picking_revolve_axis = false
	picking_profile = false
	picking_plane = false
	picking_offset_base = false
	_pending_revolve = {}
	world.clear_face_hover()
	world.clear_profile_hover()
	world.clear_axis_hover()
	world.hide_axis_candidates()
	_refresh_ui()


## "Offset Plane" (M22): pick the base plane, then type the distance.
func _on_offset_plane_pressed() -> void:
	picking_offset_base = true
	picking_plane = false
	picking_profile = false
	world.clear_profile_hover()
	world.clear_face_hover()
	world.set_planes_visible(true)
	_refresh_ui()


## Create a revolve feature (M23, undoable). `axis` is "x"/"y" or a line
## entity id in the sketch. "" when the region or axis is invalid (missing,
## or the region straddles the axis).
func revolve(sketch_id: String, at: Vector2, axis: String, angle: float,
		operation := SolidFeature.OP_NEW_BODY) -> String:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return ""
	var f := RevolveFeature.make(sketch_id, at, axis, angle, operation)
	# Dry-run the mesher against the current sketch: it returns null for a
	# missing region/axis or a straddling profile, which we refuse up front
	# rather than committing a feature that builds nothing.
	if f.build_mesh(doc) == null:
		return ""
	f.name = doc.auto_name("Revolve")
	f.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(f))
	if operation == SolidFeature.OP_CUT:
		set_status_hint("Cut revolve: carves its solid out of the bodies "
			+ "it touches.")
	return f.id


## Create an extrude feature from a profile hit (undoable). Returns the
## feature id or "" when no profile encloses `at`. `operation` is the
## boolean role (M18): new_body / join / cut.
func extrude(sketch_id: String, at: Vector2, dist: float,
		operation := ExtrudeFeature.OP_NEW_BODY) -> String:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return ""
	if ProfileFinder.profile_at(sf.sketch, at).is_empty():
		return ""
	var f := ExtrudeFeature.make(sketch_id, at, dist, operation)
	f.name = doc.auto_name("Extrude")
	f.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(f))
	if operation == ExtrudeFeature.OP_CUT:
		set_status_hint("Cut extrude: carves its prism out of the bodies "
			+ "it touches.")
	return f.id


## Ray -> (sketch feature, uv on its plane) for the sketch whose profile the
## ray hits NEAREST; a tie (coplanar sketches) goes to the LATEST sketch.
## {} when none. The old timeline-order scan returned the FIRST sketch
## containing the hit, so clicking a fresh profile drawn over an older sketch
## silently picked the older sketch's region — QA §M18.3's "cut" that erased
## the whole plate was cutting the plate's own outer profile.
func _profile_under_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for f in doc.live_features():
		if not (f is SketchFeature):
			continue
		var sf := f as SketchFeature
		var xf := sf.plane_transform()
		var n: Vector3 = xf.basis.z
		var denom := dir.dot(n)
		if absf(denom) < 1e-9:
			continue
		# Plane through xf.origin, not the world origin (offset planes, M22).
		var t := (xf.origin - origin).dot(n) / denom
		if t <= 0.0 or t > best_t + 1e-6:
			continue
		var local := xf.affine_inverse() * (origin + dir * t)
		var uv := Vector2(local.x, local.y)
		if ProfileFinder.profile_at(sf.sketch, uv).is_empty():
			continue
		best = {"sketch_id": sf.id, "at": uv}
		best_t = minf(best_t, t)
	return best


func _open_extrude_dialog() -> void:
	if _extrude_dialog == null:
		_extrude_dialog = Window.new()
		_extrude_dialog.name = "ExtrudeDialog"
		_extrude_dialog.title = "Extrude"
		_extrude_dialog.size = Vector2i(220, 118)
		_extrude_dialog.exclusive = false
		_extrude_dialog.close_requested.connect(
			func() -> void:
				_extrude_dialog.hide()
				world.clear_profile_hover())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_extrude_dialog.add_child(box)
		_extrude_dist = LineEdit.new()
		_extrude_dist.name = "ExtrudeDistEdit"
		_extrude_dist.placeholder_text = "Distance (e.g. 0.5in)"
		box.add_child(_extrude_dist)
		_extrude_op = OptionButton.new()
		_extrude_op.name = "ExtrudeOpPick"
		_extrude_op.add_item("New Body", 0)
		_extrude_op.add_item("Join", 1)
		_extrude_op.add_item("Cut", 2)
		_extrude_op.focus_mode = Control.FOCUS_NONE
		box.add_child(_extrude_op)
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
	world.clear_profile_hover()
	if not _pending_extrude.is_empty():
		var ops := [ExtrudeFeature.OP_NEW_BODY, ExtrudeFeature.OP_JOIN,
			ExtrudeFeature.OP_CUT]
		extrude(_pending_extrude["sketch_id"], _pending_extrude["at"],
			float(r["mm"]), ops[_extrude_op.selected])
	_pending_extrude = {}


func _on_finish_sketch() -> void:
	finish_sketch()


## --- revolve (M23) -------------------------------------------------------------

## The axis-pick ray: nearest candidate of the pending revolve's sketch
## within a screen-ish tolerance — a LINE entity, or one of the sketch's own
## u/v axes (drawn by show_axis_candidates while the pick is armed).
## -> {"axis": String ("x"/"y"/entity id), "a": Vector2, "b": Vector2} in
## sketch uv, {} on a miss.
func _axis_pick_under_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	var sf := doc.sketch_feature(String(_pending_revolve.get("sketch_id", "")))
	if sf == null:
		return {}
	var xf := sf.plane_transform()
	var n: Vector3 = xf.basis.z
	var denom := dir.dot(n)
	if absf(denom) < 1e-9:
		return {}
	var t := (xf.origin - origin).dot(n) / denom
	if t <= 0.0:
		return {}
	var local := xf.affine_inverse() * (origin + dir * t)
	var uv := Vector2(local.x, local.y)
	# ~8 px worth of world millimetres at the current model-view zoom.
	var tol := rig.view_height_mm() * 8.0 / maxf(float(_viewport.size.y), 1.0)
	var best := {}
	var best_d := tol
	for e in sf.sketch.entities():
		if e.kind() != "line":
			continue
		var l := e as SketchLine
		var p0 := sf.sketch.point(l.p0)
		var p1 := sf.sketch.point(l.p1)
		if p0 == null or p1 == null:
			continue
		var dd := Geometry2D.get_closest_point_to_segment(
			uv, p0.pos, p1.pos).distance_to(uv)
		if dd < best_d:
			best_d = dd
			best = {"axis": e.id, "a": p0.pos, "b": p1.pos}
	# The sketch axes, as drawn in the viewport (QA §M23.1: keyboard-only
	# axis choice). Entity lines win ties — they sit above the axes visually.
	var axl := CadWorld.AXIS_LEN
	for cand: Array in [
			["x", Vector2(-axl, 0), Vector2(axl, 0)],
			["y", Vector2(0, -axl), Vector2(0, axl)]]:
		var dd2 := Geometry2D.get_closest_point_to_segment(
			uv, cand[1] as Vector2, cand[2] as Vector2).distance_to(uv)
		if dd2 < best_d:
			best_d = dd2
			best = {"axis": cand[0], "a": cand[1], "b": cand[2]}
	return best


## Width (mm) of the axis hover band: ~4 px at the current model-view zoom.
func _axis_hover_width_mm() -> float:
	return rig.view_height_mm() * 4.0 / maxf(float(_viewport.size.y), 1.0)


func _open_revolve_dialog() -> void:
	if _revolve_dialog == null:
		_revolve_dialog = Window.new()
		_revolve_dialog.name = "RevolveDialog"
		_revolve_dialog.title = "Revolve"
		_revolve_dialog.size = Vector2i(220, 118)
		_revolve_dialog.exclusive = false
		_revolve_dialog.close_requested.connect(
			func() -> void:
				_revolve_dialog.hide()
				world.clear_profile_hover())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_revolve_dialog.add_child(box)
		_revolve_angle = LineEdit.new()
		_revolve_angle.name = "RevolveAngleEdit"
		_revolve_angle.placeholder_text = "Angle (deg, default 360)"
		box.add_child(_revolve_angle)
		_revolve_op = OptionButton.new()
		_revolve_op.name = "RevolveOpPick"
		_revolve_op.add_item("New Body", 0)
		_revolve_op.add_item("Join", 1)
		_revolve_op.add_item("Cut", 2)
		_revolve_op.focus_mode = Control.FOCUS_NONE
		box.add_child(_revolve_op)
		var okb := Button.new()
		okb.name = "RevolveOkBtn"
		okb.text = "OK"
		okb.pressed.connect(_commit_revolve)
		box.add_child(okb)
		_revolve_angle.text_submitted.connect(
			func(_t: String) -> void: _commit_revolve())
		add_child(_revolve_dialog)
	_revolve_angle.text = ""
	_revolve_dialog.popup_centered()
	_revolve_angle.grab_focus()


func _commit_revolve() -> void:
	var txt := _revolve_angle.text.strip_edges()
	var ang := 360.0
	if txt != "":
		if not txt.is_valid_float():
			_status_hint.text = "Revolve: angle must be a number of degrees"
			return
		ang = txt.to_float()
	if ang <= 0.0 or ang > 360.0:
		_status_hint.text = "Revolve: angle must be in (0, 360]"
		return
	_revolve_dialog.hide()
	world.clear_profile_hover()
	if not _pending_revolve.is_empty():
		var ops := [SolidFeature.OP_NEW_BODY, SolidFeature.OP_JOIN,
			SolidFeature.OP_CUT]
		var rid := revolve(_pending_revolve["sketch_id"], _pending_revolve["at"],
			_revolve_axis, ang, ops[_revolve_op.selected])
		if rid == "":
			set_status_hint("Revolve refused: the region must lie entirely on "
				+ "one side of the axis")
	_pending_revolve = {}
	_revolve_axis = ""


## --- construction planes (M22) -------------------------------------------------

## Create an offset construction plane (undoable). `base` is an origin-plane
## name or an existing plane feature id; offset in mm. "" when base is bad.
func create_offset_plane(base: String, offset_mm: float) -> String:
	if not SketchFeature.PLANES.has(base) and doc.plane_feature(base) == null:
		return ""
	var pf := PlaneFeature.make_offset(base, offset_mm)
	pf.name = doc.auto_name("Plane")
	pf.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(pf))
	return pf.id


## Face pick while creating a sketch: mint a CUSTOM plane on the face and the
## sketch on it, as ONE undo step.
func create_sketch_on_face(point: Vector3, normal: Vector3) -> String:
	var pf := PlaneFeature.make_custom(PlaneFeature.face_transform(point, normal))
	pf.name = doc.auto_name("Plane")
	pf.id = doc.next_feature_id()
	var sf := SketchFeature.make(doc.auto_name("Sketch"), pf.id)
	sf.id = doc.next_feature_id()
	stack.push_no_merge(CmdBatch.new("Sketch on Face",
		[CmdAddFeature.new(pf), CmdAddFeature.new(sf)]))
	edit_sketch(sf.id)
	return sf.id


## Open the offset editor for an existing plane (browser/timeline
## double-click). Custom (face) planes have no offset to edit.
func edit_plane_offset(fid: String) -> void:
	var pf := doc.plane_feature(fid)
	if pf == null:
		return
	if pf.plane_kind != PlaneFeature.KIND_OFFSET:
		set_status_hint("%s is a face plane — it has no offset to edit" % pf.name)
		return
	_open_plane_dialog(pf.base, fid)


## Is this plane feature still referenced (by a sketch on it, or as another
## plane's base)? Referenced planes refuse deletion, like referenced
## parameters — the sketch would silently fall to XY otherwise.
func plane_referenced(fid: String) -> bool:
	for f in doc.features:
		if f is SketchFeature and (f as SketchFeature).plane == fid:
			return true
		if f is PlaneFeature and (f as PlaneFeature).base == fid:
			return true
	return false


## Feature deletion with the plane guard — the timeline menu routes here.
func request_delete_feature(fid: String) -> void:
	var f := doc.feature_by_id(fid)
	if f is PlaneFeature and plane_referenced(fid):
		set_status_hint("Cannot delete %s: a sketch or plane still uses it"
			% f.name)
		return
	stack.push_no_merge(CmdDeleteFeature.new(fid))


func _open_plane_dialog(base: String, edit_fid: String) -> void:
	_plane_dialog_base = base
	_plane_dialog_edit = edit_fid
	if _plane_dialog == null:
		_plane_dialog = Window.new()
		_plane_dialog.name = "PlaneDialog"
		_plane_dialog.size = Vector2i(240, 84)
		_plane_dialog.exclusive = false
		_plane_dialog.close_requested.connect(
			func() -> void: _plane_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_plane_dialog.add_child(box)
		_plane_dist = LineEdit.new()
		_plane_dist.name = "PlaneOffsetEdit"
		_plane_dist.placeholder_text = "Offset (e.g. 0.5in)"
		box.add_child(_plane_dist)
		var okb := Button.new()
		okb.name = "PlaneOkBtn"
		okb.text = "OK"
		okb.pressed.connect(_commit_plane_dialog)
		box.add_child(okb)
		_plane_dist.text_submitted.connect(
			func(_t: String) -> void: _commit_plane_dialog())
		add_child(_plane_dialog)
	if edit_fid == "":
		_plane_dialog.title = "Offset Plane from %s" % doc.plane_label(base)
		_plane_dist.text = ""
	else:
		var pf := doc.plane_feature(edit_fid)
		_plane_dialog.title = "Edit %s" % (pf.name if pf != null else "plane")
		_plane_dist.text = UnitConverter.format(pf.offset, doc.display_unit) \
			if pf != null else ""
	_plane_dialog.popup_centered()
	_plane_dist.grab_focus()


func _commit_plane_dialog() -> void:
	var r := UnitConverter.parse(_plane_dist.text, doc.display_unit)
	if not r["ok"]:
		_status_hint.text = "Offset plane: enter a distance"
		return
	_plane_dialog.hide()
	if _plane_dialog_edit != "":
		stack.push_no_merge(CmdSetPlaneOffset.new(_plane_dialog_edit,
			float(r["mm"])))
	else:
		create_offset_plane(_plane_dialog_base, float(r["mm"]))
	_plane_dialog_base = ""
	_plane_dialog_edit = ""


## --- Parameters dialog (M20) ---------------------------------------------------

func _open_params_dialog() -> void:
	if _params_dialog == null:
		_params_dialog = Window.new()
		_params_dialog.name = "ParametersDialog"
		_params_dialog.title = "Parameters"
		_params_dialog.size = Vector2i(420, 320)
		_params_dialog.exclusive = false
		_params_dialog.close_requested.connect(
			func() -> void: _params_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_params_dialog.add_child(box)
		_params_tree = Tree.new()
		_params_tree.name = "ParamsTree"
		_params_tree.columns = 3
		_params_tree.set_column_title(0, "Name")
		_params_tree.set_column_title(1, "Expression")
		_params_tree.set_column_title(2, "Value")
		_params_tree.column_titles_visible = true
		_params_tree.hide_root = true
		_params_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_params_tree.item_selected.connect(_on_param_row_selected)
		box.add_child(_params_tree)
		var row := HBoxContainer.new()
		box.add_child(row)
		_param_name = LineEdit.new()
		_param_name.name = "ParamNameEdit"
		_param_name.placeholder_text = "name"
		_param_name.custom_minimum_size.x = 90
		row.add_child(_param_name)
		_param_expr = LineEdit.new()
		_param_expr.name = "ParamExprEdit"
		_param_expr.placeholder_text = "expression (e.g. width/2 + 0.25)"
		_param_expr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_param_expr)
		_param_unit = OptionButton.new()
		_param_unit.name = "ParamUnitPick"
		_param_unit.focus_mode = Control.FOCUS_NONE
		_param_unit.add_item("in", 0)
		_param_unit.add_item("mm", 1)
		_param_unit.add_item("scalar", 2)
		row.add_child(_param_unit)
		var setb := Button.new()
		setb.name = "ParamSetBtn"
		setb.text = "Set"
		setb.focus_mode = Control.FOCUS_NONE
		setb.pressed.connect(_commit_param)
		row.add_child(setb)
		var delb := Button.new()
		delb.name = "ParamDeleteBtn"
		delb.text = "Delete"
		delb.focus_mode = Control.FOCUS_NONE
		delb.pressed.connect(_delete_param)
		row.add_child(delb)
		_param_expr.text_submitted.connect(
			func(_t: String) -> void: _commit_param())
		_param_err = Label.new()
		_param_err.name = "ParamErrLabel"
		_param_err.add_theme_color_override("font_color", Color(0.9, 0.5, 0.4))
		box.add_child(_param_err)
		add_child(_params_dialog)
		# Parameter edits land on the undo stack; keep the table current.
		stack.changed.connect(func() -> void:
			if _params_dialog.visible:
				_refresh_params_tree())
	_param_err.text = ""
	_refresh_params_tree()
	_params_dialog.popup_centered()


func _refresh_params_tree() -> void:
	_params_tree.clear()
	var root := _params_tree.create_item()
	for prm in doc.parameters:
		var item := _params_tree.create_item(root)
		item.set_text(0, prm.name)
		item.set_text(1, prm.expr)
		if prm.unit == CadParameter.UNIT_SCALAR:
			item.set_text(2, String.num(prm.value, 4))
		else:
			item.set_text(2, "%s %s" % [
				String.num(UnitConverter.from_mm(prm.value, prm.unit), 4),
				UnitConverter.suffix(prm.unit)])


func _on_param_row_selected() -> void:
	var item := _params_tree.get_selected()
	if item == null:
		return
	_param_name.text = item.get_text(0)
	_param_expr.text = item.get_text(1)
	for prm in doc.parameters:
		if prm.name == item.get_text(0):
			_param_unit.selected = 2 if prm.unit == CadParameter.UNIT_SCALAR \
				else (1 if prm.unit == UnitConverter.Unit.MM else 0)


func _commit_param() -> void:
	var units: Array = [UnitConverter.Unit.IN, UnitConverter.Unit.MM,
		CadParameter.UNIT_SCALAR]
	var why := upsert_parameter(_param_name.text.strip_edges(),
		_param_expr.text.strip_edges(), units[_param_unit.selected])
	_param_err.text = why
	if why == "":
		_refresh_params_tree()


func _delete_param() -> void:
	var why := remove_parameter(_param_name.text.strip_edges())
	_param_err.text = why
	if why == "":
		_param_name.text = ""
		_param_expr.text = ""
		_refresh_params_tree()


## --- save / open ---------------------------------------------------------------

## Write the document to `path` (.ecad). Returns true on success.
func save_to(path: String) -> bool:
	if not path.to_lower().ends_with(".ecad"):
		path += ".ecad"
	stash_camera()
	if not Serializer.save(doc, path):
		set_status_hint("Save failed: " + path)
		return false
	_save_path = path
	stack.mark_saved()
	browser.refresh()   # root component row carries the file name
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
	browser.refresh()
	set_status_hint("Opened " + path)
	return true


## --- DXF import (M25) ----------------------------------------------------------

var _dxf_import_dialog: FileDialog
var _dxf_import_plane: OptionButton = null


## Import a DXF file as a NEW sketch on `plane` (an origin-plane name or a
## construction plane id). One undo step — the sketch is built complete and
## then added with a single CmdAddFeature. Returns the feature id, "" on
## failure (status bar says why).
func import_dxf(path: String, plane := "XY") -> String:
	if not SketchFeature.PLANES.has(plane) and doc.plane_feature(plane) == null:
		set_status_hint("Import DXF: unknown plane %s" % plane)
		return ""
	if not FileAccess.file_exists(path):
		set_status_hint("Import DXF: no such file: " + path)
		return ""
	var parsed := DxfImporter.parse(FileAccess.get_file_as_string(path))
	if not bool(parsed["ok"]):
		set_status_hint("Import DXF failed: " + String(parsed["error"]))
		return ""
	var sf := SketchFeature.make(doc.auto_name("Sketch"), plane)
	sf.id = doc.next_feature_id()
	var census := DxfImporter.populate(sf.sketch, parsed["ents"] as Array)
	stack.push_no_merge(CmdAddFeature.new(sf))
	var msg := "Imported %d lines, %d arcs, %d circles, %d points into %s" \
		% [census["lines"], census["arcs"], census["circles"],
		census["points"], sf.name]
	if int(parsed["skipped"]) > 0:
		msg += " (%d unsupported entities skipped)" % int(parsed["skipped"])
	set_status_hint(msg)
	return sf.id


func import_dxf_interactive() -> void:
	if _dxf_import_dialog == null:
		_dxf_import_dialog = FileDialog.new()
		_dxf_import_dialog.name = "DxfImportDialog"
		_dxf_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dxf_import_dialog.filters = ["*.dxf ; DXF drawings"]
		_dxf_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dxf_import_dialog.size = Vector2i(640, 440)
		_dxf_import_dialog.file_selected.connect(
			func(path: String) -> void:
				import_dxf(path, String(_dxf_import_plane.get_item_metadata(
					_dxf_import_plane.selected))))
		# Target plane rides inside the file dialog (QA §M25.1): DXF is a 2D
		# format, so the sketch's plane is the importer's to choose — it used
		# to land on XY unconditionally.
		var prow := HBoxContainer.new()
		var plab := Label.new()
		plab.text = "Sketch plane:"
		prow.add_child(plab)
		_dxf_import_plane = OptionButton.new()
		_dxf_import_plane.name = "DxfImportPlanePick"
		_dxf_import_plane.focus_mode = Control.FOCUS_NONE
		prow.add_child(_dxf_import_plane)
		_dxf_import_dialog.get_vbox().add_child(prow)
		add_child(_dxf_import_dialog)
	# Re-list the planes every open: construction planes come and go.
	var prev := ""
	if _dxf_import_plane.selected >= 0:
		prev = String(_dxf_import_plane.get_item_metadata(
			_dxf_import_plane.selected))
	_dxf_import_plane.clear()
	for plane_name: String in SketchFeature.PLANES:
		_dxf_import_plane.add_item(plane_name)
		_dxf_import_plane.set_item_metadata(
			_dxf_import_plane.item_count - 1, plane_name)
	for f in doc.live_features():
		if f is PlaneFeature:
			_dxf_import_plane.add_item((f as PlaneFeature).name)
			_dxf_import_plane.set_item_metadata(
				_dxf_import_plane.item_count - 1, f.id)
	_dxf_import_plane.selected = 0
	for i in _dxf_import_plane.item_count:
		if String(_dxf_import_plane.get_item_metadata(i)) == prev:
			_dxf_import_plane.selected = i
			break
	_dxf_import_dialog.popup_centered()


## --- 3D fillet / chamfer (M35) -----------------------------------------------
## Fusion-style edge selection (QA §M35.1): the shelf button arms a pick —
## every treatable edge of the selected body draws in the viewport, hover
## highlights, clicks toggle (rims toggle as a loop), a small dialog holds
## the size, Apply commits. Editing an existing treatment (timeline
## double-click) edits its size; the edge set stays as picked.

var _treat_dialog: Window = null
var _treat_fields := {}
var _treat_edit_fid := ""
var _treat_body := ""
var _treat_kind := EdgeTreatFeature.KIND_FILLET
var picking_treat_edges := false
var _treat_pick_edges: Array = []      # EdgeTreatFeature.pickable_edges
var _treat_selected := {}              # edge key -> true


func open_edge_treat_dialog(edit_fid: String, p_kind := "") -> void:
	var et := doc.feature_by_id(edit_fid) as EdgeTreatFeature
	if et == null:
		_start_edge_treat_pick(p_kind)
		return
	_treat_edit_fid = edit_fid
	_treat_kind = et.treat
	if _treat_dialog == null:
		_treat_dialog = Window.new()
		_treat_dialog.name = "EdgeTreatDialog"
		_treat_dialog.size = Vector2i(280, 130)
		_treat_dialog.exclusive = false
		_treat_dialog.close_requested.connect(
			func() -> void: _treat_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_treat_dialog.add_child(box)
		_treat_fields = {}
		var row := HBoxContainer.new()
		box.add_child(row)
		var lab := Label.new()
		lab.text = "Size"
		lab.custom_minimum_size = Vector2(60, 0)
		row.add_child(lab)
		var edit := LineEdit.new()
		edit.name = "TreatSizeEdit"
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.text_submitted.connect(
			func(_t: String) -> void: _commit_edge_treat())
		row.add_child(edit)
		_treat_fields["size"] = edit
		var desc := Label.new()
		desc.name = "TreatEdgesLabel"
		box.add_child(desc)
		_treat_fields["desc"] = desc
		var okb := Button.new()
		okb.name = "TreatOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_edge_treat)
		box.add_child(okb)
		add_child(_treat_dialog)
	_treat_dialog.title = "Fillet Edges" \
		if _treat_kind == EdgeTreatFeature.KIND_FILLET else "Chamfer Edges"
	(_treat_fields["size"] as LineEdit).text = \
		UnitConverter.format(et.size_mm, doc.display_unit)
	(_treat_fields["desc"] as Label).text = _describe_treat_edges(et)
	_treat_dialog.popup_centered()


static func _describe_treat_edges(et: EdgeTreatFeature) -> String:
	var bits: PackedStringArray = []
	if et.lateral:
		bits.append("all side corners" if et.corners.is_empty()
			else "%d side corner%s" % [et.corners.size(),
				"" if et.corners.size() == 1 else "s"])
	if et.top:
		bits.append("top rim" if et.top_segs.is_empty()
			else "%d top edge%s" % [et.top_segs.size(),
				"" if et.top_segs.size() == 1 else "s"])
	if et.bottom:
		bits.append("bottom rim" if et.bottom_segs.is_empty()
			else "%d bottom edge%s" % [et.bottom_segs.size(),
				"" if et.bottom_segs.size() == 1 else "s"])
	return "Edges: " + ", ".join(bits)


## Edit commit: the size is the parametric knob; the picked edge set rides
## the feature unchanged.
func _commit_edge_treat() -> void:
	var r := UnitConverter.parse((_treat_fields["size"] as LineEdit).text,
		doc.display_unit)
	if not r["ok"] or float(r["mm"]) <= 0.0:
		set_status_hint("Fillet/Chamfer: enter a size")
		return
	if _treat_edit_fid == "":
		_treat_dialog.hide()
		return
	# Oversize guard (QA §M35.6): validate the edited size against the
	# combined build BEFORE committing — otherwise replay silently keeps
	# the untreated body and the user never learns why.
	var cur := doc.feature_by_id(_treat_edit_fid) as EdgeTreatFeature
	var root := doc.feature_by_id(cur.body) as ExtrudeFeature \
		if cur != null else null
	if cur != null and root != null:
		var trial := EdgeTreatFeature.from_dict(cur.to_dict())
		trial.size_mm = float(r["mm"])
		var ets: Array = []
		for f in doc.live_features():
			if f is EdgeTreatFeature \
					and (f as EdgeTreatFeature).body == cur.body:
				ets.append(trial if f == cur else f)
		if EdgeTreatFeature.build_combined(doc, root, ets) == null:
			set_status_hint("Fillet/Chamfer: "
				+ (EdgeTreatFeature.build_error
					if EdgeTreatFeature.build_error != ""
					else "size too large for the body"))
			return   # dialog stays open for another try
	_treat_dialog.hide()
	stack.push_no_merge(CmdSetFeatureFlag.new(_treat_edit_fid, "size_mm",
		float(r["mm"])))


## --- the edge pick (create flow) ---------------------------------------------

var _treat_pick_dialog: Window = null
var _treat_pick_size: LineEdit = null
var _treat_pick_count: Label = null


func _start_edge_treat_pick(p_kind: String) -> void:
	_treat_kind = p_kind if p_kind != "" else EdgeTreatFeature.KIND_FILLET
	_treat_body = world.selected_body()
	if _treat_body == "":
		require_body("Fillet" if _treat_kind == EdgeTreatFeature.KIND_FILLET
			else "Chamfer", func() -> void: _start_edge_treat_pick(p_kind))
		return
	var root := _edge_treat_root(_treat_body)
	if root == null:
		return
	var all_edges := EdgeTreatFeature.pickable_edges(doc, root)
	if all_edges.is_empty():
		set_status_hint("Fillet/Chamfer: no treatable edges on this body")
		return
	# Edges an existing treatment already covers are not offered again —
	# stacked features may share a body but never an edge (QA §M35.3).
	var used := _edge_treat_used_keys(_treat_body, all_edges)
	_treat_pick_edges = []
	for e: Dictionary in all_edges:
		if not used.has(String(e["key"])):
			_treat_pick_edges.append(e)
	if _treat_pick_edges.is_empty():
		set_status_hint("Fillet/Chamfer: every edge on this body is already "
			+ "treated — edit those features instead")
		return
	_treat_selected = {}
	picking_treat_edges = true
	world.show_treat_edges(_treat_pick_edges, _treat_selected,
		_axis_hover_width_mm())
	_open_treat_pick_dialog()
	_refresh_ui()


func _open_treat_pick_dialog() -> void:
	if _treat_pick_dialog == null:
		_treat_pick_dialog = Window.new()
		_treat_pick_dialog.name = "EdgeTreatPickDialog"
		_treat_pick_dialog.size = Vector2i(300, 130)
		_treat_pick_dialog.exclusive = false
		_treat_pick_dialog.close_requested.connect(_end_edge_treat_pick)
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_treat_pick_dialog.add_child(box)
		var row := HBoxContainer.new()
		box.add_child(row)
		var lab := Label.new()
		lab.text = "Size"
		lab.custom_minimum_size = Vector2(60, 0)
		row.add_child(lab)
		_treat_pick_size = LineEdit.new()
		_treat_pick_size.name = "TreatPickSizeEdit"
		_treat_pick_size.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_treat_pick_size.text_submitted.connect(
			func(_t: String) -> void: _commit_edge_treat_pick())
		row.add_child(_treat_pick_size)
		_treat_pick_count = Label.new()
		_treat_pick_count.name = "TreatPickCountLabel"
		box.add_child(_treat_pick_count)
		var okb := Button.new()
		okb.name = "TreatPickApplyBtn"
		okb.text = "Apply"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_edge_treat_pick)
		box.add_child(okb)
		add_child(_treat_pick_dialog)
	_treat_pick_dialog.title = "Fillet Edges" \
		if _treat_kind == EdgeTreatFeature.KIND_FILLET else "Chamfer Edges"
	_treat_pick_size.text = UnitConverter.format(3.0, doc.display_unit)
	_update_treat_pick_count()
	# Top-right corner, not centered: the user is about to click edges in
	# the viewport and a centered window would sit right on top of the body.
	_treat_pick_dialog.position = Vector2i(
		int(get_viewport().get_visible_rect().size.x) - 320, 80)
	_treat_pick_dialog.show()


func _update_treat_pick_count() -> void:
	if _treat_pick_count == null:
		return
	var n := _treat_selected.size()
	_treat_pick_count.text = "%d edge%s selected — click edges in the view" \
		% [n, "" if n == 1 else "s"]


func _commit_edge_treat_pick() -> void:
	if not picking_treat_edges:
		return
	var r := UnitConverter.parse(_treat_pick_size.text, doc.display_unit)
	if not r["ok"] or float(r["mm"]) <= 0.0:
		set_status_hint("Fillet/Chamfer: enter a size")
		return
	if _treat_selected.is_empty():
		set_status_hint("Fillet/Chamfer: click at least one edge in the view")
		return
	var corner_list: Array = []
	var top_list: Array = []
	var bottom_list: Array = []
	for key in _treat_selected:
		var ks := String(key)
		if ks.begins_with("corner:"):
			corner_list.append(int(ks.substr(7)))
		elif ks.begins_with("top:"):
			top_list.append(int(ks.substr(4)))
		elif ks.begins_with("bottom:"):
			bottom_list.append(int(ks.substr(7)))
	corner_list.sort()
	top_list.sort()
	bottom_list.sort()
	var fid := edge_treat(_treat_body, _treat_kind, float(r["mm"]),
		not corner_list.is_empty(), not top_list.is_empty(),
		not bottom_list.is_empty(), corner_list, top_list, bottom_list)
	if fid == "":
		return   # hint already set; stay in the pick so the user can adjust
	_end_edge_treat_pick()


func _end_edge_treat_pick() -> void:
	picking_treat_edges = false
	_treat_pick_edges = []
	_treat_selected = {}
	world.hide_treat_edges()
	if _treat_pick_dialog != null:
		_treat_pick_dialog.hide()
	_refresh_ui()


## Edge keys already covered by live treatments on `body_id`, expanded
## against the full pickable list (empty corner/segment lists mean "all").
func _edge_treat_used_keys(body_id: String, all_edges: Array) -> Dictionary:
	var corner_all: Array = []
	var seg_all: Array = []
	for e: Dictionary in all_edges:
		var ks := String(e["key"])
		if ks.begins_with("corner:"):
			corner_all.append(int(ks.substr(7)))
		elif ks.begins_with("top:"):
			seg_all.append(int(ks.substr(4)))
	var used := {}
	for f in doc.live_features():
		var et := f as EdgeTreatFeature
		if et == null or et.body != body_id:
			continue
		if et.lateral:
			for c in (et.corners if not et.corners.is_empty() else corner_all):
				used["corner:%d" % int(c)] = true
		if et.top:
			for s in (et.top_segs if not et.top_segs.is_empty() else seg_all):
				used["top:%d" % int(s)] = true
		if et.bottom:
			for s in (et.bottom_segs if not et.bottom_segs.is_empty()
					else seg_all):
				used["bottom:%d" % int(s)] = true
	return used


## Every pick-list key sharing the clicked edge's chain — smooth rim runs
## (a cylinder's rim) toggle as one (QA §M35.4).
func _treat_chain_keys(key: String) -> Array:
	var chain := key
	for e: Dictionary in _treat_pick_edges:
		if String(e["key"]) == key:
			chain = String(e.get("chain", key))
			break
	var out: Array = []
	for e: Dictionary in _treat_pick_edges:
		if String(e.get("chain", e["key"])) == chain:
			out.append(String(e["key"]))
	return out


## The treat edge (by key) nearest the ray, within a few screen pixels of
## it. "" on a miss.
func _treat_edge_under_ray(origin: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_d := _axis_hover_width_mm() * 2.0
	var far := origin + dir * 1.0e6
	for e: Dictionary in _treat_pick_edges:
		var pts := Geometry3D.get_closest_points_between_segments(
			origin, far, e["a"] as Vector3, e["b"] as Vector3)
		var d := pts[0].distance_to(pts[1])
		if d < best_d:
			best_d = d
			best = String(e["key"])
	return best


## Prismatic-scope guard shared by the pick flow and edge_treat: the body
## must root at a plain extrude, untreated, with no boolean touching it (a
## body any join/cut touches is a boolean body — same AABB rule BodyBuilder
## targets by). null with the reason hinted.
func _edge_treat_root(body_id: String) -> ExtrudeFeature:
	var root := doc.feature_by_id(body_id) as ExtrudeFeature
	if root == null:
		set_status_hint("Fillet/Chamfer: prismatic scope — works on "
			+ "plain extrude bodies only (no booleans/revolves/sweeps)")
		return null
	var root_part := root.solid_part(doc)
	for f in doc.live_features():
		var sf2 := f as SolidFeature
		if sf2 != null and sf2 != root \
				and sf2.operation != SolidFeature.OP_NEW_BODY \
				and not root_part.is_empty():
			var p2 := sf2.solid_part(doc)
			if not p2.is_empty() and (p2["aabb"] as AABB).intersects(
					root_part["aabb"] as AABB):
				set_status_hint("Fillet/Chamfer: this body carries booleans "
					+ "— prismatic scope covers plain extrudes only")
				return null
	return root


## Create the treatment (shared with RPC). `corner_list` limits the lateral
## pass to those profile-polygon corner indices (empty = every eligible
## corner); `top_list` / `bot_list` limit the rims to those polygon edge
## indices (empty = the whole rim). Returns feature id or "".
func edge_treat(body_id: String, p_kind: String, size: float,
		lat := true, top := true, bot := false,
		corner_list: Array = [], top_list: Array = [],
		bot_list: Array = []) -> String:
	var root := _edge_treat_root(body_id)
	if root == null:
		return ""
	if not (lat or top or bot):
		set_status_hint("Fillet/Chamfer: pick at least one edge set")
		return ""
	# Overlap guard: stacked treatments may share the body, never an edge.
	var all_edges := EdgeTreatFeature.pickable_edges(doc, root)
	var used := _edge_treat_used_keys(body_id, all_edges)
	var req: Array = []
	for e: Dictionary in all_edges:
		var ks := String(e["key"])
		if ks.begins_with("corner:") and lat and (corner_list.is_empty()
				or corner_list.has(int(ks.substr(7)))):
			req.append(ks)
		elif ks.begins_with("top:") and top and (top_list.is_empty()
				or top_list.has(int(ks.substr(4)))):
			req.append(ks)
		elif ks.begins_with("bottom:") and bot and (bot_list.is_empty()
				or bot_list.has(int(ks.substr(7)))):
			req.append(ks)
	for rk in req:
		if used.has(rk):
			set_status_hint("Fillet/Chamfer: some of those edges are "
				+ "already treated — edit that feature or pick other edges")
			return ""
	var et := EdgeTreatFeature.new()
	et.id = doc.next_feature_id()
	et.name = doc.auto_name("Fillet"
		if p_kind == EdgeTreatFeature.KIND_FILLET else "Chamfer")
	et.body = body_id
	et.treat = p_kind
	et.size_mm = size
	et.lateral = lat
	et.top = top
	et.bottom = bot
	for c in corner_list:
		et.corners.append(int(c))
	for s in top_list:
		et.top_segs.append(int(s))
	for s in bot_list:
		et.bottom_segs.append(int(s))
	# Validate the COMBINED result (this treatment plus any existing ones on
	# the body) so a stacking conflict refuses before touching the timeline.
	var ets: Array = []
	for f in doc.live_features():
		if f is EdgeTreatFeature and (f as EdgeTreatFeature).body == body_id:
			ets.append(f)
	ets.append(et)
	if EdgeTreatFeature.build_combined(doc, root, ets) == null:
		set_status_hint("Fillet/Chamfer failed: "
			+ (EdgeTreatFeature.build_error if EdgeTreatFeature.build_error
				!= "" else "size too large for the body, or the profile "
				+ "has holes"))
		return ""
	stack.push_no_merge(CmdAddFeature.new(et))
	return et.id


## --- sweep + loft (M34) ------------------------------------------------------

var picking_sweep_profile := false
var picking_sweep_path := false
var _pending_sweep := {}          # {sketch_id, at} then + path
var picking_loft := false
var _loft_sections: Array = []
var _sweep_dialog: Window = null
var _sweep_op: OptionButton = null
var _loft_dialog: Window = null
var _loft_op: OptionButton = null
var _loft_count: Label = null


func _on_sweep_pressed() -> void:
	if mode != Mode.MODEL:
		return
	picking_sweep_profile = true
	_pending_sweep = {}
	_refresh_ui()


func _on_loft_pressed() -> void:
	if mode != Mode.MODEL:
		return
	picking_loft = true
	_loft_sections = []
	_open_loft_dialog()
	_refresh_ui()


## The nearest sketch CURVE under the ray, across every live sketch —
## sweep's path pick. {sketch_id, entity_id} or {}.
func _sweep_path_under_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_d := _axis_hover_width_mm()
	for f in doc.live_features():
		var sf := f as SketchFeature
		if sf == null:
			continue
		var xf := sf.plane_transform()
		for e in sf.sketch.entities():
			if e.kind() in ["point", "circle"]:
				continue
			if e.kind() == "spline" and (e as SketchSpline).closed:
				continue
			var poly := SketchGeometry.entity_polyline(sf.sketch, e)
			for i in poly.size() - 1:
				var a := xf * Vector3(poly[i].x, poly[i].y, 0.0)
				var b := xf * Vector3(poly[i + 1].x, poly[i + 1].y, 0.0)
				var d := _ray_segment_distance(origin, dir, a, b)
				if d < best_d:
					best_d = d
					best = {"sketch_id": sf.id, "entity_id": e.id}
	return best


static func _ray_segment_distance(ro: Vector3, rd: Vector3, a: Vector3,
		b: Vector3) -> float:
	# Sampled closest approach — robust and plenty accurate for picking.
	var best := INF
	for k in 9:
		var p := a.lerp(b, k / 8.0)
		var t := maxf((p - ro).dot(rd), 0.0)
		best = minf(best, (ro + rd * t).distance_to(p))
	return best


func _open_sweep_dialog() -> void:
	if _sweep_dialog == null:
		_sweep_dialog = Window.new()
		_sweep_dialog.name = "SweepDialog"
		_sweep_dialog.title = "Sweep"
		_sweep_dialog.size = Vector2i(240, 96)
		_sweep_dialog.exclusive = false
		_sweep_dialog.close_requested.connect(
			func() -> void: _sweep_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_sweep_dialog.add_child(box)
		_sweep_op = OptionButton.new()
		_sweep_op.name = "SweepOpPick"
		_sweep_op.focus_mode = Control.FOCUS_NONE
		_sweep_op.add_item("New Body", 0)
		_sweep_op.add_item("Join", 1)
		_sweep_op.add_item("Cut", 2)
		box.add_child(_sweep_op)
		var okb := Button.new()
		okb.name = "SweepOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_sweep)
		box.add_child(okb)
		add_child(_sweep_dialog)
	_sweep_dialog.popup_centered()


func _commit_sweep() -> void:
	_sweep_dialog.hide()
	var ops := [SolidFeature.OP_NEW_BODY, SolidFeature.OP_JOIN,
		SolidFeature.OP_CUT]
	var op: String = ops[_sweep_op.get_selected_id()]
	sweep(String(_pending_sweep["sketch_id"]),
		_pending_sweep["at"] as Vector2,
		String(_pending_sweep["path_sketch"]),
		String(_pending_sweep["path_entity"]), op)
	_pending_sweep = {}


func sweep(profile_sketch: String, at: Vector2, path_sk: String,
		path_entity: String, op := SolidFeature.OP_NEW_BODY) -> String:
	var f := SweepFeature.make(profile_sketch, at, path_sk, path_entity, op)
	f.id = doc.next_feature_id()
	f.name = doc.auto_name("Sweep")
	f.doc_ref = weakref(doc)
	if f.build_mesh(doc) == null:
		set_status_hint("Sweep failed: " + (f.last_error if f.last_error != ""
			else "no profile/path"))
		return ""
	if f.last_warning != "":
		set_status_hint("Sweep: " + f.last_warning)
	stack.push_no_merge(CmdAddFeature.new(f))
	return f.id


## Amber-fill marks on every section picked so far (QA §M34.5).
func _show_loft_section_marks() -> void:
	var marks: Array = []
	for sec: Dictionary in _loft_sections:
		marks.append({"sf": doc.sketch_feature(String(sec["sketch"])),
			"at": sec["at"]})
	world.show_loft_sections(marks)


func _open_loft_dialog() -> void:
	if _loft_dialog == null:
		_loft_dialog = Window.new()
		_loft_dialog.name = "LoftDialog"
		_loft_dialog.title = "Loft"
		_loft_dialog.size = Vector2i(250, 120)
		_loft_dialog.exclusive = false
		_loft_dialog.close_requested.connect(func() -> void:
			_loft_dialog.hide()
			picking_loft = false
			_loft_sections = []
			world.hide_loft_sections()
			_refresh_ui())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_loft_dialog.add_child(box)
		_loft_count = Label.new()
		_loft_count.name = "LoftCountLabel"
		box.add_child(_loft_count)
		_loft_op = OptionButton.new()
		_loft_op.name = "LoftOpPick"
		_loft_op.focus_mode = Control.FOCUS_NONE
		_loft_op.add_item("New Body", 0)
		_loft_op.add_item("Join", 1)
		_loft_op.add_item("Cut", 2)
		box.add_child(_loft_op)
		var okb := Button.new()
		okb.name = "LoftOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_loft)
		box.add_child(okb)
		add_child(_loft_dialog)
	_loft_count.text = "Sections: %d (click profiles)" % _loft_sections.size()
	# Top-right corner, not centered: the user is about to click profiles in
	# the viewport and a centered window sits right on top of them (same
	# placement as the fillet/chamfer edge pick).
	_loft_dialog.position = Vector2i(
		int(get_viewport().get_visible_rect().size.x) - 270, 80)
	_loft_dialog.show()


func _commit_loft() -> void:
	if _loft_sections.size() < 2:
		set_status_hint("Loft: pick at least two profiles (sketch regions "
			+ "on different planes — to spin one profile about an axis, "
			+ "use Revolve)")
		return
	_loft_dialog.hide()
	picking_loft = false
	world.hide_loft_sections()
	var ops := [SolidFeature.OP_NEW_BODY, SolidFeature.OP_JOIN,
		SolidFeature.OP_CUT]
	loft(_loft_sections, ops[_loft_op.get_selected_id()])
	_loft_sections = []
	_refresh_ui()


func loft(p_sections: Array, op := SolidFeature.OP_NEW_BODY) -> String:
	var f := LoftFeature.make(p_sections, op)
	f.id = doc.next_feature_id()
	f.name = doc.auto_name("Loft")
	f.doc_ref = weakref(doc)
	if f.build_mesh(doc) == null:
		set_status_hint("Loft failed: needs 2+ hole-free closed profiles")
		return ""
	stack.push_no_merge(CmdAddFeature.new(f))
	return f.id


## --- solid mirror + patterns (M33) -------------------------------------------

var picking_mirror_plane := false
## Arm-then-pick for body commands (CHANGES #6): a command that needs a body
## with none selected arms a body pick; the click selects it and runs the
## command. See require_body.
var picking_body := false
var _body_pick_then: Callable = Callable()
var _body_pick_label := ""
var _mirror_source := ""
var _pattern_dialog: Window = null
var _pattern_fields := {}
var _pattern_edit_fid := ""
var _pattern_source := ""


## Run `then` with a body selected: right away when one is, otherwise arm
## a body pick (hover-highlighted; Esc cancels) whose click selects the body
## and then runs `then`. Every body command goes through here so "arm the
## tool, then pick" holds for all of them. Returns true when run at once.
func require_body(label: String, then: Callable) -> bool:
	if world.selected_body() != "":
		then.call()
		return true
	if world.body_ids().is_empty():
		set_status_hint("%s: no bodies in the model yet" % label)
		return false
	picking_body = true
	_body_pick_then = then
	_body_pick_label = label
	_refresh_ui()
	return false


func _end_body_pick() -> void:
	picking_body = false
	_body_pick_then = Callable()
	world.set_body_hover("")


func _on_mirror_body_pressed() -> void:
	if mode != Mode.MODEL:
		return
	_mirror_source = world.selected_body()
	if _mirror_source == "":
		require_body("Mirror Body", _on_mirror_body_pressed)
		return
	picking_mirror_plane = true
	world.set_planes_visible(true)
	_refresh_ui()


func mirror_body(body_id: String, plane: String) -> String:
	if not SketchFeature.PLANES.has(plane) and doc.plane_feature(plane) == null:
		set_status_hint("Mirror Body: unknown plane %s" % plane)
		return ""
	var mf := MirrorBodyFeature.new()
	mf.id = doc.next_feature_id()
	mf.name = doc.auto_name("Mirror")
	mf.source = body_id
	mf.plane = plane
	stack.push_no_merge(CmdAddFeature.new(mf))
	return mf.id


func open_pattern_dialog(edit_fid: String) -> void:
	var pf := doc.feature_by_id(edit_fid) as PatternBodyFeature
	_pattern_edit_fid = edit_fid if pf != null else ""
	_pattern_source = pf.source if pf != null else world.selected_body()
	if _pattern_source == "":
		require_body("Pattern", func() -> void: open_pattern_dialog(""))
		return
	if _pattern_dialog == null:
		_pattern_dialog = Window.new()
		_pattern_dialog.name = "PatternDialog"
		_pattern_dialog.size = Vector2i(300, 300)
		_pattern_dialog.exclusive = false
		_pattern_dialog.close_requested.connect(
			func() -> void: _pattern_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_pattern_dialog.add_child(box)
		_pattern_fields = {}
		var mrow := HBoxContainer.new()
		box.add_child(mrow)
		var mlab := Label.new()
		mlab.text = "Mode"
		mlab.custom_minimum_size = Vector2(70, 0)
		mrow.add_child(mlab)
		var mode_pick := OptionButton.new()
		mode_pick.name = "PatternModePick"
		mode_pick.focus_mode = Control.FOCUS_NONE
		mode_pick.add_item("Linear", 0)
		mode_pick.add_item("Circular", 1)
		mode_pick.item_selected.connect(func(_i: int) -> void:
			_sync_pattern_rows())
		mrow.add_child(mode_pick)
		_pattern_fields["mode"] = mode_pick
		for def: Array in [["Count", "n1"], ["Δ1 X,Y,Z", "o1"],
				["Count 2", "n2"], ["Δ2 X,Y,Z", "o2"], ["Total °", "total"]]:
			var row := HBoxContainer.new()
			row.name = "Row_" + String(def[1])
			box.add_child(row)
			var lab := Label.new()
			lab.text = def[0]
			lab.custom_minimum_size = Vector2(70, 0)
			row.add_child(lab)
			var edit := LineEdit.new()
			edit.name = "Pattern" + String(def[1]).capitalize() + "Edit"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_submitted.connect(
				func(_t: String) -> void: _commit_pattern_dialog())
			row.add_child(edit)
			_pattern_fields[def[1]] = edit
			_pattern_fields["row_" + String(def[1])] = row
		var arow := HBoxContainer.new()
		arow.name = "Row_axis"
		box.add_child(arow)
		var alab := Label.new()
		alab.text = "Axis"
		alab.custom_minimum_size = Vector2(70, 0)
		arow.add_child(alab)
		var axis := OptionButton.new()
		axis.name = "PatternAxisPick"
		axis.focus_mode = Control.FOCUS_NONE
		axis.add_item("Z", 2)
		axis.add_item("X", 0)
		axis.add_item("Y", 1)
		arow.add_child(axis)
		_pattern_fields["axis"] = axis
		_pattern_fields["row_axis"] = arow
		var okb := Button.new()
		okb.name = "PatternOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_pattern_dialog)
		box.add_child(okb)
		add_child(_pattern_dialog)
	var u := doc.display_unit
	var mp: OptionButton = _pattern_fields["mode"]
	if pf != null:
		_pattern_dialog.title = "Edit %s" % pf.name
		mp.select(1 if pf.mode == PatternBodyFeature.MODE_CIRCULAR else 0)
		(_pattern_fields["n1"] as LineEdit).text = str(pf.count1)
		(_pattern_fields["o1"] as LineEdit).text = "%s, %s, %s" % [
			UnitConverter.format(pf.offset1.x, u),
			UnitConverter.format(pf.offset1.y, u),
			UnitConverter.format(pf.offset1.z, u)]
		(_pattern_fields["n2"] as LineEdit).text = str(pf.count2)
		(_pattern_fields["o2"] as LineEdit).text = "%s, %s, %s" % [
			UnitConverter.format(pf.offset2.x, u),
			UnitConverter.format(pf.offset2.y, u),
			UnitConverter.format(pf.offset2.z, u)]
		(_pattern_fields["total"] as LineEdit).text = "%.1f" % pf.total_deg
		var ax: OptionButton = _pattern_fields["axis"]
		var want := 2
		if absf(pf.axis_dir.x) > 0.5:
			want = 0
		elif absf(pf.axis_dir.y) > 0.5:
			want = 1
		ax.select(ax.get_item_index(want))
	else:
		_pattern_dialog.title = "Pattern Body"
		mp.select(0)
		(_pattern_fields["n1"] as LineEdit).text = "3"
		var w := 30.0
		for b: Dictionary in world.bodies():
			if String(b["id"]) == _pattern_source:
				w = (b["mesh"] as ArrayMesh).get_aabb().size.x + 10.0
		(_pattern_fields["o1"] as LineEdit).text = "%s, %s, %s" % [
			UnitConverter.format(w, u), UnitConverter.format(0, u),
			UnitConverter.format(0, u)]
		(_pattern_fields["n2"] as LineEdit).text = "1"
		(_pattern_fields["o2"] as LineEdit).text = "%s, %s, %s" % [
			UnitConverter.format(0, u), UnitConverter.format(0, u),
			UnitConverter.format(0, u)]
		(_pattern_fields["total"] as LineEdit).text = "360"
	_sync_pattern_rows()
	_pattern_dialog.popup_centered()


func _sync_pattern_rows() -> void:
	var circular: bool = (_pattern_fields["mode"] as OptionButton) \
		.get_selected_id() == 1
	(_pattern_fields["row_o1"] as Control).visible = not circular
	(_pattern_fields["row_n2"] as Control).visible = not circular
	(_pattern_fields["row_o2"] as Control).visible = not circular
	(_pattern_fields["row_total"] as Control).visible = circular
	(_pattern_fields["row_axis"] as Control).visible = circular


func _parse_vec3(text: String, u: UnitConverter.Unit) -> Vector3:
	var parts := text.split(",")
	var out := Vector3.ZERO
	for i in mini(parts.size(), 3):
		var r := UnitConverter.parse(parts[i].strip_edges(), u)
		out[i] = float(r["mm"]) if r["ok"] else 0.0
	return out


func _commit_pattern_dialog() -> void:
	var u := doc.display_unit
	var circular: bool = (_pattern_fields["mode"] as OptionButton) \
		.get_selected_id() == 1
	var n1_text := (_pattern_fields["n1"] as LineEdit).text
	var n2_text := (_pattern_fields["n2"] as LineEdit).text
	var total_text := (_pattern_fields["total"] as LineEdit).text
	var axis_id: int = (_pattern_fields["axis"] as OptionButton) \
		.get_selected_id()
	var props := {
		"mode": PatternBodyFeature.MODE_CIRCULAR if circular
			else PatternBodyFeature.MODE_LINEAR,
		"count1": maxi(n1_text.to_int(), 2) if n1_text.is_valid_int() else 3,
		"offset1": _parse_vec3((_pattern_fields["o1"] as LineEdit).text, u),
		"count2": maxi(n2_text.to_int(), 1) if n2_text.is_valid_int() else 1,
		"offset2": _parse_vec3((_pattern_fields["o2"] as LineEdit).text, u),
		"axis_dir": [Vector3(1, 0, 0), Vector3(0, 1, 0),
			Vector3(0, 0, 1)][axis_id] as Vector3,
		"total_deg": total_text.to_float() if total_text.is_valid_float()
			else 360.0,
	}
	_pattern_dialog.hide()
	if _pattern_edit_fid != "":
		var batch := CmdMergeBatch.new("Edit Pattern", [])
		stack.push_no_merge(batch)
		for k in props:
			stack.push(CmdSetFeatureFlag.new(_pattern_edit_fid, k, props[k]))
		batch.seal()
		return
	pattern_body(_pattern_source, props)


func pattern_body(body_id: String, props: Dictionary) -> String:
	var pf := PatternBodyFeature.new()
	pf.id = doc.next_feature_id()
	pf.name = doc.auto_name("Pattern")
	pf.source = body_id
	for k in props:
		pf.set(k, props[k])
	if pf.instance_transforms().is_empty():
		set_status_hint("Pattern: nothing to add (check counts/offsets)")
		return ""
	stack.push_no_merge(CmdAddFeature.new(pf))
	return pf.id


## --- move / copy bodies + appearance (M32) -----------------------------------

var _move_dialog: Window = null
var _move_fields := {}
var _move_edit_fid := ""     # transform feature being edited ("" = create)
var _move_target_body := ""
var _copy_dialog: Window = null
var _copy_fields := {}
var _copy_edit_fid := ""
var _copy_source_body := ""
var _color_dialog: Window = null
var _color_picker: ColorPicker = null
var _color_target := ""


## Open the Move Body dialog: creating (edit_fid == "", uses the selected
## body) or editing an existing transform feature.
func open_move_dialog(edit_fid: String) -> void:
	var tf := doc.feature_by_id(edit_fid) as TransformFeature
	_move_edit_fid = edit_fid if tf != null else ""
	_move_target_body = tf.body if tf != null else world.selected_body()
	if _move_target_body == "":
		require_body("Move Body", func() -> void: open_move_dialog(""))
		return
	if _move_dialog == null:
		_move_dialog = Window.new()
		_move_dialog.name = "MoveBodyDialog"
		_move_dialog.size = Vector2i(280, 210)
		_move_dialog.exclusive = false
		_move_dialog.close_requested.connect(
			func() -> void: _move_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_move_dialog.add_child(box)
		_move_fields = {}
		for def: Array in [["ΔX", "dx"], ["ΔY", "dy"], ["ΔZ", "dz"],
				["Angle °", "ang"]]:
			var row := HBoxContainer.new()
			box.add_child(row)
			var lab := Label.new()
			lab.text = def[0]
			lab.custom_minimum_size = Vector2(64, 0)
			row.add_child(lab)
			var edit := LineEdit.new()
			edit.name = "Move" + String(def[1]).capitalize() + "Edit"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_submitted.connect(
				func(_t: String) -> void: _commit_move_dialog())
			row.add_child(edit)
			_move_fields[def[1]] = edit
		var arow := HBoxContainer.new()
		box.add_child(arow)
		var alab := Label.new()
		alab.text = "Axis"
		alab.custom_minimum_size = Vector2(64, 0)
		arow.add_child(alab)
		var axis := OptionButton.new()
		axis.name = "MoveAxisPick"
		axis.focus_mode = Control.FOCUS_NONE
		axis.add_item("Z", 2)
		axis.add_item("X", 0)
		axis.add_item("Y", 1)
		arow.add_child(axis)
		_move_fields["axis"] = axis
		var okb := Button.new()
		okb.name = "MoveOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_move_dialog)
		box.add_child(okb)
		add_child(_move_dialog)
	var u := doc.display_unit
	if tf != null:
		_move_dialog.title = "Edit %s" % tf.name
		(_move_fields["dx"] as LineEdit).text = UnitConverter.format(tf.translation.x, u)
		(_move_fields["dy"] as LineEdit).text = UnitConverter.format(tf.translation.y, u)
		(_move_fields["dz"] as LineEdit).text = UnitConverter.format(tf.translation.z, u)
		(_move_fields["ang"] as LineEdit).text = "%.1f" % tf.rot_deg
		var ax: OptionButton = _move_fields["axis"]
		var want := 2
		if absf(tf.rot_axis.x) > 0.5:
			want = 0
		elif absf(tf.rot_axis.y) > 0.5:
			want = 1
		ax.select(ax.get_item_index(want))
	else:
		_move_dialog.title = "Move Body"
		for k in ["dx", "dy", "dz"]:
			(_move_fields[k] as LineEdit).text = ""
		(_move_fields["ang"] as LineEdit).text = ""
	_move_dialog.popup_centered()


func _commit_move_dialog() -> void:
	var u := doc.display_unit
	var vals := {}
	for k in ["dx", "dy", "dz"]:
		var r := UnitConverter.parse((_move_fields[k] as LineEdit).text, u)
		vals[k] = float(r["mm"]) if r["ok"] else 0.0
	var ang_text := (_move_fields["ang"] as LineEdit).text
	var ang := ang_text.to_float() if ang_text.is_valid_float() else 0.0
	var axis_id: int = (_move_fields["axis"] as OptionButton).get_selected_id()
	var axis: Vector3 = [Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, 0, 1)][axis_id]
	_move_dialog.hide()
	var t := Vector3(vals["dx"], vals["dy"], vals["dz"])
	if _move_edit_fid != "":
		var batch := CmdMergeBatch.new("Edit Move", [])
		stack.push_no_merge(batch)
		stack.push(CmdSetFeatureFlag.new(_move_edit_fid, "translation", t))
		stack.push(CmdSetFeatureFlag.new(_move_edit_fid, "rot_axis", axis))
		stack.push(CmdSetFeatureFlag.new(_move_edit_fid, "rot_deg", ang))
		batch.seal()
		return
	move_body(_move_target_body, t, axis, ang)


## Create the transform feature (shared with RPC). Returns its id or "".
func move_body(body_id: String, t: Vector3, axis := Vector3(0, 0, 1),
		ang_deg := 0.0) -> String:
	if t.length() < 1e-9 and absf(ang_deg) < 1e-9:
		set_status_hint("Move Body: zero move")
		return ""
	var tf := TransformFeature.new()
	tf.id = doc.next_feature_id()
	tf.name = doc.auto_name("Move")
	tf.body = body_id
	tf.translation = t
	tf.rot_axis = axis
	tf.rot_deg = ang_deg
	stack.push_no_merge(CmdAddFeature.new(tf))
	return tf.id


func open_copy_dialog(edit_fid: String) -> void:
	var cf := doc.feature_by_id(edit_fid) as CopyBodyFeature
	_copy_edit_fid = edit_fid if cf != null else ""
	_copy_source_body = cf.source if cf != null else world.selected_body()
	if _copy_source_body == "":
		require_body("Copy Body", func() -> void: open_copy_dialog(""))
		return
	if _copy_dialog == null:
		_copy_dialog = Window.new()
		_copy_dialog.name = "CopyBodyDialog"
		_copy_dialog.size = Vector2i(260, 150)
		_copy_dialog.exclusive = false
		_copy_dialog.close_requested.connect(
			func() -> void: _copy_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_copy_dialog.add_child(box)
		_copy_fields = {}
		for def: Array in [["ΔX", "dx"], ["ΔY", "dy"], ["ΔZ", "dz"]]:
			var row := HBoxContainer.new()
			box.add_child(row)
			var lab := Label.new()
			lab.text = def[0]
			lab.custom_minimum_size = Vector2(64, 0)
			row.add_child(lab)
			var edit := LineEdit.new()
			edit.name = "Copy" + String(def[1]).capitalize() + "Edit"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_submitted.connect(
				func(_t: String) -> void: _commit_copy_dialog())
			row.add_child(edit)
			_copy_fields[def[1]] = edit
		var okb := Button.new()
		okb.name = "CopyOkBtn"
		okb.text = "OK"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(_commit_copy_dialog)
		box.add_child(okb)
		add_child(_copy_dialog)
	var u := doc.display_unit
	if cf != null:
		_copy_dialog.title = "Edit %s" % cf.name
		(_copy_fields["dx"] as LineEdit).text = UnitConverter.format(cf.translation.x, u)
		(_copy_fields["dy"] as LineEdit).text = UnitConverter.format(cf.translation.y, u)
		(_copy_fields["dz"] as LineEdit).text = UnitConverter.format(cf.translation.z, u)
	else:
		_copy_dialog.title = "Copy Body"
		# Default: one body-width to the +X so the copy is visibly its own.
		var w := 20.0
		for b: Dictionary in world.bodies():
			if String(b["id"]) == _copy_source_body:
				w = (b["mesh"] as ArrayMesh).get_aabb().size.x + 10.0
		(_copy_fields["dx"] as LineEdit).text = UnitConverter.format(w, u)
		(_copy_fields["dy"] as LineEdit).text = UnitConverter.format(0, u)
		(_copy_fields["dz"] as LineEdit).text = UnitConverter.format(0, u)
	_copy_dialog.popup_centered()


func _commit_copy_dialog() -> void:
	var u := doc.display_unit
	var vals := {}
	for k in ["dx", "dy", "dz"]:
		var r := UnitConverter.parse((_copy_fields[k] as LineEdit).text, u)
		vals[k] = float(r["mm"]) if r["ok"] else 0.0
	_copy_dialog.hide()
	var t := Vector3(vals["dx"], vals["dy"], vals["dz"])
	if _copy_edit_fid != "":
		stack.push_no_merge(CmdSetFeatureFlag.new(_copy_edit_fid,
			"translation", t))
		return
	copy_body(_copy_source_body, t)


func copy_body(body_id: String, t: Vector3) -> String:
	var cf := CopyBodyFeature.new()
	cf.id = doc.next_feature_id()
	cf.name = doc.auto_name("Copy")
	cf.source = body_id
	cf.translation = t
	stack.push_no_merge(CmdAddFeature.new(cf))
	return cf.id


## Body appearance (M32): color lives on the body's ROOT solid feature.
## Copies inherit their source's color until given one of their own
## (QA §M32.5) — so they are colorable too.
func pick_body_color(body_id: String) -> void:
	var f := doc.feature_by_id(body_id)
	if not (f is SolidFeature or f is CopyBodyFeature):
		set_status_hint("Color: select a body (mirror/pattern instances "
			+ "follow their source)")
		return
	var body_color: Color = f.get("color")
	if f is CopyBodyFeature and body_color.a <= 0.0:
		# Uncolored copy: seed the picker with the inherited source color.
		var src := doc.feature_by_id((f as CopyBodyFeature).source)
		if src is SolidFeature:
			body_color = (src as SolidFeature).color
	_color_target = body_id
	if _color_dialog == null:
		_color_dialog = Window.new()
		_color_dialog.name = "BodyColorDialog"
		_color_dialog.title = "Body Color"
		_color_dialog.size = Vector2i(300, 420)
		_color_dialog.exclusive = false
		_color_dialog.close_requested.connect(
			func() -> void: _color_dialog.hide())
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_color_dialog.add_child(box)
		_color_picker = ColorPicker.new()
		_color_picker.name = "BodyColorPicker"
		_color_picker.edit_alpha = false
		# Compact (QA §M32 additional): the stock picker's sampler/mode/
		# preset rows pushed Apply below the window with no way to scroll.
		_color_picker.sampler_visible = false
		_color_picker.color_modes_visible = false
		_color_picker.presets_visible = false
		_color_picker.can_add_swatches = false
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		box.add_child(scroll)
		scroll.add_child(_color_picker)
		var okb := Button.new()
		okb.name = "BodyColorOkBtn"
		okb.text = "Apply"
		okb.focus_mode = Control.FOCUS_NONE
		okb.pressed.connect(func() -> void:
			_color_dialog.hide()
			set_body_color(_color_target, _color_picker.color))
		box.add_child(okb)
		add_child(_color_dialog)
	_color_picker.color = Color(body_color.r, body_color.g, body_color.b) \
		if body_color.a > 0.0 else Color(0.62, 0.66, 0.72)
	_color_dialog.popup_centered()


func set_body_color(body_id: String, c: Color) -> String:
	var f := doc.feature_by_id(body_id)
	if not (f is SolidFeature or f is CopyBodyFeature):
		return "no colorable feature roots body %s" % body_id
	stack.push_no_merge(CmdSetFeatureFlag.new(body_id, "color",
		Color(c.r, c.g, c.b, 1.0)))
	return ""


## --- SVG import (M31) --------------------------------------------------------

var _svg_import_dialog: FileDialog = null
var _svg_import_plane: OptionButton = null
var _svg_import_width: LineEdit = null
var _svg_import_wlab: Label = null
var _svg_import_dpi: LineEdit = null


## Import an SVG as a NEW sketch on `plane`. `width_mm` > 0 rescales the
## whole drawing uniformly to that overall width. `dpi` > 0 reinterprets a
## UNITLESS file's pixels at that density instead of the CSS default of 96
## (files with a physical width/height ignore it). Returns the feature id.
func import_svg(path: String, plane := "XY", width_mm := 0.0,
		dpi := 0.0) -> String:
	if not SketchFeature.PLANES.has(plane) and doc.plane_feature(plane) == null:
		set_status_hint("Import SVG: unknown plane %s" % plane)
		return ""
	if not FileAccess.file_exists(path):
		set_status_hint("Import SVG: no such file: " + path)
		return ""
	var parsed := SvgImporter.parse(FileAccess.get_file_as_string(path))
	if not bool(parsed["ok"]):
		set_status_hint("Import SVG failed: " + String(parsed["error"]))
		return ""
	var ents: Array = parsed["ents"]
	if dpi > 0.0 and not bool(parsed.get("physical", false)) \
			and absf(dpi - 96.0) > 1e-6:
		# Parsing assumed CSS's 96 px/in; rescale to the requested density.
		_svg_scale_ents(ents, 96.0 / dpi)
		parsed["size"] = (parsed["size"] as Vector2) * (96.0 / dpi)
	if width_mm > 0.0:
		var natural := (parsed["size"] as Vector2).x
		if natural <= 0.0:
			natural = _svg_bounds_width(ents)
		if natural > 0.0:
			_svg_scale_ents(ents, width_mm / natural)
	var sf := SketchFeature.make(doc.auto_name("Sketch"), plane)
	sf.id = doc.next_feature_id()
	var census := SvgImporter.populate(sf.sketch, ents)
	stack.push_no_merge(CmdAddFeature.new(sf))
	var msg := "Imported %d lines, %d arcs, %d circles, %d splines into %s" \
		% [census["lines"], census["arcs"], census["circles"],
		census["splines"], sf.name]
	if int(parsed["skipped"]) > 0:
		msg += " (%d unsupported elements skipped)" % int(parsed["skipped"])
	set_status_hint(msg)
	return sf.id


static func _svg_scale_ents(ents: Array, s: float) -> void:
	for ent: Dictionary in ents:
		for k in ["a", "b", "c", "from", "to"]:
			if ent.has(k):
				ent[k] = (ent[k] as Vector2) * s
		if ent.has("r"):
			ent["r"] = float(ent["r"]) * s
		if ent.has("pts"):
			var pts: Array = ent["pts"]
			for i in pts.size():
				pts[i] = (pts[i] as Vector2) * s


static func _svg_bounds_width(ents: Array) -> float:
	var lo := INF
	var hi := -INF
	for ent: Dictionary in ents:
		for k in ["a", "b", "from", "to"]:
			if ent.has(k):
				lo = minf(lo, (ent[k] as Vector2).x)
				hi = maxf(hi, (ent[k] as Vector2).x)
		if ent.has("c"):
			lo = minf(lo, (ent["c"] as Vector2).x - float(ent.get("r", 0.0)))
			hi = maxf(hi, (ent["c"] as Vector2).x + float(ent.get("r", 0.0)))
		for p in ent.get("pts", []):
			lo = minf(lo, (p as Vector2).x)
			hi = maxf(hi, (p as Vector2).x)
	return hi - lo if hi > lo else 0.0


func import_svg_interactive() -> void:
	if _svg_import_dialog == null:
		_svg_import_dialog = FileDialog.new()
		_svg_import_dialog.name = "SvgImportDialog"
		_svg_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_svg_import_dialog.filters = ["*.svg ; SVG drawings"]
		_svg_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_svg_import_dialog.size = Vector2i(640, 460)
		_svg_import_dialog.file_selected.connect(
			func(path: String) -> void:
				var w := UnitConverter.parse(_svg_import_width.text,
					doc.display_unit)
				var dpi_txt := _svg_import_dpi.text.strip_edges()
				import_svg(path, String(_svg_import_plane.get_item_metadata(
					_svg_import_plane.selected)),
					float(w["mm"]) if w["ok"] else 0.0,
					dpi_txt.to_float() if dpi_txt.is_valid_float() else 0.0))
		var prow := HBoxContainer.new()
		var plab := Label.new()
		plab.text = "Sketch plane:"
		prow.add_child(plab)
		_svg_import_plane = OptionButton.new()
		_svg_import_plane.name = "SvgImportPlanePick"
		_svg_import_plane.focus_mode = Control.FOCUS_NONE
		prow.add_child(_svg_import_plane)
		# Overall width in the display unit (suffixes like "40mm" work too).
		_svg_import_wlab = Label.new()
		prow.add_child(_svg_import_wlab)
		_svg_import_width = LineEdit.new()
		_svg_import_width.name = "SvgImportWidthEdit"
		_svg_import_width.placeholder_text = "native"
		_svg_import_width.custom_minimum_size = Vector2(90, 0)
		_svg_import_width.tooltip_text = ("Scale the drawing to this overall "
			+ "width (display unit; suffixes like 40mm / 2in work)")
		prow.add_child(_svg_import_width)
		# DPI: how to read a unitless file's pixels (CSS default is 96).
		var dlab := Label.new()
		dlab.text = "  DPI:"
		prow.add_child(dlab)
		_svg_import_dpi = LineEdit.new()
		_svg_import_dpi.name = "SvgImportDpiEdit"
		_svg_import_dpi.placeholder_text = "96"
		_svg_import_dpi.custom_minimum_size = Vector2(60, 0)
		_svg_import_dpi.tooltip_text = ("Pixel density for files with no "
			+ "physical size (width in mm/in ignores this)")
		prow.add_child(_svg_import_dpi)
		_svg_import_dialog.get_vbox().add_child(prow)
		add_child(_svg_import_dialog)
	_svg_import_wlab.text = "  Width (%s):" \
		% UnitConverter.suffix(doc.display_unit).strip_edges()
	var prev := ""
	if _svg_import_plane.selected >= 0:
		prev = String(_svg_import_plane.get_item_metadata(
			_svg_import_plane.selected))
	_svg_import_plane.clear()
	for plane_name: String in SketchFeature.PLANES:
		_svg_import_plane.add_item(plane_name)
		_svg_import_plane.set_item_metadata(
			_svg_import_plane.item_count - 1, plane_name)
	for f in doc.live_features():
		if f is PlaneFeature:
			_svg_import_plane.add_item((f as PlaneFeature).name)
			_svg_import_plane.set_item_metadata(
				_svg_import_plane.item_count - 1, f.id)
	_svg_import_plane.selected = 0
	for i in _svg_import_plane.item_count:
		if String(_svg_import_plane.get_item_metadata(i)) == prev:
			_svg_import_plane.selected = i
			break
	_svg_import_dialog.popup_centered()


## --- STL export (M24) ----------------------------------------------------------

var _stl_dialog: FileDialog
var _stl_ascii_chk: CheckBox = null
var _stl_unit_pick: OptionButton = null
## Body chosen when the dialog opened ("" = every visible body), so a
## selection change while the file dialog is up cannot swap the target.
var _stl_export_body := ""


## The bodies an STL export would write: one named body, or every body the
## browser has visible. Reads the world's built body list (exact meshes for
## plain solids, CSG bakes for booleans).
func _stl_bodies(body_id: String) -> Array:
	var out: Array = []
	for b: Dictionary in world.bodies():
		if body_id != "" and String(b["id"]) != body_id:
			continue
		if body_id == "" and not world.body_shown(String(b["id"])):
			continue
		out.append(b)
	return out


## Open the STL save dialog for one body, or for all visible bodies ("").
## Called by the toolbar button and the browser's body context menu.
func export_stl_interactive(body_id := "") -> void:
	if _stl_bodies(body_id).is_empty():
		set_status_hint("Export STL: no solid bodies to export")
		return
	_stl_export_body = body_id
	if _stl_dialog == null:
		_stl_dialog = FileDialog.new()
		_stl_dialog.name = "StlFileDialog"
		_stl_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_stl_dialog.filters = ["*.stl ; STL meshes"]
		_stl_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_stl_dialog.size = Vector2i(640, 440)
		_stl_dialog.file_selected.connect(
			func(path: String) -> void:
				export_stl(path, _stl_export_body,
					_stl_ascii_chk.button_pressed,
					0.001 if _stl_unit_pick.selected == 1 else 1.0))
		# Binary is the slicer default; ASCII rides as an option for
		# diffable/debuggable output.
		_stl_ascii_chk = CheckBox.new()
		_stl_ascii_chk.name = "StlAsciiChk"
		_stl_ascii_chk.text = "ASCII STL (text, larger)"
		_stl_ascii_chk.button_pressed = false
		_stl_dialog.get_vbox().add_child(_stl_ascii_chk)
		# STL carries no units. Slicers assume 1 unit = 1 mm (the default
		# here); Blender maps 1 unit = 1 m, so an "mm" file lands 1000x too
		# big there (QA §M24.3) — the metres option scales for it.
		var urow := HBoxContainer.new()
		var ulab := Label.new()
		ulab.text = "Units:"
		urow.add_child(ulab)
		_stl_unit_pick = OptionButton.new()
		_stl_unit_pick.name = "StlUnitPick"
		_stl_unit_pick.add_item("millimetres (slicers)", 0)
		_stl_unit_pick.add_item("metres (Blender)", 1)
		_stl_unit_pick.selected = 0
		_stl_unit_pick.focus_mode = Control.FOCUS_NONE
		urow.add_child(_stl_unit_pick)
		_stl_dialog.get_vbox().add_child(urow)
		add_child(_stl_dialog)
	_stl_dialog.current_file = "export.stl"
	_stl_dialog.popup_centered()


## Write the STL. `scale` multiplies coordinates on the way out (1.0 = mm,
## 0.001 = metres for Blender). Returns true on success (status bar reports
## either way).
func export_stl(path: String, body_id := "", ascii := false,
		scale := 1.0) -> bool:
	if not path.to_lower().ends_with(".stl"):
		path += ".stl"
	var res := StlExporter.write(_stl_bodies(body_id), path, ascii, scale)
	if not bool(res["ok"]):
		set_status_hint("Export STL failed: " + String(res["error"]))
		return false
	set_status_hint("Exported %d triangles (%s) to %s"
		% [int(res["triangles"]),
		"mm" if absf(scale - 1.0) < 1e-12 else "m", path])
	return true


## --- DXF export (M21) ----------------------------------------------------------

var _dxf_dialog: FileDialog
var _dxf_include_cons: CheckBox = null
## Sketch feature chosen when the export dialog opened, so a selection
## change while the file dialog is up cannot swap the target underneath it.
var _dxf_export_id := ""


## The sketch feature a DXF export would write when none is named: the
## active one in sketch mode, the browser-selected one, or the document's
## ONLY sketch. Null = ambiguous/none.
func _dxf_target_feature() -> SketchFeature:
	if mode == Mode.SKETCH and active_sketch_id != "":
		return doc.sketch_feature(active_sketch_id)
	if browser != null:
		var bid := browser.selected_sketch_id()
		if bid != "":
			return doc.sketch_feature(bid)
	var only: SketchFeature = null
	for f in doc.features:
		if f is SketchFeature:
			if only != null:
				return null
			only = f as SketchFeature
	return only


## Compat shim for callers that want the Sketch itself (automation).
func _dxf_target_sketch() -> Sketch:
	var sf := _dxf_target_feature()
	return sf.sketch if sf != null else null


## Open the export file dialog for `target_id`, or for the resolved target
## (active / browser-selected / only sketch) when "". Called by the toolbar
## button and the browser's right-click menu.
func export_dxf_interactive(target_id := "") -> void:
	if target_id == "":
		var sf := _dxf_target_feature()
		if sf == null:
			set_status_hint("Export DXF: select the sketch in the browser "
				+ "(or open it) first — the document has more than one.")
			return
		target_id = sf.id
	_dxf_export_id = target_id
	if _dxf_dialog == null:
		_dxf_dialog = FileDialog.new()
		_dxf_dialog.name = "DxfFileDialog"
		_dxf_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dxf_dialog.filters = ["*.dxf ; DXF drawings"]
		_dxf_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_dxf_dialog.size = Vector2i(640, 440)
		_dxf_dialog.file_selected.connect(
			func(path: String) -> void: export_dxf(path))
		# Export option rides inside the file dialog (M21 QA request):
		# construction geometry in or out, remembered between exports.
		_dxf_include_cons = CheckBox.new()
		_dxf_include_cons.name = "DxfConstructionChk"
		_dxf_include_cons.text = "Include construction geometry (CONSTRUCTION layer)"
		_dxf_include_cons.button_pressed = true
		_dxf_dialog.get_vbox().add_child(_dxf_include_cons)
		add_child(_dxf_dialog)
	var named := doc.sketch_feature(target_id)
	_dxf_dialog.title = "Export DXF — %s" % (named.name if named != null else "?")
	_dxf_dialog.popup_centered()


## Write a sketch to `path` (.dxf appended if missing): the one the dialog
## was opened for, else the resolved target. True on success; the status
## bar reports either way.
func export_dxf(path: String) -> bool:
	var sf := doc.sketch_feature(_dxf_export_id) if _dxf_export_id != "" \
		else _dxf_target_feature()
	_dxf_export_id = ""
	if sf == null:
		set_status_hint("DXF export: no unambiguous sketch to export")
		return false
	if not path.to_lower().ends_with(".dxf"):
		path += ".dxf"
	var include_cons: bool = _dxf_include_cons == null \
		or _dxf_include_cons.button_pressed
	var why := DxfExporter.save(sf.sketch, path, include_cons)
	set_status_hint(("Exported " + path) if why == ""
		else ("DXF export failed: " + why))
	return why == ""


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
	# The canvas hides but stays the ONE mapping: it projects through the 3D
	# camera, so tools keep working off-axis and geometry lands on the
	# ORIGINAL sketch plane (Fusion's workflow — M14 QA).
	var feat := doc.sketch_feature(active_sketch_id)
	if feat != null:
		sketch_view.set_projection_3d(rig.camera, feat.plane_transform())
	# The in-edit sketch gets the same 3D line-mesh treatment as every other
	# live sketch — the world's meshes may be stale mid-edit, so rebuild now.
	world.rebuild_sketches(doc)
	# Off-axis the sketch follows the model-mode projection preference:
	# an ortho user stays ortho while orbiting (CHANGES #3); otherwise
	# perspective with the apparent size preserved.
	if ThemeService.model_ortho:
		rig.set_projection_ortho(true)
	else:
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
	var xf := feat.plane_transform()
	var pan := sketch_view.pan()
	rig.frame_view(xf.basis.z, xf.basis.y, xf * Vector3(pan.x, pan.y, 0.0),
		rig.distance)
	_after_camera_move(func() -> void:
		if mode != Mode.SKETCH:
			return
		sketch_orbit = false
		sketch_view.clear_projection_3d()
		sketch_view.visible = true
		sketch_view.grab_focus()
		# Ortho + exact registration with the canvas, as on sketch entry.
		_sync_camera_to_sketch_view()
		_refresh_ui())
	_refresh_ui()


## Home = the standard 3/4 view (front-right-top), Z up — the same pose the
## app starts in (OrbitCamera.HOME_YAW / HOME_PITCH).
func go_home_view() -> void:
	if mode == Mode.SKETCH and not sketch_orbit:
		return
	rig.frame_home()


## View-cube navigation widgets: quarter-turn steps around the model, or home.
func _on_cube_nav(kind: String) -> void:
	if mode == Mode.SKETCH and not sketch_orbit:
		return   # square-on sketch editing owns the camera
	match kind:
		"home":
			go_home_view()
		"left":
			rig.step_view(PI / 2.0, 0.0)
		"right":
			rig.step_view(-PI / 2.0, 0.0)
		"up":
			rig.step_view(0.0, PI / 2.0)
		"down":
			rig.step_view(0.0, -PI / 2.0)


func _on_cube_face(normal: Vector3, up: Vector3) -> void:
	if mode == Mode.MODEL:
		rig.frame_view(normal, up)
	elif sketch_orbit:
		# The active plane's own face is the way home; any other face just
		# reorients the off-axis view.
		var feat := doc.sketch_feature(active_sketch_id)
		if feat != null \
				and normal.dot(feat.plane_transform().basis.z) > 0.999:
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
			# Off-axis sketching: clicks ray-cast onto the sketch plane and
			# feed the active tool exactly as locked-2D clicks do.
			if mb.button_index == MOUSE_BUTTON_LEFT:
				_on_tool_input(sketch_view.screen_to_world(mb.position),
					mb.position, mb)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_look_at:
			var rayl := rig.pixel_ray(mb.position)
			var lplane := world.pick_plane(rayl[0], rayl[1])
			if lplane != "":
				picking_look_at = false
				world.set_plane_hover("")
				world.set_planes_visible(false)
				var xf := _plane_transform_for(lplane)
				look_at_normal(xf.basis.z, xf.basis.y)
				_refresh_ui()
			else:
				var lface := world.pick_face(rayl[0], rayl[1])
				if not lface.is_empty():
					picking_look_at = false
					world.clear_face_hover()
					world.set_planes_visible(false)
					look_at_normal(lface["normal"])
					_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_mirror_plane:
			var raym2 := rig.pixel_ray(mb.position)
			var mplane := world.pick_plane(raym2[0], raym2[1])
			if mplane != "":
				picking_mirror_plane = false
				world.set_plane_hover("")
				world.set_planes_visible(false)
				mirror_body(_mirror_source, mplane)
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_plane:
			var ray := rig.pixel_ray(mb.position)
			var plane := world.pick_plane(ray[0], ray[1])
			if plane != "":
				world.clear_face_hover()
				create_sketch(plane)
			else:
				# No quad under the click — a flat body face will do (M22):
				# mint a snapshot plane on it and sketch there.
				var face := world.pick_face(ray[0], ray[1])
				if not face.is_empty():
					world.clear_face_hover()
					create_sketch_on_face(face["point"], face["normal"])
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_offset_base:
			var rayo := rig.pixel_ray(mb.position)
			var base := world.pick_plane(rayo[0], rayo[1])
			if base != "":
				picking_offset_base = false
				world.set_plane_hover("")
				world.set_planes_visible(false)
				_open_plane_dialog(base, "")
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_profile:
			var ray2 := rig.pixel_ray(mb.position)
			var hit := _profile_under_ray(ray2[0], ray2[1])
			if not hit.is_empty():
				picking_profile = false
				_pending_extrude = hit
				_open_extrude_dialog()
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_sweep_profile:
			var rays := rig.pixel_ray(mb.position)
			var shit := _profile_under_ray(rays[0], rays[1])
			if not shit.is_empty():
				picking_sweep_profile = false
				picking_sweep_path = true
				_pending_sweep = shit
				world.clear_profile_hover()
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_sweep_path:
			var rayp2 := rig.pixel_ray(mb.position)
			var cand := _sweep_path_under_ray(rayp2[0], rayp2[1])
			if not cand.is_empty():
				picking_sweep_path = false
				_pending_sweep["path_sketch"] = cand["sketch_id"]
				_pending_sweep["path_entity"] = cand["entity_id"]
				world.clear_axis_hover()
				_open_sweep_dialog()
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_loft:
			var rayl := rig.pixel_ray(mb.position)
			var lhit := _profile_under_ray(rayl[0], rayl[1])
			if not lhit.is_empty():
				_loft_sections.append({"sketch": lhit["sketch_id"],
					"at": lhit["at"]})
				if _loft_count != null:
					_loft_count.text = "Sections: %d (click profiles)" \
						% _loft_sections.size()
				_show_loft_section_marks()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and picking_revolve:
			var rayr := rig.pixel_ray(mb.position)
			var rhit := _profile_under_ray(rayr[0], rayr[1])
			if not rhit.is_empty():
				picking_revolve = false
				picking_revolve_axis = true
				_pending_revolve = rhit
				world.show_axis_candidates(
					doc.sketch_feature(String(rhit["sketch_id"])))
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_revolve_axis:
			var raya := rig.pixel_ray(mb.position)
			var apick := _axis_pick_under_ray(raya[0], raya[1])
			if not apick.is_empty():
				_revolve_axis = String(apick["axis"])
				picking_revolve_axis = false
				world.clear_profile_hover()
				world.clear_axis_hover()
				world.hide_axis_candidates()
				_open_revolve_dialog()
				_refresh_ui()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_treat_edges:
			var rayt := rig.pixel_ray(mb.position)
			var tkey := _treat_edge_under_ray(rayt[0], rayt[1])
			if tkey != "":
				# A click toggles the whole smooth chain (one segment on a
				# box; the full rim on a cylinder — QA §M35.4).
				var ckeys := _treat_chain_keys(tkey)
				var all_sel := true
				for ck in ckeys:
					if not _treat_selected.has(ck):
						all_sel = false
						break
				for ck in ckeys:
					if all_sel:
						_treat_selected.erase(ck)
					else:
						_treat_selected[ck] = true
				world.show_treat_edges(_treat_pick_edges, _treat_selected,
					_axis_hover_width_mm())
				_update_treat_pick_count()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and picking_body:
			var rayb := rig.pixel_ray(mb.position)
			var bid := world.pick_body(rayb[0], rayb[1])
			if bid == "":
				set_status_hint("%s: click a body (Esc to cancel)" % _body_pick_label)
			else:
				var then := _body_pick_then
				_end_body_pick()
				select_body(bid)
				if then.is_valid():
					then.call()
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
		elif nav_only:
			# Off-axis sketching: hover/preview motion reaches the tool too.
			_on_tool_input(sketch_view.screen_to_world(mm.position),
				mm.position, mm)
		elif picking_plane or picking_look_at or picking_mirror_plane:
			var ray := rig.pixel_ray(mm.position)
			var hov := world.pick_plane(ray[0], ray[1])
			world.set_plane_hover(hov)
			# A flat body face is a sketch target too (M22) — highlight it
			# whenever no plane quad is in the way.
			if hov == "":
				var face := world.pick_face(ray[0], ray[1])
				if face.is_empty():
					world.clear_face_hover()
				else:
					world.set_face_hover(String(face["body"]),
						face["point"], face["normal"])
			else:
				world.clear_face_hover()
		elif picking_offset_base:
			var rayb := rig.pixel_ray(mm.position)
			world.set_plane_hover(world.pick_plane(rayb[0], rayb[1]))
		elif picking_body:
			# Pre-highlight the body the click would take.
			var rayh := rig.pixel_ray(mm.position)
			world.set_body_hover(world.pick_body(rayh[0], rayh[1]))
		elif picking_profile or picking_revolve or picking_sweep_profile \
				or picking_loft:
			# Pre-highlight the region the click would take.
			var rayp := rig.pixel_ray(mm.position)
			var hitp := _profile_under_ray(rayp[0], rayp[1])
			if hitp.is_empty():
				world.clear_profile_hover()
			else:
				world.set_profile_hover(
					doc.sketch_feature(hitp["sketch_id"]), hitp["at"])
		elif picking_revolve_axis:
			# Pre-highlight the axis candidate the click would take (QA
			# §M23.6): line entities and the drawn sketch axes alike.
			var raym := rig.pixel_ray(mm.position)
			var cand := _axis_pick_under_ray(raym[0], raym[1])
			if cand.is_empty():
				world.clear_axis_hover()
			else:
				world.set_axis_hover(
					doc.sketch_feature(String(_pending_revolve["sketch_id"])),
					String(cand["axis"]), cand["a"] as Vector2,
					cand["b"] as Vector2, _axis_hover_width_mm())
		elif picking_sweep_path:
			# Pre-highlight the path curve the click would take (hover
			# feedback is mandatory on every pick stage — see CLAUDE.md).
			var rayc := rig.pixel_ray(mm.position)
			var candc := _sweep_path_under_ray(rayc[0], rayc[1])
			if candc.is_empty():
				world.clear_axis_hover()
			else:
				var sfc := doc.sketch_feature(String(candc["sketch_id"]))
				world.set_curve_hover(sfc, String(candc["entity_id"]),
					SketchGeometry.entity_polyline(sfc.sketch,
						sfc.sketch.entity(String(candc["entity_id"]))),
					_axis_hover_width_mm())
		elif picking_treat_edges:
			# Pre-highlight the edge the click would toggle.
			var raye := rig.pixel_ray(mm.position)
			world.set_treat_edge_hover(_treat_edge_under_ray(raye[0], raye[1]),
				_treat_pick_edges, _axis_hover_width_mm())


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
	# Axis shortcut while revolve waits for one: X/Y pick the sketch axes.
	if picking_revolve_axis and not k.ctrl_pressed \
			and (k.keycode == KEY_X or k.keycode == KEY_Y):
		_revolve_axis = RevolveFeature.AXIS_X if k.keycode == KEY_X \
			else RevolveFeature.AXIS_Y
		picking_revolve_axis = false
		world.clear_profile_hover()
		world.clear_axis_hover()
		world.hide_axis_candidates()
		_open_revolve_dialog()
		_refresh_ui()
		return true
	if k.keycode == KEY_ESCAPE:
		if picking_calibrate:
			picking_calibrate = false
			_calib_picks = []
			set_status_hint("Calibrate cancelled")
			return true
		if picking_treat_edges:
			_end_edge_treat_pick()
			set_status_hint("Fillet/Chamfer cancelled")
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
			# Nothing left for the tool to cancel: off-axis, Esc is the
			# other way home (same as the plane's view-cube face).
			if sketch_orbit:
				return_to_sketch_plane()
				return true
		if picking_body:
			_end_body_pick()
			set_status_hint("Cancelled")
			_refresh_ui()
			return true
		if picking_plane or picking_profile or picking_offset_base \
				or picking_revolve or picking_revolve_axis or picking_look_at \
				or picking_mirror_plane or picking_sweep_profile \
				or picking_sweep_path or picking_loft:
			picking_plane = false
			picking_profile = false
			picking_offset_base = false
			picking_revolve = false
			picking_revolve_axis = false
			picking_look_at = false
			picking_mirror_plane = false
			picking_sweep_profile = false
			picking_sweep_path = false
			if picking_loft or not _loft_sections.is_empty():
				picking_loft = false
				_loft_sections = []
				world.hide_loft_sections()
				if _loft_dialog != null:
					_loft_dialog.hide()
			_pending_revolve = {}
			_pending_sweep = {}
			world.set_plane_hover("")
			world.clear_profile_hover()
			world.clear_face_hover()
			world.clear_axis_hover()
			world.hide_axis_candidates()
			world.set_planes_visible(false)
			_refresh_ui()
			return true
		return false
	if (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and mode == Mode.SKETCH:
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
	if k.keycode == KEY_DELETE and mode == Mode.SKETCH:
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
	if mode == Mode.MODEL and not k.ctrl_pressed:
		# Model-mode view keys (M27). Guarded from sketch mode, where letters
		# belong to tools and type-in fields.
		if k.keycode == KEY_P:
			set_model_projection(not rig.is_orthographic())
			return true
		if k.keycode == KEY_F:
			fit_view()
			return true
	if mode == Mode.SKETCH and not k.ctrl_pressed:
		# Type-in fields get first claim on keys (digits, Tab, units...).
		var active := tools.get_tool(tools.active_id())
		if active != null and active.key_input(k):
			overlay.queue_redraw()
			return true
		# X: normal <-> construction toggle on the selection (Fusion's key).
		# After the type-in check so a value being typed never loses its 'x'.
		if k.keycode == KEY_X:
			toggle_construction()
			return true
		for tid: String in tools.tool_ids():
			if tools.get_tool(tid).shortcut == k.keycode:
				tools.set_active(tid)
				return true
	return false


## Flip the construction flag on every selected curve (X key). Points are
## skipped — construction has no meaning for a bare point here. The whole
## toggle is one undo step, and mixed selections normalize to the OPPOSITE
## of the first curve's state, so repeated presses flip cleanly.
## With NOTHING selected, X toggles construction MODE instead: geometry
## drawn from now on comes out construction — which is what makes X work
## in the middle of a line chain (the committed segments keep their state,
## the segments still to come flip).
func toggle_construction() -> void:
	var sk := active_sketch()
	if sk == null:
		return
	var targets := {}
	var to := false
	var first := true
	for id in selection:
		var e := sk.entity(id)
		if e == null or e.kind() == "point":
			continue
		if first:
			to = not e.construction
			first = false
		targets[id] = to
	if targets.is_empty():
		if not selection.is_empty():
			# A points-only selection: neither meaningful to convert nor a
			# clear "toggle the mode" intent — explain instead of guessing.
			set_status_hint("Construction toggle (X): select lines, arcs, "
				+ "or circles (points cannot be construction).")
			return
		construction_mode = not construction_mode
		if _construction_check != null:
			_construction_check.set_pressed_no_signal(construction_mode)
		set_status_hint(("Construction mode ON — new geometry draws dashed "
			+ "and is excluded from profiles. X (or the checkbox) turns it "
			+ "off.") if construction_mode else "Construction mode off.")
		return
	stack.push_no_merge(CmdSetConstruction.new(active_sketch_id, targets))
	set_status_hint(("Construction geometry (dashed, excluded from profiles)"
		if to else "Normal geometry") + " — X toggles back.")


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
		# Canvas calibration picks (M30) intercept clicks before tools.
		if picking_calibrate and mb.pressed \
				and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_calibrate_pick(world_pos)
			return true
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
	var xf := feat.plane_transform()
	# Square onto the plane. The fly-in leaves the camera here, but a
	# view-cube click or a stray orbit can leave it off-axis, and then the
	# model behind the canvas is a skewed projection that no longer lines up
	# with the 2D geometry drawn over it.
	var yp := OrbitCamera.yaw_pitch_for(xf.basis.z, xf.basis.y)
	rig.yaw = yp.x
	rig.pitch = yp.y
	# The sketch point at the panel centre, in world space.
	var pan := sketch_view.pan()
	rig.target = xf * Vector3(pan.x, pan.y, 0.0)
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
		world.update_grid(rig.view_height_mm(), rig.target)


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
			_draw_entity_outline(sk, he, COLOR_HOVER(), 3.0)
	# Point markers go ON TOP of the hover highlight: the highlight for a point
	# is a larger filled square behind it, so drawing the marker afterwards
	# leaves the point itself crisp with a halo around it. Drawing them the
	# other way round hid the halo completely under the 5 px marker, which is
	# why hovering a point appeared to do nothing at all.
	for e in sk.entities():
		if e.kind() == "point":
			var p := v.world_to_screen((e as SketchPoint).pos)
			var c := ThemeService.col("sk_point")
			if selection.has(e.id):
				c = ThemeService.col("sk_selected")
			elif constrained_pts.has(e.id):
				c = RenderBridge.color_constrained()
			overlay.draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5, 5)), c)
	for id in selection:
		var e := sk.entity(id)
		if e == null:
			continue
		_draw_entity_outline(sk, e, COLOR_SELECTED(), 2.0)
	# Badge satisfied/unsolved state is re-read only at REST: mid-gesture the
	# sub-solves leave transient residuals that made badges flash "unsolved"
	# during a healthy drag (QA §M17-5). Frozen alongside `dof`, which already
	# pauses for the same reason.
	if not live_gesture:
		_badge_unsolved = ConstraintOverlay.unsolved_set(sk)
	badge_hits = ConstraintOverlay.draw(overlay, v, sk, dof, selected_constraint,
		_badge_unsolved)
	dim_hits = DimensionOverlay.draw(overlay, v, sk, dof, selected_constraint,
		doc.display_unit)
	tools.draw_overlay(overlay)


## Trace an entity's outline in `c` at `w` px — the shared shape used for both
## the selection highlight and the hover pre-highlight, so the two can never
## disagree about where an entity is.
func _draw_entity_outline(sk: Sketch, e: SketchEntity, c: Color, w: float) -> void:
	var v := sketch_view
	# A CONSTRUCTION entity keeps its dashes even while highlighted — a solid
	# selection stroke used to paint right over them, so a selected
	# construction line was indistinguishable from a normal one (M21 QA).
	var dashed := e.construction
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
				if dashed:
					overlay.draw_dashed_line(v.world_to_screen(a.pos),
						v.world_to_screen(b.pos), c, w, 8.0)
				else:
					overlay.draw_line(v.world_to_screen(a.pos),
						v.world_to_screen(b.pos), c, w)
		"circle":
			var ci := e as SketchCircle
			var cp := sk.point(ci.center)
			if cp != null:
				_draw_arc_outline(v.world_to_screen(cp.pos),
					ci.radius * v.zoom(), 0.0, TAU, c, w, dashed)
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
				_draw_arc_outline(v.world_to_screen(cp.pos), rs,
					-a0, -(a0 + sweep), c, w, dashed)
		"spline":
			var poly := (e as SketchSpline).polyline(sk)
			for i in poly.size() - 1:
				if dashed:
					overlay.draw_dashed_line(v.world_to_screen(poly[i]),
						v.world_to_screen(poly[i + 1]), c, w, 8.0)
				else:
					overlay.draw_line(v.world_to_screen(poly[i]),
						v.world_to_screen(poly[i + 1]), c, w)


## draw_arc with an optional dashed rendering (there is no draw_dashed_arc):
## the sweep is chopped into ~8 px dashes with ~6 px gaps.
func _draw_arc_outline(center: Vector2, radius: float, from: float,
		to: float, c: Color, w: float, dashed: bool) -> void:
	if not dashed or radius < 1.0:
		overlay.draw_arc(center, radius, from, to, 48, c, w)
		return
	var arc_len := absf(to - from) * radius
	var dash_ang := 8.0 / radius
	var gap_ang := 6.0 / radius
	var dir := signf(to - from)
	var a := from
	var guard := int(ceil(arc_len / 8.0)) + 4
	while dir * (to - a) > 0.0 and guard > 0:
		guard -= 1
		var a2 := a + dir * dash_ang
		if dir * (to - a2) < 0.0:
			a2 = to
		overlay.draw_arc(center, radius, a, a2, 6, c, w)
		a = a2 + dir * gap_ang


## A gesture started/ended. Ending one runs the derived work its frames
## skipped (see `live_gesture`).
func set_live_gesture(on: bool) -> void:
	if live_gesture == on:
		return
	live_gesture = on
	if not on:
		var proj_msgs := Projector.refresh(doc)
		if not proj_msgs.is_empty():
			set_status_hint(proj_msgs[0])
		_refresh_dof()
		if mode == Mode.SKETCH:
			sketch_view.mark_dirty()
			world.rebuild_sketches(doc)   # 3D twin catches up with the drag
		overlay.queue_redraw()
		_refresh_ui()


func _on_stack_changed() -> void:
	# Projections are derived state: recompute them from their sources on
	# every SETTLED model change (edits, undo, redo, parameter changes), so
	# linked geometry follows its source and dead links break with a
	# message. Deferred while a drag streams changes — see `live_gesture`.
	if not live_gesture:
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
			if not live_gesture:
				_refresh_dof()
			sketch_view.mark_dirty()
			overlay.queue_redraw()
			# Off-axis the 3D line meshes ARE the sketch display, so undo/redo
			# must rebuild them just as model mode does. Square-on, the 3D
			# mesh of the active sketch still shows through the canvas, so a
			# stale one reads as a ghost of the pre-edit geometry (CHANGES #8)
			# — rebuild at every settled change; drags catch up on release.
			if sketch_orbit or not live_gesture:
				world.rebuild_sketches(doc)
	else:
		world.rebuild_sketches(doc)
	timeline.refresh()
	browser.refresh()
	_refresh_ui()


## Menu-bar chrome that tracks document state: file name + unsaved mark at
## the left, display unit at the right, operation count in the timeline.
## File stem of the open document ("Untitled" before the first save) — the
## root component's name in the browser and the menu bar's document label.
func document_title() -> String:
	return _save_path.get_file().get_basename() if _save_path != "" else "Untitled"


func _refresh_chrome_labels() -> void:
	if _doc_label != null:
		var fname := _save_path.get_file() if _save_path != "" else "untitled"
		var dirty := stack.can_undo()
		_doc_label.text = "—  %s%s" % [fname, "   ● unsaved" if dirty else ""]
	if _unit_badge != null:
		_unit_badge.text = "%s · %s" % [UnitConverter.suffix(doc.display_unit),
			"Sketch" if mode == Mode.SKETCH else "Design"]
	if _timeline_count != null:
		var n := doc.features.size()
		_timeline_count.text = "%d operation%s" % [n, "" if n == 1 else "s"]


func _refresh_ui() -> void:
	var in_sketch := mode == Mode.SKETCH
	# M36 ribbon: the model row and the sketch row swap with the mode.
	_model_ribbon.visible = not in_sketch
	_tool_bar.visible = in_sketch
	request_ribbon_layout()
	if in_sketch and not dof.is_empty():
		var sk := active_sketch()
		_status_dof.text = DofAnalyzer.summary(sk) if sk != null else ""
	else:
		_status_dof.text = ""
	# Fully constrained reads as a success badge, anything else as a hint.
	if _status_dof.text.begins_with("Fully"):
		_status_dof.add_theme_color_override("font_color", ThemeService.col("success"))
	else:
		_status_dof.remove_theme_color_override("font_color")
	for tid: String in _tool_buttons:
		(_tool_buttons[tid] as Button).set_pressed_no_signal(
			tid == tools.active_id())
	var ct := tools.get_tool("constraint") as ConstraintTool
	for t in _con_buttons:
		(_con_buttons[t] as Button).set_pressed_no_signal(
			tools.active_id() == "constraint" and ct != null and ct.type == t)
	# A stack's face follows whichever of its tools is active (keyboard
	# shortcuts and RPC reach variants the face is not showing).
	var active_stack := _stack_for_tool(tools.active_id())
	for st: Dictionary in _stacks:
		if st == active_stack:
			_stack_show(st, tools.active_id())
		(st["btn"] as Button).set_pressed_no_signal(st == active_stack)
	_btn_undo.disabled = not stack.can_undo()
	_btn_redo.disabled = not stack.can_redo()
	_status_mode.text = "SKETCH" if in_sketch else "MODEL"
	_refresh_chrome_labels()
	_btn_ortho.disabled = in_sketch
	if not in_sketch:
		_btn_ortho.set_pressed_no_signal(rig.is_orthographic())
	if _status_measure != null and not in_sketch:
		_status_measure.text = ""
	if _status_ids != null and not in_sketch:
		_status_ids.text = ""
	if picking_look_at:
		_status_hint.text = ("Look At: select a plane or a flat body face "
			+ "(Esc to cancel)")
	elif picking_body:
		_status_hint.text = "%s: click a body (Esc to cancel)" % _body_pick_label
	elif picking_mirror_plane:
		_status_hint.text = "Mirror: select the mirror plane (Esc to cancel)"
	elif picking_sweep_profile:
		_status_hint.text = "Sweep: select the profile to sweep (Esc to cancel)"
	elif picking_sweep_path:
		_status_hint.text = ("Sweep: click the PATH — a line/arc/spline "
			+ "chain in another sketch (Esc to cancel)")
	elif picking_loft:
		_status_hint.text = ("Loft: click 2+ profiles in order, then OK in "
			+ "the dialog (Esc to cancel)")
	elif picking_treat_edges:
		_status_hint.text = (("Fillet" if _treat_kind
			== EdgeTreatFeature.KIND_FILLET else "Chamfer")
			+ ": click edges to select — smooth runs (a cylinder rim) select "
			+ "as one chain, click again to deselect — then Apply "
			+ "(Esc to cancel)")
	elif picking_plane:
		_status_hint.text = "Select a plane or a flat body face (Esc to cancel)"
	elif picking_offset_base:
		_status_hint.text = "Select the plane to offset from (Esc to cancel)"
	elif picking_profile:
		_status_hint.text = "Select a closed profile (Esc to cancel)"
	elif picking_revolve:
		_status_hint.text = "Select the profile to revolve (Esc to cancel)"
	elif picking_revolve_axis:
		_status_hint.text = ("Select the axis: click a sketch line or one of "
			+ "the drawn sketch axes, or press X / Y (Esc to cancel)")
	elif in_sketch and sketch_orbit:
		var fo := doc.sketch_feature(active_sketch_id)
		_status_hint.text = ("Off-axis — sketching continues on %s; click its "
			+ "view-cube face (or press Esc) to square up") \
			% (fo.plane_label() if fo != null else "the plane")
	elif in_sketch:
		var f := doc.sketch_feature(active_sketch_id)
		_status_hint.text = "%s on %s" % [f.name, f.plane_label()] \
			if f != null else ""
	else:
		_status_hint.text = ""
	_status_zoom.text = "%d%%" % roundi(sketch_view.zoom() * 25.0) if in_sketch else ""
