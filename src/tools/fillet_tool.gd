class_name FilletTool
extends SketchTool
## Sketch fillet (F): click a corner point shared by exactly two lines; the
## corner is replaced by a tangent arc of the typed radius (default 0.25 in).
## The shared point is split — each line gets its own endpoint at the
## tangency point — and TANGENT constraints on both sides keep it a fillet
## under the solver. One undo step.

const HIT_PX := 8.0
const DEFAULT_R := 6.35   # 0.25 in

var _hover := false
var _preview := Vector2.ZERO
var _fields := DimFields.new(["R"])
var _corner := ""          # hovered corner point id ("" = none)


func _init() -> void:
	id = "fillet"
	title = "Fillet"
	shortcut = KEY_F


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
	var r := _fields.value_mm(0, app.doc.display_unit)
	_apply(sketch(), _corner, absf(r) if not is_nan(r) else DEFAULT_R)
	_corner = ""
	return true


func _lines_at(sk: Sketch, pid: String) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e is SketchLine and ((e as SketchLine).p0 == pid
				or (e as SketchLine).p1 == pid):
			out.append(e)
	return out


func _apply(sk: Sketch, corner_id: String, r: float) -> void:
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
		app._status_hint.text = "Fillet: lines are collinear"
		return
	var leg := r / tan(theta * 0.5)
	if leg > far1.distance_to(corner) - 1e-6 \
			or leg > far2.distance_to(corner) - 1e-6:
		app._status_hint.text = "Fillet: radius too large for these lines"
		return
	var t1 := corner + u * leg
	var t2 := corner + w * leg
	var bis := (u + w).normalized()
	var center := corner + bis * (r / sin(theta * 0.5))

	var batch := CmdMergeBatch.new("Fillet", [])
	app.stack.push_no_merge(batch)
	# New endpoints (the shared corner splits) + arc center.
	var p1 := SketchPoint.make(t1)
	var p2 := SketchPoint.make(t2)
	var cp := SketchPoint.make(center)
	for p: SketchPoint in [p1, p2, cp]:
		p.id = sk.next_id()
	# Winding: the arc runs from t1 to t2 the short way around center.
	var ccw := (t1 - center).cross(t2 - center) > 0.0
	var arc := SketchArc.make(cp.id, p1.id, p2.id, ccw)
	arc.id = sk.next_id()
	var cons: Array = [
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [l1.id, arc.id]),
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [l2.id, arc.id]),
	]
	app.stack.push(CmdAddEntities.new(app.active_sketch_id,
		[p1, p2, cp, arc], cons))
	# Rewire each line's corner end to its tangency point.
	app.stack.push(CmdSetEntityRef.new(app.active_sketch_id, l1.id,
		"p0" if l1.p0 == corner_id else "p1", p1.id))
	app.stack.push(CmdSetEntityRef.new(app.active_sketch_id, l2.id,
		"p0" if l2.p0 == corner_id else "p1", p2.id))
	# The corner point is now orphaned; delete it (prunes its constraints).
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
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, ghost(0.6))
	if _fields.has_text(0):
		_fields.draw(overlay, v.world_to_screen(_preview),
			app.doc.display_unit, [DEFAULT_R])
