class_name PointTool
extends SketchTool
## Sketch point tool: click places a SketchPoint (snapped). One undo step
## per point.

var _preview := Vector2.ZERO
var _hover := false


func _init() -> void:
	id = "point"
	title = "Point"
	shortcut = KEY_P


func activate() -> void:
	app.rebuild_snap_index()
	_hover = false


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	var p := SketchPoint.make(_snap(world))
	p.id = sk.next_id()
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id, [p]))
	app.rebuild_snap_index()
	return true


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var p := view().world_to_screen(_preview)
	overlay.draw_line(p - Vector2(5, 0), p + Vector2(5, 0), Color.WHITE, 1.0)
	overlay.draw_line(p - Vector2(0, 5), p + Vector2(0, 5), Color.WHITE, 1.0)
