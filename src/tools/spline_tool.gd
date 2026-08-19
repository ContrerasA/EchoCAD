class_name SplineTool
extends SketchTool
## M28 spline tool: click fit points; Enter or double-click finishes the open
## spline; clicking the FIRST fit point again (3+ points down) closes it.
## Esc discards the in-progress curve. Every fit point is a real SketchPoint
## — a click on an existing point welds onto it, exactly like the line tool.
## The whole spline (points + entity) commits as ONE undo step.

var _pts: Array = []          # clicked positions (mm)
var _weld_ids: Array = []     # per click: existing point id or ""
var _preview := Vector2.ZERO
var _hover_valid := false
var _snap := {}


func _init() -> void:
	id = "spline"
	title = "Spline"
	shortcut = KEY_B


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_pts = []
	_weld_ids = []
	_hover_valid = false
	_snap = {}


func cancel() -> bool:
	if not _pts.is_empty() or _hover_valid:
		_reset()
		return true
	return false


func commit() -> bool:
	if _pts.size() >= 2:
		_do_commit(false)
		return true
	return cancel()


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _resolve(world)
	_hover_valid = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _resolve(world)
	if e.double_click:
		# The first click of the double already added this point.
		if _pts.size() >= 2:
			_do_commit(false)
		return true
	var weld := String(_snap.get("id", "")) \
		if String(_snap.get("kind", "")) == SnapEngine.KIND_POINT else ""
	# Closing click: back onto the first fit point with a real loop drawn.
	if _pts.size() >= 3:
		var on_first: bool = (weld != "" and weld == String(_weld_ids[0])) \
			or pos.distance_to(_pts[0]) < SnapEngine.TOL_PX / view().zoom()
		if on_first:
			_do_commit(true)
			return true
	if not _pts.is_empty() and pos.distance_to(_pts[_pts.size() - 1]) < 1e-6:
		return true   # duplicate click in place: ignore
	_pts.append(pos)
	_weld_ids.append(weld)
	return true


func _do_commit(make_closed: bool) -> void:
	var sk := sketch()
	var entities: Array = []
	var ids: Array = []
	for i in _pts.size():
		var wid := String(_weld_ids[i])
		if wid != "" and sk.has(wid):
			ids.append(wid)
			continue
		var p := SketchPoint.make(_pts[i])
		p.id = sk.next_id()
		entities.append(p)
		ids.append(p.id)
	var sp := SketchSpline.make(ids, make_closed)
	sp.id = sk.next_id()
	entities.append(sp)
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction(entities), []))
	app.rebuild_snap_index()
	_reset()


func _resolve(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	var s := app.snap.snap_point(world, tol, grid)
	var kind := String(s["kind"])
	_snap = s if kind != "" and kind != SnapEngine.KIND_GRID else {}
	return s["pos"]


func draw_overlay(overlay: Control) -> void:
	if not _hover_valid:
		return
	var v := view()
	# Ghost of the curve that would commit right now (same math as commit).
	if not _pts.is_empty():
		var ps := _pts.duplicate()
		if _preview.distance_to(ps[ps.size() - 1]) > 1e-6:
			ps.append(_preview)
		var poly := SketchSpline.positions_polyline(ps, [], false)
		for i in poly.size() - 1:
			preview_line(overlay, v.world_to_screen(poly[i]),
				v.world_to_screen(poly[i + 1]), ghost(0.9), 1.0)
		for p in _pts:
			var sp := v.world_to_screen(p)
			overlay.draw_rect(Rect2(sp - Vector2(3, 3), Vector2(6, 6)),
				Color(0.35, 0.9, 0.55))
	# Snap / cursor marker, same glyphs as the line tool.
	var p2 := v.world_to_screen(_preview)
	match String(_snap.get("kind", "")):
		SnapEngine.KIND_POINT:
			overlay.draw_rect(Rect2(p2 - Vector2(5, 5), Vector2(10, 10)),
				Color(0.35, 0.9, 0.55), false, 2.0)
		SnapEngine.KIND_MID:
			overlay.draw_circle(p2, 5.0, Color(0.35, 0.9, 0.55, 0.9))
		SnapEngine.KIND_CURVE:
			overlay.draw_circle(p2, 4.0, Color(0.9, 0.75, 0.35, 0.9))
		_:
			overlay.draw_circle(p2, 2.0, ghost(0.7))
