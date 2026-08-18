class_name ThreePointCircleTool
extends SketchTool
## Circle through three clicked points. Preview appears after the second
## click; the third commits center point + circle as one undo step.

var _picked: Array[Vector2] = []
var _preview := Vector2.ZERO
var _hover := false


func _init() -> void:
	id = "circle3"
	title = "3-Pt Circle"
	shortcut = KEY_NONE


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_picked.clear()
	_hover = false


func cancel() -> bool:
	if not _picked.is_empty() or _hover:
		_reset()
		return true
	return false


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _snap(world)
	_picked.append(pos)
	if _picked.size() < 3:
		return true
	var cc := SketchGeometry.circumcircle(_picked[0], _picked[1], _picked[2])
	if not cc.get("ok", false):
		_picked.resize(2)   # collinear — ignore the click
		return true
	var sk := sketch()
	var cp := SketchPoint.make(cc["pos"])
	cp.id = sk.next_id()
	var ci := SketchCircle.make(cp.id, float(cc["radius"]))
	ci.id = sk.next_id()
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction([cp, ci])))
	app.rebuild_snap_index()
	_reset()
	return true


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
	if _picked.size() == 2:
		var cc := SketchGeometry.circumcircle(_picked[0], _picked[1], _preview)
		if cc.get("ok", false):
			overlay.draw_arc(v.world_to_screen(cc["pos"]),
				float(cc["radius"]) * v.zoom(), 0, TAU, 64,
				Color(1, 1, 1, 0.7), 1.0)
	elif _picked.size() == 1:
		overlay.draw_line(v.world_to_screen(_picked[0]),
			v.world_to_screen(_preview), Color(1, 1, 1, 0.35), 1.0)
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
