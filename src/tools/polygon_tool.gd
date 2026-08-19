class_name PolygonTool
extends SketchTool
## M29 polygon: first click is the CENTER, second a VERTEX (inscribed).
## Fields: N sides (default 6), R circumradius. Emits the Fusion-style
## constrained shape: a construction center point + construction circle,
## every vertex POINT_ON the circle, consecutive sides EQUAL — the ring
## stays a regular polygon through drags while rotation/scale stay free
## (dimension the circle to lock the size). One undo step.

var _hover := false
var _armed := false
var _center := Vector2.ZERO
var _preview := Vector2.ZERO
var _fields := DimFields.new(["N", "R"])


func _init() -> void:
	id = "polygon"
	title = "Polygon"
	shortcut = KEY_NONE


func activate() -> void:
	_reset()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_hover = false
	_armed = false
	_fields.reset()


func cancel() -> bool:
	if _armed or _fields.has_text(0) or _fields.has_text(1):
		_reset()
		return true
	return false


func key_input(e: InputEventKey) -> bool:
	return _fields.key_input(e)


func _sides() -> int:
	var n := _fields.value_mm(0, UnitConverter.Unit.MM)
	return clampi(int(n) if not is_nan(n) else 6, 3, 64)


func _vertex_at() -> Vector2:
	var r := _fields.value_mm(1, app.doc.display_unit)
	if is_nan(r):
		return _preview
	var dir := (_preview - _center)
	if dir.length() < 1e-9:
		dir = Vector2.RIGHT
	return _center + dir.normalized() * absf(r)


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
		return true
	_preview = pos
	_commit()
	return true


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


func _commit() -> void:
	var sk := sketch()
	var vert := _vertex_at()
	var r := _center.distance_to(vert)
	if r < 1e-6:
		return
	var n := _sides()
	var a0 := (vert - _center).angle()

	var cp := SketchPoint.make(_center)
	cp.id = sk.next_id()
	cp.construction = true
	var circle := SketchCircle.make(cp.id, r)
	circle.id = sk.next_id()
	circle.construction = true
	var entities: Array = [cp, circle]
	var verts: Array = []
	for k in n:
		var ang := a0 + TAU * k / n
		var p := SketchPoint.make(_center + Vector2(cos(ang), sin(ang)) * r)
		p.id = sk.next_id()
		verts.append(p)
		entities.append(p)
	var sides: Array = []
	for k in n:
		var l := SketchLine.make((verts[k] as SketchPoint).id,
			(verts[(k + 1) % n] as SketchPoint).id)
		l.id = sk.next_id()
		sides.append(l)
		entities.append(l)
	var cons: Array = []
	for k in n:
		var pops: Array[String] = [(verts[k] as SketchPoint).id, circle.id]
		cons.append(SketchConstraint.make(
			SketchConstraint.Type.POINT_ON, pops))
	for k in n - 1:
		var eops: Array[String] = [(sides[k] as SketchLine).id,
			(sides[k + 1] as SketchLine).id]
		cons.append(SketchConstraint.make(SketchConstraint.Type.EQUAL, eops))
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction(entities), cons))
	app.rebuild_snap_index()
	_reset()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _armed:
		var vert := _vertex_at()
		var r := _center.distance_to(vert)
		var n := _sides()
		var a0 := (vert - _center).angle()
		var prev := vert
		for k in range(1, n + 1):
			var ang := a0 + TAU * k / n
			var p := _center + Vector2(cos(ang), sin(ang)) * r
			preview_line(overlay, v.world_to_screen(prev),
				v.world_to_screen(p), Color(1, 1, 1, 0.9), 1.0)
			prev = p
		var c := v.world_to_screen(_center)
		overlay.draw_line(c - Vector2(4, 0), c + Vector2(4, 0),
			Color(1, 1, 1, 0.6))
		overlay.draw_line(c - Vector2(0, 4), c + Vector2(0, 4),
			Color(1, 1, 1, 0.6))
		_fields.draw(overlay, v.world_to_screen(_preview),
			app.doc.display_unit, [6, r])
	else:
		overlay.draw_circle(v.world_to_screen(_preview), 2.0,
			Color(1, 1, 1, 0.7))
