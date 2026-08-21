class_name RectPatternTool
extends SketchTool
## M29 rectangular pattern: select geometry first, then this tool. The
## cursor sets the column/row offset from the selection's anchor (its
## bounding-box min corner); type-in fields override columns (N), rows (M),
## and the two spacings. Click commits every copy in ONE undo step.
## Copies clone the selection's internal geometric constraints (PatternLib),
## Fusion-lite: dimensions/FIX are not replicated.

var _hover := false
var _preview := Vector2.ZERO
## Cols/Rows are plain counts; the spacings are lengths in the display unit.
var _fields := DimFields.new(["Cols", "Rows", "Spacing X", "Spacing Y"],
	["int", "int", "len", "len"])
var _source: Array = []
var _anchor := Vector2.ZERO


func _init() -> void:
	id = "rect_pattern"
	title = "Rect Pattern"
	shortcut = KEY_NONE


func activate() -> void:
	_hover = false
	_fields.reset()
	gathering = false
	_take_source()
	if _source.is_empty():
		gather_begin("Rect Pattern: click the geometry to pattern")
		return
	_arm()


## The selection minus bare points becomes the pattern source.
func _take_source() -> void:
	_source = app.selection.duplicate()
	_source = _source.filter(func(sid: String) -> bool:
		var e := sketch().entity(sid)
		return e != null and e.kind() != "point")


func _arm() -> void:
	_anchor = _bbox_min(sketch(), _source)
	app.set_status_hint("Rect Pattern: move to set spacing, type "
		+ "Cols/Rows/Spacing (Tab cycles), click to commit")


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
	if _fields.has_text(0) or _fields.has_text(1) or _fields.has_text(2) \
			or _fields.has_text(3):
		_fields.reset()
		return true
	if not _source.is_empty():
		_source = []
		return true
	return false


func key_input(e: InputEventKey) -> bool:
	return _fields.key_input(e)


static func _bbox_min(sk: Sketch, ids: Array) -> Vector2:
	var lo := Vector2(INF, INF)
	for id in ids:
		var e := sk.entity(String(id))
		if e == null:
			continue
		for pid in e.point_refs():
			var p := sk.point(pid)
			if p != null:
				lo = Vector2(minf(lo.x, p.pos.x), minf(lo.y, p.pos.y))
	return lo if lo.x < INF else Vector2.ZERO


## Counts come from the fields as raw numbers; spacings honor the display
## unit; the cursor supplies both spacings when the fields are empty.
func _params() -> Dictionary:
	var n := _fields.value_num(0)
	var m := _fields.value_num(1)
	var dx := _fields.value_mm(2, app.doc.display_unit)
	var dy := _fields.value_mm(3, app.doc.display_unit)
	var d := _preview - _anchor
	var p := {
		"cols": clampi(int(n) if not is_nan(n) else 2, 1, 64),
		"rows": clampi(int(m) if not is_nan(m) else 1, 1, 64),
		"dx": dx if not is_nan(dx) else d.x,
		"dy": dy if not is_nan(dy) else d.y,
	}
	# A 1-count axis has no spacing to ask for — hide its field (QA §M29.1).
	_fields.set_enabled(2, int(p["cols"]) > 1)
	_fields.set_enabled(3, int(p["rows"]) > 1)
	return p


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	if gathering:
		update_hover(world, GATHER_HIT_PX)
	return true


func pointer_down(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if gathering:
		if gather_pointer_down(_world, e):
			_take_source()
			_arm()
		return true
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _source.is_empty():
		gather_begin("Rect Pattern: click the geometry to pattern")
		return true
	var p := _params()
	if int(p["cols"]) * int(p["rows"]) <= 1:
		app.set_status_hint("Rect Pattern: nothing to copy (1×1)")
		return true
	if absf(float(p["dx"])) < 1e-6 and absf(float(p["dy"])) < 1e-6:
		app.set_status_hint("Rect Pattern: zero spacing")
		return true
	var sk := sketch()
	var adds: Array = []
	var cons: Array = []
	for j in int(p["rows"]):
		for i in int(p["cols"]):
			if i == 0 and j == 0:
				continue
			var off := Vector2(float(p["dx"]) * i, float(p["dy"]) * j)
			var dup := PatternLib.duplicate_transformed(sk, _source,
				Transform2D(0.0, off))
			adds.append_array(dup["entities"])
			cons.append_array(dup["cons"])
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		adds, cons))
	app.rebuild_snap_index()
	app.set_status_hint("Pattern: %d copies" %
		(int(p["cols"]) * int(p["rows"]) - 1))
	_fields.reset()
	return true


func draw_overlay(overlay: Control) -> void:
	if not _hover or _source.is_empty():
		return
	var v := view()
	var sk := sketch()
	var p := _params()
	for j in int(p["rows"]):
		for i in int(p["cols"]):
			if i == 0 and j == 0:
				continue
			var off := Vector2(float(p["dx"]) * i, float(p["dy"]) * j)
			for sid in _source:
				var poly := SketchGeometry.entity_polyline(sk,
					sk.entity(String(sid)))
				for k in poly.size() - 1:
					preview_line(overlay, v.world_to_screen(poly[k] + off),
						v.world_to_screen(poly[k + 1] + off),
						ghost(0.5), 1.0)
	_fields.draw(overlay, v.world_to_screen(_preview), app.doc.display_unit,
		[p["cols"], p["rows"], p["dx"], p["dy"]])
