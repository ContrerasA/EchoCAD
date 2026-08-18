class_name LineTool
extends SketchTool
## Fusion-style line tool: click-click chained segments. Esc/Enter ends the
## chain; clicking the chain's start point closes it and ends the chain.
## Each committed segment is ONE undo step (points + line + inferred
## constraints together).
##
## Inference (Fusion behavior, toggleable via app.prefs.inference): a snap
## the user can SEE becomes a constraint on commit —
##   - point snap    -> COINCIDENT (new endpoint tied to the snapped point)
##   - near-H/V      -> preview locks to the axis, HORIZONTAL/VERTICAL added
## Axis inference applies only when no entity snap wins. Grid snap rounds
## the free coordinate(s) but never constrains.

const AXIS_DEG := 4.0            # inference threshold from horizontal/vertical

var _chain := false
var _anchor := Vector2.ZERO      # committed chain end (mm)
var _anchor_id := ""             # SketchPoint entity id of the chain end
var _first_id := ""              # chain's first point (for close detection)
var _preview := Vector2.ZERO
var _hover_valid := false
## Live inference state for overlay + commit: {axis: ""/"h"/"v", snap: {}}
var _inference := {"axis": "", "snap": {}}


func _init() -> void:
	id = "line"
	title = "Line"
	shortcut = KEY_L


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_chain = false
	_anchor_id = ""
	_first_id = ""
	_hover_valid = false
	_inference = {"axis": "", "snap": {}}


func cancel() -> bool:
	if _chain or _hover_valid:
		_reset()
		return true
	return false


func commit() -> bool:
	return cancel()


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _resolve(world)
	_hover_valid = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _resolve(world)
	var snap: Dictionary = _inference["snap"]
	if not _chain:
		_chain = true
		_anchor = pos
		_anchor_id = ""     # start point is created with the first segment
		_first_id = String(snap.get("id", "")) if snap.get("kind", "") == SnapEngine.KIND_POINT else ""
		return true
	_commit_segment(pos)
	return true


func _commit_segment(pos: Vector2) -> void:
	var sk := sketch()
	var snap: Dictionary = _inference["snap"]
	var snapped_point := String(snap.get("id", "")) \
		if snap.get("kind", "") == SnapEngine.KIND_POINT else ""
	var closing := snapped_point != "" and (snapped_point == _first_id
		or snapped_point == _anchor_id) and snapped_point != ""
	if pos.distance_to(_anchor) < 1e-6:
		return   # zero-length: ignore the click

	var entities: Array = []
	var constraints: Array = []

	# Chain start point (first segment only). If that very first click landed
	# on an existing point, the segment STARTS at that point — reusing its id,
	# not minting a twin beside it. `_first_id` was set from the same snap.
	var start_id := _anchor_id
	if start_id == "":
		if _first_id != "" and sk.has(_first_id):
			start_id = _first_id
		else:
			var sp := SketchPoint.make(_anchor)
			sp.id = sk.next_id()
			entities.append(sp)
			start_id = sp.id
			if _first_id == "":
				_first_id = start_id

	# Welding, Fusion-style: a click on an existing point ENDS THE SEGMENT ON
	# THAT POINT. Sharing the id is what makes both lines move together when it
	# is later dragged. The old shape here — a fresh twin point plus a
	# Coincident constraint — is not a weld: the two points are independent
	# variables that merely tend to agree, and a drag pins one and lets the
	# solver pull the other away, which is how joined shapes came apart.
	var end_id := ""
	if snapped_point != "" and sk.has(snapped_point) and snapped_point != start_id:
		end_id = snapped_point
	else:
		var ep := SketchPoint.make(pos)
		ep.id = sk.next_id()
		entities.append(ep)
		end_id = ep.id

	var line := SketchLine.make(start_id, end_id)
	line.id = sk.next_id()
	entities.append(line)

	# A snap the user SAW must become a constraint, or the join is cosmetic:
	# it looks attached and comes apart the moment anything moves. Welding
	# covers the endpoint case above; these are the other two snaps the engine
	# reports, and both previously set the POSITION and nothing else.
	#   - on a curve  -> POINT_ON, so the endpoint slides along that entity but
	#                    never leaves it.
	#   - on a midpoint -> MIDPOINT, so it tracks the middle as the line moves.
	# Skipped when the endpoint was welded, since it is then already tied to
	# real geometry and a second rule would only fight the first.
	if end_id != snapped_point:
		var owner := String(snap.get("owner", ""))
		match String(snap.get("kind", "")):
			SnapEngine.KIND_CURVE:
				if owner != "" and sk.has(owner):
					constraints.append(SketchConstraint.make(
						SketchConstraint.Type.POINT_ON, [end_id, owner]))
			SnapEngine.KIND_MID:
				if owner != "" and sk.has(owner):
					constraints.append(SketchConstraint.make(
						SketchConstraint.Type.MIDPOINT, [end_id, owner]))

	match String(_inference["axis"]):
		"h":
			constraints.append(SketchConstraint.make(
				SketchConstraint.Type.HORIZONTAL, [line.id]))
		"v":
			constraints.append(SketchConstraint.make(
				SketchConstraint.Type.VERTICAL, [line.id]))

	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction(entities), constraints))
	app.rebuild_snap_index()

	if closing:
		_reset()
	else:
		_anchor = pos
		_anchor_id = end_id


