class_name PointTool
extends SketchTool
## Sketch point tool: click places a SketchPoint (snapped). One undo step
## per point.
##
## The snap the user SAW becomes a CONSTRAINT, the same rule the line tool
## follows for its endpoints: a point dropped on a curve gets POINT_ON, one
## dropped on a line's midpoint gets MIDPOINT, and a click on an existing
## point reuses that point instead of minting a free twin on top of it.
## Setting only the POSITION makes the attachment cosmetic — the point looks
## welded to the edge and drifts off it the moment anything moves.

var _preview := Vector2.ZERO
var _snap := {}
var _hover := false


func _init() -> void:
	id = "point"
	title = "Point"
	shortcut = KEY_P


func activate() -> void:
	app.rebuild_snap_index()
	_hover = false
	_snap = {}
	hover_id = ""


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_snap = _snap_at(world)
	_preview = _snap["pos"]
	_hover = true
	# Hard rule: nothing binds without hover feedback first. The highlight is
	# driven by the SNAP, not by a second hit test, so it can never promise an
	# attachment the click would not actually make.
	hover_id = _hover_target(_snap)
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	# Recomputed rather than reused: a click can arrive with no motion before
	# it (touch, automation), and placing at a stale preview would attach the
	# point to whatever the cursor last passed over.
	var snap := _snap_at(world)
	var kind := String(snap.get("kind", ""))
	# Landing on an existing point: reuse it. A second point at the same place
	# is two independent variables that merely agree today — exactly the
	# "cosmetic weld" the line tool avoids by sharing the id.
	if kind == SnapEngine.KIND_POINT:
		var hit := String(snap.get("id", ""))
		if hit != "" and sk.has(hit):
			app.set_selection([hit])
			app.set_status_hint(
				"%s is already here — selected it instead of stacking a "
				% hit + "second point on top of it")
			return true
	var p := SketchPoint.make(snap["pos"])
	p.id = sk.next_id()
	var cons: Array = []
	var owner := _bind_target(snap)
	if owner != "":
		match kind:
			SnapEngine.KIND_MID:
				cons.append(SketchConstraint.make(
					SketchConstraint.Type.MIDPOINT, [p.id, owner]))
			SnapEngine.KIND_CURVE:
				cons.append(SketchConstraint.make(
					SketchConstraint.Type.POINT_ON, [p.id, owner]))
	app.stack.push_no_merge(
		CmdAddEntities.new(app.active_sketch_id, [p], cons))
	app.rebuild_snap_index()
	return true


## The entity a click here would ACT ON — the curve the new point binds to,
## or the existing point it would reuse. Highlighting the reuse case matters
## as much as the bind case: a click that quietly resolves to an existing
## point looks like a click that did nothing.
func _hover_target(snap: Dictionary) -> String:
	var sk := sketch()
	if sk == null:
		return ""
	if String(snap.get("kind", "")) == SnapEngine.KIND_POINT:
		var hit := String(snap.get("id", ""))
		return hit if sk.has(hit) else ""
	return _bind_target(snap)


## The entity a click here would CONSTRAIN the new point to, "" for a free
## point (grid snap or open space). Grid and existing-point snaps bind
## nothing: the first has no owner, the second reuses the point instead.
func _bind_target(snap: Dictionary) -> String:
	var owner := String(snap.get("owner", ""))
	if owner == "" or sketch() == null or not sketch().has(owner):
		return ""
	match String(snap.get("kind", "")):
		SnapEngine.KIND_MID, SnapEngine.KIND_CURVE:
			return owner
	return ""


func _snap_at(world: Vector2) -> Dictionary:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var p := view().world_to_screen(_preview)
	overlay.draw_line(p - Vector2(5, 0), p + Vector2(5, 0), ghost(0.9), 1.0)
	overlay.draw_line(p - Vector2(0, 5), p + Vector2(0, 5), ghost(0.9), 1.0)
	# What the click will bind to, in the constraint palette's own colours:
	# green for the exact hits (existing point, midpoint), amber for "somewhere
	# along this curve".
	match String(_snap.get("kind", "")):
		SnapEngine.KIND_POINT:
			overlay.draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)),
				ThemeService.col("constraint_ok"), false, 2.0)
		SnapEngine.KIND_MID:
			overlay.draw_circle(p, 5.0, ThemeService.col("constraint_ok"))
		SnapEngine.KIND_CURVE:
			overlay.draw_circle(p, 4.0, ThemeService.col("warning"))
