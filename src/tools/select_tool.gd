class_name SelectTool
extends SketchTool
## Minimal M4 select tool: click selects the topmost entity (Ctrl toggles),
## dragging a point moves it, dragging a line moves both endpoints. Moves
## merge into one undo step per drag. Constraint re-solve arrives with M6/M7.

const HIT_PX := 6.0
const DEADZONE_PX := 4.0

enum Drag { NONE, PENDING, MOVE }

var _drag := Drag.NONE
var _down_world := Vector2.ZERO
var _down_screen := Vector2.ZERO
var _move_points: Array[String] = []   # point entity ids being dragged
var _start := {}                       # id -> Vector2 at drag start
var _batch: CmdMergeBatch = null       # one undo step: drag + re-solve
var _label_drag := -1                  # dimension index whose label is dragged
var _label_start := Vector2.ZERO       # label_offset at drag start
var _label_down := Vector2.ZERO        # world pos at drag start
var _dim_fields := DimFields.new(["Value"])   # edit box for selected dimension
## Coalesced drag state: pointer_move records where the drag wants to be and
## `tick` applies it once per frame. See pointer_move for why.
var _pending := false
var _pending_world := Vector2.ZERO


func _init() -> void:
	id = "select"
	title = "Select"
	shortcut = KEY_V


func deactivate() -> void:
	_drag = Drag.NONE
	_pending = false
	clear_hover()


func cancel() -> bool:
	if _drag != Drag.NONE:
		_drag = Drag.NONE
		return true
	if app.selected_constraint >= 0:
		app.selected_constraint = -1
		app.overlay.queue_redraw()
		return true
	if not app.selection.is_empty():
		app.set_selection([])
		return true
	return false


