class_name TangentArcTool
extends SketchTool
## Tangent arc: first click must land on a LINE ENDPOINT; the arc leaves
## that endpoint tangent to the line and ends at the second click. Commits
## start (coincident with the line endpoint), center, end + arc + TANGENT
## constraint in one undo step.

var _armed := false
var _line_id := ""
var _start_point_id := ""       # the snapped line endpoint
var _start := Vector2.ZERO
var _dir := Vector2.ZERO        # tangent direction leaving the endpoint
var _preview := Vector2.ZERO
var _hover := false


func _init() -> void:
	id = "tangent_arc"
	title = "Tangent Arc"
	shortcut = KEY_NONE


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_armed = false
	_hover = false
	_line_id = ""
	_start_point_id = ""


func cancel() -> bool:
	if _armed or _hover:
		_reset()
		return true
	return false


## Solve the tangent-arc geometry: center sits on the normal through start;
## |end - center| == |start - center|. Returns {} when degenerate.
static func solve_arc(start: Vector2, dir: Vector2, end: Vector2) -> Dictionary:
	var n := Vector2(-dir.y, dir.x)
	var v := end - start
	var denom := 2.0 * n.dot(v)
	if absf(denom) < 1e-9 or v.length() < 1e-6:
		return {}
	var t := v.length_squared() / denom
	var center := start + n * t
	# ccw when the tangent direction at start (ccw sense) matches dir.
	var tangent_ccw := Vector2(-(start - center).y, (start - center).x)
	return {"center": center, "radius": absf(t),
		"ccw": tangent_ccw.dot(dir) > 0.0}


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	var s := _snap(world)
	_preview = s["pos"]
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var s := _snap(world)
	if not _armed:
		if String(s.get("kind", "")) != SnapEngine.KIND_POINT:
			return true   # needs a line endpoint
		var pid := String(s["id"])
		var sk := sketch()
		for ent in sk.entities():
			if ent.kind() != "line":
				continue
			var l := ent as SketchLine
			if l.p0 == pid or l.p1 == pid:
				_line_id = l.id
				_start_point_id = pid
				_start = s["pos"]
				var other := sk.point(l.p1 if l.p0 == pid else l.p0)
				_dir = (_start - other.pos).normalized()
				_armed = true
				return true
		return true
	var arc_geo := solve_arc(_start, _dir, s["pos"])
	if arc_geo.is_empty():
		return true
	# The END click's snap matters as much as the start's. Only its POSITION
	# was used before, so an arc closed onto existing geometry looked joined
	# but was not: its far endpoint was a fresh, unconstrained point sitting on
	# top of another one, and the moment anything moved they came apart.
	var end_id := String(s["id"]) \
		if String(s.get("kind", "")) == SnapEngine.KIND_POINT else ""
	_commit(s["pos"], arc_geo, end_id)
	return true


## `snapped_end_id` — an existing point the closing click landed on, to weld
## the arc's far end onto; "" to mint a fresh point there.
func _commit(end_pos: Vector2, geo: Dictionary, snapped_end_id := "") -> void:
	var sk := sketch()
	var center := SketchPoint.make(geo["center"])
	var entities: Array = []
	center.id = sk.next_id()
	# WELD the arc's start onto the line endpoint it was launched from, rather
	# than minting a twin there and tying the two with a Coincident (which is
	# what the line tool used to do — see its `_commit_segment`).
	#
	# The twin was not merely redundant, it was actively unstable. The solver's
	# rigid ride-along translates an arc's rim when its centre moves, the
	# tangency projection moves that centre to close its gap, and the Coincident
	# then hauls the twin back — three rules taking turns undoing each other, so
	# the solve never converged and a 5 mm drag of the line sent the arc's
	# centre over a metre while leaving tangency WORSE than it started. One
	# shared point removes the contradiction at the source: there is nothing to
	# reconcile, because there is only one point.
	var start_id := _start_point_id
	if start_id == "" or not sk.has(start_id):
		var start := SketchPoint.make(_start)
		start.id = sk.next_id()
		entities.append(start)
		start_id = start.id
	# Same weld for the closing end.
	var end_id := snapped_end_id
	if end_id == "" or not sk.has(end_id) or end_id == start_id:
		var end := SketchPoint.make(end_pos)
		end.id = sk.next_id()
		entities.append(end)
		end_id = end.id
	entities.append(center)
	var arc := SketchArc.make(center.id, start_id, end_id, bool(geo["ccw"]))
	arc.id = sk.next_id()
	entities.append(arc)
	var cons: Array = [
		SketchConstraint.make(SketchConstraint.Type.TANGENT, [_line_id, arc.id]),
	]
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		entities, cons))
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
	if _armed:
		var geo := solve_arc(_start, _dir, _preview)
		if not geo.is_empty():
			var c: Vector2 = geo["center"]
			var a0 := (_start - c).angle()
			var a1 := (_preview - c).angle()
			var sweep := fposmod(a1 - a0, TAU) if bool(geo["ccw"]) \
				else fposmod(a1 - a0, TAU) - TAU
			overlay.draw_arc(v.world_to_screen(c), float(geo["radius"]) * v.zoom(),
				-a0, -(a0 + sweep), 48, Color(1, 1, 1, 0.8), 1.0)
		overlay.draw_circle(v.world_to_screen(_start), 4.0, Color(0.35, 0.9, 0.55))
	overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
