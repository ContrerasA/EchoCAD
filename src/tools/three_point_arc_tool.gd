class_name ThreePointArcTool
extends SketchTool
## Fusion 3-point arc: click start, click end, then a point the arc passes
## through (the "bulge"). One undo step: center/start/end points + arc.
## Start/end clicks that snap onto existing points create COINCIDENT.

var _picked: Array[Vector2] = []
var _picked_snap: Array[String] = []    # snapped point id per pick ("" = none)
var _preview := Vector2.ZERO
var _hover := false


func _init() -> void:
	id = "arc3"
	title = "3-Pt Arc"
	shortcut = KEY_A


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_picked.clear()
	_picked_snap.clear()
	_hover = false


func cancel() -> bool:
	if not _picked.is_empty() or _hover:
		_reset()
		return true
	return false


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)["pos"]
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var s := _snap(world)
	_picked.append(s["pos"])
	_picked_snap.append(String(s.get("id", "")) \
		if String(s.get("kind", "")) == SnapEngine.KIND_POINT else "")
	if _picked.size() < 3:
		return true
	_commit()
	return true


## Winding so the arc from start to end passes THROUGH the third pick.
static func winding(center: Vector2, start: Vector2, end: Vector2,
		through: Vector2) -> bool:
	var a0 := (start - center).angle()
	var a1 := fposmod((end - center).angle() - a0, TAU)
	var at := fposmod((through - center).angle() - a0, TAU)
	return at <= a1


func _commit() -> void:
	var cc := SketchGeometry.circumcircle(_picked[0], _picked[1], _picked[2])
	if not cc.get("ok", false):
		_picked.resize(2)
		_picked_snap.resize(2)
		return
	var sk := sketch()
	var center := SketchPoint.make(cc["pos"])
	var start := SketchPoint.make(_picked[0])
	var end := SketchPoint.make(_picked[1])
	for p: SketchPoint in [center, start, end]:
		p.id = sk.next_id()
	var arc := SketchArc.make(center.id, start.id, end.id,
		winding(cc["pos"], _picked[0], _picked[1], _picked[2]))
	arc.id = sk.next_id()
	var cons: Array = []
	if _picked_snap[0] != "":
		cons.append(SketchConstraint.make(SketchConstraint.Type.COINCIDENT,
			[start.id, _picked_snap[0]]))
	if _picked_snap[1] != "":
		cons.append(SketchConstraint.make(SketchConstraint.Type.COINCIDENT,
			[end.id, _picked_snap[1]]))
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction([center, start, end, arc]), cons))
	app.rebuild_snap_index()
	_reset()


func _snap(world: Vector2) -> Dictionary:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)


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
		var cc := SketchGeometry.circumcircle(_picked[0], _picked[1], _preview)
		if cc.get("ok", false):
			var c: Vector2 = cc["pos"]
			var a0 := (_picked[0] - c).angle()
			var a1 := (_picked[1] - c).angle()
			var ccw := winding(c, _picked[0], _picked[1], _preview)
			var sweep := fposmod(a1 - a0, TAU) if ccw else fposmod(a1 - a0, TAU) - TAU
			preview_arc(overlay, v.world_to_screen(c),
				float(cc["radius"]) * v.zoom(),
				-a0, -(a0 + sweep), 48, Color(1, 1, 1, 0.8), 1.0)
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
