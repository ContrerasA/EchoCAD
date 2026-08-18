class_name CircleTool
extends SketchTool
## Center-radius circle: click center, click rim (or type R + Enter).
## One undo step: center SketchPoint + SketchCircle.

var _armed := false
var _center := Vector2.ZERO
var _preview := Vector2.ZERO
var _hover := false
var _fields := DimFields.new(["R"])


func _init() -> void:
	id = "circle"
	title = "Circle"
	shortcut = KEY_C


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_armed = false
	_hover = false
	_fields.reset()


func cancel() -> bool:
	if _armed or _hover:
		_reset()
		return true
	return false


func commit() -> bool:
	if not _armed:
		return false
	var r := _resolve_radius()
	if r > 1e-6:
		_commit_circle(r)
	return true


func key_input(e: InputEventKey) -> bool:
	if not _armed:
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return commit()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _snap(world)
	if not _armed:
		_armed = true
		_center = pos
		_fields.reset()
		return true
	_preview = pos
	var r := _resolve_radius()
	if r > 1e-6:
		_commit_circle(r)
	return true


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


func _resolve_radius() -> float:
	var typed := _fields.value_mm(0, app.doc.display_unit)
	return absf(typed) if not is_nan(typed) else _center.distance_to(_preview)


func _commit_circle(r: float) -> void:
	var sk := sketch()
	var cp := SketchPoint.make(_center)
	cp.id = sk.next_id()
	var ci := SketchCircle.make(cp.id, r)
	ci.id = sk.next_id()
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction([cp, ci])))
	app.rebuild_snap_index()
	_reset()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _armed:
		var r := _resolve_radius()
		var c := v.world_to_screen(_center)
		preview_arc(overlay, c, r * v.zoom(), 0, TAU, 64, Color(1, 1, 1, 0.9), 1.0)
		overlay.draw_line(c, v.world_to_screen(_preview), Color(1, 1, 1, 0.35), 1.0)
		_fields.draw(overlay, v.world_to_screen(_preview),
			app.doc.display_unit, [r])
	else:
		overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
