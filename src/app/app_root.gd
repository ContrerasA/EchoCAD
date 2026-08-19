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
var _tool_bar: HFlowContainer
## Snap/inference toggles — kept so RPC-driven pref changes can refresh them.
var _snap_check: CheckBox = null
var _infer_check: CheckBox = null
var _construction_check: CheckBox = null
## While true, drawing tools mint CONSTRUCTION curves (Fusion's sticky
## construction toggle). See stamp_construction in the tool base.
var construction_mode := false
var _constraint_bar: HFlowContainer
var _tool_buttons := {}
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
	threaded_solver = ThreadedSolver.new()
	threaded_solver.name = "ThreadedSolver"
	add_child(threaded_solver)
	_build_ui()
	_refresh_ui()
	_maybe_start_automation()
	get_window().title = "EchoCAD — build " + BUILD


## Drives the active tool's per-frame tick. Tools are RefCounted and have no
## _process of their own, and gestures that must not run faster than the
## display (drag re-solves) rely on this — see `SketchTool.tick`.
func _process(_dt: float) -> void:
	if mode == Mode.SKETCH:
		tools.handle_tick()
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
	_btn_revolve = _button(top, "Revolve", _on_revolve_pressed)
	_btn_revolve.name = "RevolveBtn"
	_btn_offset_plane = _button(top, "Offset Plane", _on_offset_plane_pressed)
	_btn_offset_plane.name = "OffsetPlaneBtn"
	var pbtn := _button(top, "Parameters", _open_params_dialog)
	pbtn.name = "ParametersBtn"
	_btn_finish = _button(top, "Finish Sketch", _on_finish_sketch)
	_btn_finish.name = "FinishSketchBtn"
	_btn_undo = _button(top, "Undo", func() -> void: stack.undo())
	_btn_undo.name = "UndoBtn"
	_btn_redo = _button(top, "Redo", func() -> void: stack.redo())
	_btn_redo.name = "RedoBtn"
	_btn_save = _button(top, "Save", func() -> void: save_interactive(false))
	_btn_save.name = "SaveBtn"
	var stlb := _button(top, "Export STL",
		func() -> void: export_stl_interactive())
	stlb.name = "ExportStlBtn"
	var dxfi := _button(top, "Import DXF", import_dxf_interactive)
	dxfi.name = "ImportDxfBtn"
	var dxfb := _button(top, "Export DXF", export_dxf_interactive)
	dxfb.name = "ExportDxfBtn"
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

	# Construction MODE: newly drawn curves come out as construction geometry
	# while this is on (M21 QA fix). X with nothing selected toggles it too,
	# so X mid-line-chain flips the segments still to come.
	var cons_box := CheckBox.new()
	cons_box.name = "ConstructionChk"
	cons_box.text = "Construction"
	cons_box.focus_mode = Control.FOCUS_NONE
	cons_box.button_pressed = construction_mode
	cons_box.toggled.connect(func(on: bool) -> void: construction_mode = on)
	_tool_bar.add_child(cons_box)
	_construction_check = cons_box

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
		world.update_grid(rig.view_height_mm())
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
	# Boolean bakes land a frame after the model change — re-list bodies when
	# they do, or the browser shows stale rows (deferred: the rebuild can be
	# triggered from inside a Tree mouse callback, where refresh must not run).
	world.bodies_rebuilt.connect(func() -> void:
		browser.refresh.call_deferred())
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
	picking_offset_base = false
	world.clear_face_hover()
	world.set_plane_hover("")
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
	var xf := feat.plane_transform()
	world.set_grid_plane(feat.plane, xf)
	world.set_grid_unit(doc.display_unit)
	rig.frame_view(xf.basis.z, xf.basis.y, xf.origin, 500.0)
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
	sketch_view.clear_projection_3d()
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
		elif picking_plane:
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
		elif picking_profile or picking_revolve:
			# Pre-highlight the region the click would extrude/revolve.
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
		if picking_plane or picking_profile or picking_offset_base \
				or picking_revolve or picking_revolve_axis:
			picking_plane = false
			picking_profile = false
			picking_offset_base = false
			picking_revolve = false
			picking_revolve_axis = false
			_pending_revolve = {}
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
		world.update_grid(rig.view_height_mm())


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
	_btn_revolve.visible = not in_sketch
	_btn_offset_plane.visible = not in_sketch
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