## Snap + infer: returns the resolved preview position and records
## _inference for the overlay and the commit.
func _resolve(world: Vector2) -> Vector2:
	var zoom := view().zoom()
	var tol := SnapEngine.TOL_PX / zoom
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	var s := app.snap.snap_point(world, tol, grid)
	var axis := ""
	var pos: Vector2 = s["pos"]
	var kind := String(s["kind"])
	var entity_snapped := kind != "" and kind != SnapEngine.KIND_GRID
	if _chain and not entity_snapped and app.prefs.get("inference", true):
		var d := world - _anchor
		if d.length() > 1e-6:
			var ang := absf(rad_to_deg(atan2(absf(d.y), absf(d.x))))
			if ang <= AXIS_DEG:
				axis = "h"
				pos.y = _anchor.y
				if grid > 0.0:
					pos.x = roundf(world.x / grid) * grid
				else:
					pos.x = world.x
			elif ang >= 90.0 - AXIS_DEG:
				axis = "v"
				pos.x = _anchor.x
				if grid > 0.0:
					pos.y = roundf(world.y / grid) * grid
				else:
					pos.y = world.y
	_inference = {"axis": axis, "snap": s if entity_snapped else {}}
	return pos


func draw_overlay(overlay: Control) -> void:
	if not _hover_valid:
		return
	var v := view()
	var p := v.world_to_screen(_preview)
	# Rubber-band segment.
	if _chain:
		preview_line(overlay, v.world_to_screen(_anchor), p,
			Color(1, 1, 1, 0.9), 1.0)
	# Snap marker.
	var snap: Dictionary = _inference["snap"]
	match String(snap.get("kind", "")):
		SnapEngine.KIND_POINT:
			overlay.draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)),
				Color(0.35, 0.9, 0.55), false, 2.0)
		SnapEngine.KIND_MID:
			overlay.draw_circle(p, 5.0, Color(0.35, 0.9, 0.55, 0.9))
		SnapEngine.KIND_CURVE:
			overlay.draw_circle(p, 4.0, Color(0.9, 0.75, 0.35, 0.9))
		_:
			overlay.draw_circle(p, 2.0, Color(1, 1, 1, 0.7))
	# Axis glyph near the preview midpoint.
	var axis := String(_inference["axis"])
	if axis != "" and _chain:
		var mid := v.world_to_screen((_anchor + _preview) * 0.5) + Vector2(8, -8)
		var font := ThemeDB.fallback_font
		overlay.draw_string(font, mid, "H" if axis == "h" else "V",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.35, 0.9, 0.55))
