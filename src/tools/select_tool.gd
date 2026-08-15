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
	if not app.selection.is_empty():
		app.set_selection([])
		return true
	return false


func pointer_down(world: Vector2, screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
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
	if _drag == Drag.PENDING \
			and screen.distance_to(_down_screen) > DEADZONE_PX:
		_drag = Drag.MOVE
		app.rebuild_snap_index(_moving_entity_ids())
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
	return true


func pointer_up(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _drag == Drag.MOVE:
		app.rebuild_snap_index()
	_drag = Drag.NONE
	return true


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
