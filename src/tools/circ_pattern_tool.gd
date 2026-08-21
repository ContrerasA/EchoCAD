class_name CircPatternTool
extends SketchTool
## M29 circular pattern: select geometry first, then this tool; click the
## pattern CENTER. Fields: N (count, default 4) and A (total angle in
## degrees, default 360 — the full-circle case spaces N copies evenly, a
## partial angle spreads them over it, last copy landing on A). One click,
## one undo step; internal geometric constraints clone per copy.

var _hover := false
var _preview := Vector2.ZERO
var _fields := DimFields.new(["Count", "Angle"], ["int", "deg"])
var _source: Array = []


func _init() -> void:
	id = "circ_pattern"
	title = "Circ Pattern"
	shortcut = KEY_NONE


func activate() -> void:
	_hover = false
	_fields.reset()
	gathering = false
	_take_source()
	if _source.is_empty():
		gather_begin("Circ Pattern: click the geometry to pattern")
		return
	_arm()


func _take_source() -> void:
	_source = app.selection.duplicate()
	_source = _source.filter(func(sid: String) -> bool:
		var e := sketch().entity(sid)
		return e != null and e.kind() != "point")


func _arm() -> void:
	app.set_status_hint(
		"Circ Pattern: type Count (and total Angle°, Tab cycles), "
		+ "click the center")


func gather_accepts(id: String) -> bool:
	var e := sketch().entity(id)
	return e != null and e.kind() != "point"


func commit() -> bool:
	if gathering and gather_confirm():
		_take_source()
		_arm()
		return true
	return false


func deactivate() -> void:
	_source = []


func cancel() -> bool:
	if gathering:
		return gather_cancel()
	if _fields.has_text(0) or _fields.has_text(1):
		_fields.reset()
		return true
	if not _source.is_empty():
		_source = []
		return true
	return false


func key_input(e: InputEventKey) -> bool:
	return _fields.key_input(e)


func _params() -> Dictionary:
	var n := _fields.value_num(0)
	var a := _fields.value_num(1)
	return {
		"count": clampi(int(n) if not is_nan(n) else 4, 2, 64),
		"total": a if not is_nan(a) else 360.0,
	}


## Copy k (1-based) of `count` rotates by k * step. Full circle: step =
## total/count (N even slots). Partial: step = total/(count-1) so the last
## copy lands exactly on the typed angle.
static func step_deg(count: int, total: float) -> float:
	if absf(fposmod(total, 360.0)) < 1e-9:
		return total / count
	return total / maxi(count - 1, 1)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	if gathering:
		update_hover(world, GATHER_HIT_PX)
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if gathering:
		if gather_pointer_down(world, e):
			_take_source()
			_arm()
		return true
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _source.is_empty():
		gather_begin("Circ Pattern: click the geometry to pattern")
		return true
	var p := _params()
	var count := int(p["count"])
	var step := deg_to_rad(step_deg(count, float(p["total"])))
	var sk := sketch()
	var adds: Array = []
	var cons: Array = []
	for k in range(1, count):
		var xf := Transform2D(0.0, world) * Transform2D(step * k,
			Vector2.ZERO) * Transform2D(0.0, -world)
		var dup := PatternLib.duplicate_transformed(sk, _source, xf)
		adds.append_array(dup["entities"])
		cons.append_array(dup["cons"])
	if adds.is_empty():
		return true
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		adds, cons))
	app.rebuild_snap_index()
	app.set_status_hint("Pattern: %d copies around the center" % (count - 1))
	_fields.reset()
	return true


func draw_overlay(overlay: Control) -> void:
	if not _hover or _source.is_empty():
		return
	var v := view()
	var sk := sketch()
	var p := _params()
	var count := int(p["count"])
	var step := deg_to_rad(step_deg(count, float(p["total"])))
	for k in range(1, count):
		var xf := Transform2D(0.0, _preview) * Transform2D(step * k,
			Vector2.ZERO) * Transform2D(0.0, -_preview)
		for sid in _source:
			var poly := SketchGeometry.entity_polyline(sk,
				sk.entity(String(sid)))
			for i in poly.size() - 1:
				preview_line(overlay, v.world_to_screen(xf * poly[i]),
					v.world_to_screen(xf * poly[i + 1]),
					ghost(0.5), 1.0)
	overlay.draw_circle(v.world_to_screen(_preview), 3.0,
		Color(0.35, 0.9, 0.55, 0.9))
	_fields.draw(overlay, v.world_to_screen(_preview), app.doc.display_unit,
		[count, float(p["total"])])
