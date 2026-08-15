class_name ExtendTool
extends SketchTool
## Extend (X): click near a line's endpoint — that endpoint extends along
## the line's direction to the nearest intersection ahead. One undo step
## (a point move, so constraints re-solve).

const HIT_PX := 8.0

var _hover := false
var _preview := Vector2.ZERO
## {line, point_id, target} when the hover has a valid extension.
var _pending := {}


func _init() -> void:
	id = "extend"
	title = "Extend"
	shortcut = KEY_X


func activate() -> void:
	_hover = false
	_pending = {}


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	_pending = _find(world)
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	pointer_move(world, _screen, null)
	if _pending.is_empty():
		return true
	var batch := CmdMergeBatch.new("Extend", [])
	app.stack.push_no_merge(batch)
	app.stack.push(CmdMovePoints.new(app.active_sketch_id,
		{_pending["point_id"]: _pending["target"]}))
	app.solve_followers([_pending["point_id"]])
	batch.seal()
	_pending = {}
	app.rebuild_snap_index()
	return true


func _find(world: Vector2) -> Dictionary:
	var sk := sketch()
	var tol := HIT_PX / view().zoom()
	# Lines only (entity_at would prefer the endpoint itself).
	var line_id := ""
	var best_line := tol
	for cand in sk.entities():
		if cand.kind() != "line":
			continue
		var dd := SketchGeometry.distance_to_entity(sk, cand, world)
		if dd <= best_line:
			best_line = dd
			line_id = cand.id
	var l := sk.entity(line_id) as SketchLine
	if l == null:
		return {}
	var a := sk.point(l.p0)
	var b := sk.point(l.p1)
	# The endpoint nearer the cursor extends.
	var from_b := world.distance_to(b.pos) < world.distance_to(a.pos)
	var tip := b.pos if from_b else a.pos
	var dir := (b.pos - a.pos).normalized() if from_b else (a.pos - b.pos).normalized()
	if dir == Vector2.ZERO:
		return {}
	# Nearest intersection strictly ahead of the tip along dir.
	var far := tip + dir * 100000.0
	var best := INF
	var target := Vector2.ZERO
	for other in sk.entities():
		if other.id == line_id or other.kind() == "point":
			continue
		var pts: Array = []
		match other.kind():
			"line":
				var ol := other as SketchLine
				pts = SketchGeometry.intersect_segments(tip, far,
					sk.point(ol.p0).pos, sk.point(ol.p1).pos)
			"circle":
				var oc := other as SketchCircle
				pts = SketchGeometry.intersect_segment_circle(tip, far,
					sk.point(oc.center).pos, oc.radius)
			"arc":
				var oa := other as SketchArc
				var c := sk.point(oa.center).pos
				var raw := SketchGeometry.intersect_segment_circle(tip, far,
					c, c.distance_to(sk.point(oa.start).pos))
				for p: Vector2 in raw:
					if SketchGeometry.arc_contains_angle(sk, oa, (p - c).angle()):
						pts.append(p)
		for p: Vector2 in pts:
			var d := (p - tip).dot(dir)
			if d > 1e-6 and d < best:
				best = d
				target = p
	if not is_finite(best):
		return {}
	return {"line": line_id, "point_id": l.p1 if from_b else l.p0,
		"target": target}


func draw_overlay(overlay: Control) -> void:
	if not _hover or _pending.is_empty():
		return
	var sk := sketch()
	var v := view()
	var tip := sk.point(_pending["point_id"]).pos
	overlay.draw_line(v.world_to_screen(tip),
		v.world_to_screen(_pending["target"]),
		Color(0.35, 0.9, 0.55, 0.9), 2.0)
	overlay.draw_circle(v.world_to_screen(_pending["target"]), 4.0,
		Color(0.35, 0.9, 0.55))
