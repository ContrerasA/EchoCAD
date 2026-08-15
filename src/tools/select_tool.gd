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


func _init() -> void:
	id = "select"
	title = "Select"
	shortcut = KEY_V


func deactivate() -> void:
	_drag = Drag.NONE


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
	if e.ctrl_pressed:
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
	_drag = Drag.PENDING if not _move_points.is_empty() else Drag.NONE
	return true


func pointer_move(world: Vector2, screen: Vector2, _e: InputEventMouseMotion) -> bool:
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
	app.solve_followers(_move_points)
	return true


func pointer_up(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _label_drag >= 0:
		_label_drag = -1
		return true
	if _drag == Drag.MOVE:
		if _batch != null:
			_batch.seal()
			_batch = null
		app.rebuild_snap_index()
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
