class_name SlotTool
extends SketchTool
## Slot tool, all three Fusion variants (selected by `variant`):
##   "center"  — center-to-center: click center A, center B, then width
##   "overall" — overall: click the two outer ends, then width
##   "point"   — center-point: click the slot's midpoint, one end center,
##               then width
## Third click (or typed W + Enter) commits ONE undo step: 6 points, 2 side
## lines, 2 end arcs sharing rim points, and the constraints that keep a
## slot a slot under the solver: 4 tangencies + equal end radii. Like
## Fusion, the slot IS plain sketch geometry afterwards — dimension the
## center distance or an end radius to drive it.

var variant := "center"

var _picks: Array[Vector2] = []
var _preview := Vector2.ZERO
var _hover := false
var _fields := DimFields.new(["W"])


func _init(p_variant := "center") -> void:
	variant = p_variant
	match variant:
		"center":
			id = "slot"
			title = "Slot"
			shortcut = KEY_S
		"overall":
			id = "slot_overall"
			title = "Slot (Overall)"
		"point":
			id = "slot_center"
			title = "Slot (Center Pt)"


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_picks.clear()
	_hover = false
	_fields.reset()


func cancel() -> bool:
	if not _picks.is_empty() or _hover:
		_reset()
		return true
	return false


func commit() -> bool:
	if _picks.size() == 2:
		var w := _resolve_width()
		if w > 1e-6:
			_commit_slot(w)
			return true
	return false


func key_input(e: InputEventKey) -> bool:
	if _picks.size() != 2:
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return commit()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _snap(world)
	if _picks.size() < 2:
		_picks.append(pos)
		if _picks.size() == 2 and _picks[0].distance_to(_picks[1]) < 1e-6:
			_picks.resize(1)
		return true
	_preview = pos
	var w := _resolve_width()
	if w > 1e-6:
		_commit_slot(w)
	return true


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


## Slot CENTERS for the current picks (variant-dependent).
func _centers(width: float) -> Array:
	match variant:
		"overall":
			var d := (_picks[1] - _picks[0]).normalized()
			return [_picks[0] + d * width * 0.5, _picks[1] - d * width * 0.5]
		"point":
			return [_picks[1], _picks[0] * 2.0 - _picks[1]]
	return [_picks[0], _picks[1]]


func _resolve_width() -> float:
	var typed := _fields.value_mm(0, app.doc.display_unit)
	if not is_nan(typed):
		return absf(typed)
	# Width from the cursor's distance to the axis (full width = 2x).
	var a := _picks[0]
	var b := _picks[1]
	var d := (b - a).normalized()
	if d == Vector2.ZERO:
		return 0.0
	return absf(Vector2(-d.y, d.x).dot(_preview - a)) * 2.0


func _commit_slot(width: float) -> void:
	var centers := _centers(width)
	var wa: Vector2 = centers[0]
	var wb: Vector2 = centers[1]
	if wa.distance_to(wb) < width * 0.5 + 1e-6:
		return   # degenerate: ends would overlap
	var d := (wb - wa).normalized()
	var n := Vector2(-d.y, d.x)
	var r := width * 0.5
	var sk := sketch()

	var pa := SketchPoint.make(wa)
	var pb := SketchPoint.make(wb)
	var p1 := SketchPoint.make(wa + n * r)   # A upper rim
	var p2 := SketchPoint.make(wa - n * r)   # A lower rim
	var p3 := SketchPoint.make(wb + n * r)   # B upper rim
	var p4 := SketchPoint.make(wb - n * r)   # B lower rim
	for p: SketchPoint in [pa, pb, p1, p2, p3, p4]:
		p.id = sk.next_id()
	var side1 := SketchLine.make(p1.id, p3.id)
	var side2 := SketchLine.make(p2.id, p4.id)
	# End arcs bulge away from the opposite center; windings derived from
	# the +n/-n rim layout (see cross products in the design notes).
	var arc_a := SketchArc.make(pa.id, p1.id, p2.id, true)
	var arc_b := SketchArc.make(pb.id, p4.id, p3.id, true)
	for e: SketchEntity in [side1, side2, arc_a, arc_b]:
		e.id = sk.next_id()

	var cons: Array = [
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [side1.id, arc_a.id]),
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [side1.id, arc_b.id]),
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [side2.id, arc_a.id]),
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [side2.id, arc_b.id]),
		SketchConstraint.make(SketchConstraint.Type.EQUAL, [arc_a.id, arc_b.id]),
	]
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction([pa, pb, p1, p2, p3, p4, side1, side2, arc_a, arc_b]),
		cons))
	app.rebuild_snap_index()
	_reset()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	for p in _picks:
		overlay.draw_circle(v.world_to_screen(p), 3.0, Color(0.35, 0.9, 0.55))
	if _picks.size() == 1:
		overlay.draw_line(v.world_to_screen(_picks[0]),
			v.world_to_screen(_preview), Color(1, 1, 1, 0.35), 1.0)
	elif _picks.size() == 2:
		var w := _resolve_width()
		if w > 1e-6:
			_draw_slot_preview(overlay, w)
		_fields.draw(overlay, v.world_to_screen(_preview),
			app.doc.display_unit, [w])


func _draw_slot_preview(overlay: Control, width: float) -> void:
	var v := view()
	var centers := _centers(width)
	var wa: Vector2 = centers[0]
	var wb: Vector2 = centers[1]
	var d := (wb - wa).normalized()
	if d == Vector2.ZERO:
		return
	var n := Vector2(-d.y, d.x)
	var r := width * 0.5
	var col := Color(1, 1, 1, 0.85)
	overlay.draw_line(v.world_to_screen(wa + n * r),
		v.world_to_screen(wb + n * r), col, 1.0)
	overlay.draw_line(v.world_to_screen(wa - n * r),
		v.world_to_screen(wb - n * r), col, 1.0)
	# End caps (screen-space angles are negated: Y-down). The A cap bulges AWAY
	# from B — its screen sweep must pass through world direction -d, which is
	# the [ang_n + PI, ang_n + TAU] half here; B gets the other half.
	var ang_n := -n.angle()
	overlay.draw_arc(v.world_to_screen(wa), r * v.zoom(),
		ang_n + PI, ang_n + TAU, 24, col, 1.0)
	overlay.draw_arc(v.world_to_screen(wb), r * v.zoom(),
		ang_n, ang_n + PI, 24, col, 1.0)
