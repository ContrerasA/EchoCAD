class_name CenterArcTool
extends SketchTool
## Center-point arc: click center, click start (sets radius), then the end
## angle follows the cursor; third click commits. Winding follows the short
## way the cursor traveled from the start angle.

var _picked: Array[Vector2] = []
var _preview := Vector2.ZERO
var _hover := false
## Accumulated swept angle while previewing (lets the user wind past 180°).
var _sweep := 0.0
var _last_angle := 0.0


func _init() -> void:
	id = "center_arc"
	title = "Center Arc"
	shortcut = KEY_NONE


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_picked.clear()
	_hover = false
	_sweep = 0.0


func cancel() -> bool:
	if not _picked.is_empty() or _hover:
		_reset()
		return true
	return false


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	if _picked.size() == 2:
		var ang := (_preview - _picked[0]).angle()
		var d := wrapf(ang - _last_angle, -PI, PI)
		_sweep = clampf(_sweep + d, -TAU + 0.01, TAU - 0.01)
		_last_angle = ang
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _snap(world)
	_picked.append(pos)
	if _picked.size() == 2:
		_last_angle = (pos - _picked[0]).angle()
		_sweep = 0.0
		return true
	if _picked.size() < 3:
		return true
	_commit()
	return true


func _commit() -> void:
	var center_pos := _picked[0]
	var start_pos := _picked[1]
	var r := center_pos.distance_to(start_pos)
	if r < 1e-6 or absf(_sweep) < 1e-3:
		_reset()
		return
	var end_angle := (start_pos - center_pos).angle() + _sweep
	var end_pos := center_pos + Vector2(cos(end_angle), sin(end_angle)) * r
	var sk := sketch()
	var center := SketchPoint.make(center_pos)
	var start := SketchPoint.make(start_pos)
	var end := SketchPoint.make(end_pos)
	for p: SketchPoint in [center, start, end]:
		p.id = sk.next_id()
	var arc := SketchArc.make(center.id, start.id, end.id, _sweep > 0.0)
	arc.id = sk.next_id()
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		[center, start, end, arc]))
	app.rebuild_snap_index()
	_reset()


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	for p in _picked:
		overlay.draw_circle(v.world_to_screen(p), 3.0, Color(0.35, 0.9, 0.55))
	if _picked.size() == 1:
		overlay.draw_line(v.world_to_screen(_picked[0]),
			v.world_to_screen(_preview), Color(1, 1, 1, 0.35), 1.0)
	elif _picked.size() == 2:
		var c := _picked[0]
		var r := c.distance_to(_picked[1])
		var a0 := (_picked[1] - c).angle()
		overlay.draw_arc(v.world_to_screen(c), r * v.zoom(),
			-a0, -(a0 + _sweep), 48, Color(1, 1, 1, 0.8), 1.0)
		overlay.draw_line(v.world_to_screen(c), v.world_to_screen(_preview),
			Color(1, 1, 1, 0.25), 1.0)
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
