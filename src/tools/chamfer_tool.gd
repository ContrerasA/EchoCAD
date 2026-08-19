class_name ChamferTool
extends SketchTool
## M29 sketch chamfer: click a corner point shared by exactly two lines; the
## corner is cut by a straight edge at the typed distance (equal legs,
## default 0.25 in) along both lines. Same surgery as the fillet: the shared
## point splits, each line is rewired to its own cut point, the corner point
## dies. One undo step.

const HIT_PX := 8.0
const DEFAULT_D := 6.35   # 0.25 in

var _hover := false
var _preview := Vector2.ZERO
var _fields := DimFields.new(["D"])
var _corner := ""


func _init() -> void:
	id = "chamfer"
	title = "Chamfer"
	shortcut = KEY_NONE


func activate() -> void:
	_hover = false
	_corner = ""
	_fields.reset()


func cancel() -> bool:
	if _corner != "" or _fields.has_text(0):
		_corner = ""
		_fields.reset()
		return true
	return false


func key_input(e: InputEventKey) -> bool:
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	_corner = ""
	var sk := sketch()
	var hit := SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	if hit != "" and sk.entity(hit).kind() == "point" \
			and _lines_at(sk, hit).size() == 2:
		_corner = hit
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	pointer_move(world, _screen, null)
	if _corner == "":
		return true
	var d := _fields.value_mm(0, app.doc.display_unit)
	_apply(sketch(), _corner, absf(d) if not is_nan(d) else DEFAULT_D)
	_corner = ""
	return true


func _lines_at(sk: Sketch, pid: String) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e is SketchLine and ((e as SketchLine).p0 == pid
				or (e as SketchLine).p1 == pid):
			out.append(e)
	return out


func _apply(sk: Sketch, corner_id: String, d: float) -> void:
	var lines := _lines_at(sk, corner_id)
	var l1 := lines[0] as SketchLine
	var l2 := lines[1] as SketchLine
	var corner := sk.point(corner_id).pos
	var far1 := sk.point(l1.p1 if l1.p0 == corner_id else l1.p0).pos
	var far2 := sk.point(l2.p1 if l2.p0 == corner_id else l2.p0).pos
	var u := (far1 - corner).normalized()
	var w := (far2 - corner).normalized()
	var cos_full := clampf(u.dot(w), -1.0, 1.0)
	var theta := acos(cos_full)
	if theta < 0.02 or theta > PI - 0.02:
		app.set_status_hint("Chamfer: lines are collinear")
		return
	if d > far1.distance_to(corner) - 1e-6 \
			or d > far2.distance_to(corner) - 1e-6:
		app.set_status_hint("Chamfer: distance too large for these lines")
		return
	var t1 := corner + u * d
	var t2 := corner + w * d

	var batch := CmdMergeBatch.new("Chamfer", [])
	app.stack.push_no_merge(batch)
	var p1 := SketchPoint.make(t1)
	var p2 := SketchPoint.make(t2)
	for p: SketchPoint in [p1, p2]:
		p.id = sk.next_id()
	var edge := SketchLine.make(p1.id, p2.id)
	edge.id = sk.next_id()
	app.stack.push(CmdAddEntities.new(app.active_sketch_id,
		[p1, p2, edge], []))
	app.stack.push(CmdSetEntityRef.new(app.active_sketch_id, l1.id,
		"p0" if l1.p0 == corner_id else "p1", p1.id))
	app.stack.push(CmdSetEntityRef.new(app.active_sketch_id, l2.id,
		"p0" if l2.p0 == corner_id else "p1", p2.id))
	app.stack.push(CmdDeleteEntities.new(app.active_sketch_id, [corner_id]))
	app.solve_followers()
	batch.seal()
	app.rebuild_snap_index()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _corner != "":
		overlay.draw_circle(v.world_to_screen(sketch().point(_corner).pos),
			6.0, Color(0.35, 0.9, 0.55, 0.9))
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.6))
	if _fields.has_text(0):
		_fields.draw(overlay, v.world_to_screen(_preview),
			app.doc.display_unit, [DEFAULT_D])