func pointer_down(world: Vector2, screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	# Dimension labels and constraint badges sit above geometry.
	for h: Dictionary in app.dim_hits:
		if (h["rect"] as Rect2).has_point(screen):
			app.set_selection([])
			app.selected_constraint = int(h["index"])
			_dim_fields.reset()
			_label_drag = int(h["index"])
			_label_down = world
			_label_start = sketch().constraints[_label_drag].label_offset
			app.overlay.queue_redraw()
			return true
	for h: Dictionary in app.badge_hits:
		if (h["rect"] as Rect2).has_point(screen):
			app.set_selection([])
			app.selected_constraint = int(h["index"])
			app.overlay.queue_redraw()
			return true
	var sk := sketch()
	var hit := SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	if hit == "":
		if not e.ctrl_pressed:
			app.set_selection([])
		return true
	# Shift adds to the selection as well as Ctrl. Ctrl-click is the CAD
	# convention and Shift-click is the everything-else convention; users reach
	# for whichever their hands know, and there is no reason to accept only one.
	if e.ctrl_pressed or e.shift_pressed:
		var sel := app.selection.duplicate()
		if sel.has(hit):
			sel.erase(hit)
		else:
			sel.append(hit)
		app.set_selection(sel)
	elif not app.selection.has(hit):
		app.set_selection([hit])
	# Arm a potential drag with the points this hit controls.
	_move_points.clear()
	_start.clear()
	var ent := sk.entity(hit)
	var refs: Array[String] = []
	if ent.kind() == "point":
		refs = [ent.id]
	else:
		refs = ent.point_refs()
	for pid in refs:
		var p := sk.point(pid)
		if p != null:
			_move_points.append(pid)
			_start[pid] = p.pos
	_down_world = world
	_down_screen = screen
	# A FULLY CONSTRAINED point cannot be dragged — its position is already
	# determined, so there is nothing left for a drag to decide. Fusion refuses
	# the gesture outright, and it has to: allowing it means the drag and the
	# dimensions each demand a different position, the solver is handed a system
	# with no solution, and the sketch ends up mangled and reading "Conflicting
	# constraints" when the user did nothing wrong. Refusing keeps the drawing
	# intact and puts the reason in the status bar.
	if not _move_points.is_empty() and _all_constrained(_move_points):
		app.set_status_hint("Fully constrained — remove or edit a dimension to "
			+ "move this. (Drag refused so the sketch is not broken.)")
		_drag = Drag.NONE
		return true
	_drag = Drag.PENDING if not _move_points.is_empty() else Drag.NONE
	return true


## Are ALL of these points determined by the current constraints? Read from the
## DOF analysis the status bar already shows, so what blocks a drag is exactly
## what the user was told is fully constrained.
func _all_constrained(pids: Array) -> bool:
	var determined: Array = app.dof.get("constrained_points", [])
	if determined.is_empty():
		return false
	for pid in pids:
		if not determined.has(pid):
			return false
	return true


func pointer_move(world: Vector2, screen: Vector2, _e: InputEventMouseMotion) -> bool:
	# Pre-highlight what a click would pick, Fusion-style. Deliberately the
	# SAME hit test the click uses, so the highlight can never promise
	# something the click would not deliver. Skipped mid-drag, where the
	# cursor is committed to geometry it already grabbed.
	if _drag == Drag.NONE and _label_drag < 0:
		if update_hover(world, HIT_PX):
			app.overlay.queue_redraw()
	elif clear_hover():
		app.overlay.queue_redraw()
	if _label_drag >= 0:
		var sk := sketch()
		if _label_drag < sk.constraints.size():
			var edited := sk.constraints[_label_drag].duplicate_constraint()
			edited.label_offset = _label_start + (world - _label_down)
			var after: Array = sk.constraints.duplicate()
			after[_label_drag] = edited
			app.stack.push(CmdSetConstraints.new(app.active_sketch_id,
				sk.constraints, after))
		return true
	if _drag == Drag.PENDING \
			and screen.distance_to(_down_screen) > DEADZONE_PX:
		_drag = Drag.MOVE
		app.rebuild_snap_index(_moving_entity_ids())
		# The whole gesture — every move + every constraint re-solve — is
		# one sealed undo step.
		_batch = CmdMergeBatch.new("Drag", [])
		app.stack.push_no_merge(_batch)
	if _drag != Drag.MOVE:
		return false
	# Record the target and let _process apply it ONCE this frame. Motion
	# events arrive several times per displayed frame, and each one used to run
	# the whole pipeline: push a move command, which fires stack.changed, which
	# rebuilds the snap index, re-runs the DOF analysis and re-rasterizes the
	# canvas — then a full constraint solve (up to MAX_ROUNDS sweeps over every
	# constraint) on top. Everything but the last of those is overwritten
	# before it is ever seen, so it was pure heat: one core pegged and the CPU
	# ~20 °C hotter for a result identical to solving once per frame.
	_pending_world = world
	_pending = true
	return true


## Apply at most one drag update per frame — see `pointer_move`. The undo
## semantics are unchanged: every push still lands in the same sealed
## CmdMergeBatch, so the whole gesture remains one step.
func tick() -> void:
	if not _pending or _drag != Drag.MOVE:
		return
	_pending = false
	_apply_drag(_pending_world)


func _apply_drag(world: Vector2) -> void:
	var delta := world - _down_world
	# Snap the DRAGGED point (single-point drags) so moves land on targets.
	if _move_points.size() == 1:
		var tol := SnapEngine.TOL_PX / view().zoom()
		var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
		var target: Vector2 = (_start[_move_points[0]] as Vector2) + delta
		delta = app.snap.snap_point(target, tol, grid)["pos"] \
			- (_start[_move_points[0]] as Vector2)
	var targets := {}
	for pid in _move_points:
		targets[pid] = (_start[pid] as Vector2) + delta
	app.stack.push(CmdMovePoints.new(app.active_sketch_id, targets))
	# Mid-gesture the re-solve runs on the worker thread (M16) so a large
	# constrained sketch cannot stutter the drag; the final exact solve
	# happens synchronously in pointer_up before the batch seals.
	app.solve_followers_async(_move_points)


func pointer_up(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _label_drag >= 0:
		_label_drag = -1
		return true
	if _drag == Drag.MOVE:
		# Flush the last coalesced move BEFORE sealing, or the drag ends
		# wherever the final frame happened to land rather than where the
		# button came up.
		if _pending:
			_pending = false
			_apply_drag(_pending_world)
		# The gesture's LAST solve is synchronous: outstanding threaded work
		# is cancelled (its result would land after the batch seals) and the
		# exact final state is computed here, inside the batch.
		if app.threaded_solver != null:
			app.threaded_solver.cancel()
		app.solve_followers(_move_points)
		if _batch != null:
			_batch.seal()
			_batch = null
		app.rebuild_snap_index()
	_pending = false
	_drag = Drag.NONE
	return true


## Selected dimension: typing edits its value, Enter applies.
func key_input(e: InputEventKey) -> bool:
	var sk := sketch()
	if sk == null or app.selected_constraint < 0 \
			or app.selected_constraint >= sk.constraints.size():
		return false
	if not sk.constraints[app.selected_constraint].is_dimensional():
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		if _dim_fields.has_text(0):
			var batch := CmdMergeBatch.new("Edit Dimension", [])
			app.stack.push_no_merge(batch)
			app.set_dimension_value(app.selected_constraint, _dim_fields.texts[0])
			batch.seal()
			_dim_fields.reset()
		return true
	return _dim_fields.key_input(e)


func draw_overlay(overlay: Control) -> void:
	var sk := sketch()
	if sk == null or app.selected_constraint < 0 or not _dim_fields.has_text(0):
		return
	if app.selected_constraint >= sk.constraints.size():
		return
	var c := sk.constraints[app.selected_constraint]
	if not c.is_dimensional():
		return
	var at := view().world_to_screen(
		ConstraintOverlay.anchor_of(sk, c) + c.label_offset) + Vector2(0, 20)
	_dim_fields.draw(overlay, at, app.doc.display_unit, [c.value])


func _moving_entity_ids() -> Array:
	# Exclude dragged points AND entities owning them from snap targets.
	var out := _move_points.duplicate()
	var sk := sketch()
	for e in sk.entities():
		if e.kind() == "point":
			continue
		for pid in e.point_refs():
			if _move_points.has(pid):
				out.append(e.id)
				break
	return out
