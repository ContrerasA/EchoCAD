class_name SketchGeometry
extends RefCounted
## Render-independent geometry queries over typed entities (static + pure).
## All distances in sketch mm.


static func closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 1e-12:
		return a
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return a + ab * t


## Arc sweep from start angle in the arc's winding direction (radians,
## positive ccw / negative cw).
static func arc_sweep(sk: Sketch, arc: SketchArc) -> float:
	var c := sk.point(arc.center)
	var s := sk.point(arc.start)
	var e := sk.point(arc.end)
	if c == null or s == null or e == null:
		return 0.0
	var a0 := (s.pos - c.pos).angle()
	var sweep := (e.pos - c.pos).angle() - a0
	if arc.ccw and sweep < 0.0:
		sweep += TAU
	elif not arc.ccw and sweep > 0.0:
		sweep -= TAU
	return sweep


## Closest point ON an entity's curve to `p` (INF distance when degenerate).
static func closest_on_entity(sk: Sketch, e: SketchEntity, p: Vector2) -> Dictionary:
	match e.kind():
		"point":
			return {"pos": (e as SketchPoint).pos, "ok": true}
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0)
			var b := sk.point(l.p1)
			if a == null or b == null:
				return {"ok": false}
			return {"pos": closest_on_segment(p, a.pos, b.pos), "ok": true}
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center)
			if c == null:
				return {"ok": false}
			var d := p - c.pos
			if d.length() < 1e-9:
				d = Vector2.RIGHT
			return {"pos": c.pos + d.normalized() * ci.radius, "ok": true}
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center)
			var s := sk.point(arc.start)
			if c == null or s == null:
				return {"ok": false}
			var r := c.pos.distance_to(s.pos)
			var a0 := (s.pos - c.pos).angle()
			var sweep := arc_sweep(sk, arc)
			var ang := (p - c.pos).angle()
			# Angle within the swept range? Normalize into the sweep direction.
			var rel := wrapf(ang - a0, -PI, PI)
			if sweep >= 0.0:
				rel = fposmod(ang - a0, TAU)
				if rel > sweep:
					rel = sweep if absf(rel - sweep) < absf(rel - TAU) else 0.0
			else:
				rel = -fposmod(a0 - ang, TAU)
				if rel < sweep:
					rel = sweep if absf(rel - sweep) < absf(rel + TAU) else 0.0
			var at := a0 + rel
			return {"pos": c.pos + Vector2(cos(at), sin(at)) * r, "ok": true}
	return {"ok": false}


static func distance_to_entity(sk: Sketch, e: SketchEntity, p: Vector2) -> float:
	var r := closest_on_entity(sk, e, p)
	if not r.get("ok", false):
		return INF
	return (r["pos"] as Vector2).distance_to(p)


## Topmost entity within `tol` of `p` (points win over curves; later
## entities win ties). Returns "" when nothing hits.
static func entity_at(sk: Sketch, p: Vector2, tol: float) -> String:
	var best := ""
	var best_d := INF
	var best_is_point := false
	for e in sk.entities():
		var d := distance_to_entity(sk, e, p)
		if d > tol:
			continue
		var is_point := e.kind() == "point"
		# Points get priority at equal footing (they're small targets).
		if is_point and not best_is_point:
			if d <= tol:
				best = e.id
				best_d = d
				best_is_point = true
			continue
		if best_is_point and not is_point:
			continue
		if d <= best_d:
			best = e.id
			best_d = d
			best_is_point = is_point
	return best


## Circumcenter of three points ({pos, radius, ok}; ok=false when collinear).
static func circumcircle(a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 1e-9:
		return {"ok": false}
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	var center := Vector2(
		(a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
		(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
	return {"ok": true, "pos": center, "radius": center.distance_to(a)}


## Midpoint of a line entity (Dictionary {pos, ok}).
static func line_midpoint(sk: Sketch, l: SketchLine) -> Dictionary:
	var a := sk.point(l.p0)
	var b := sk.point(l.p1)
	if a == null or b == null:
		return {"ok": false}
	return {"pos": (a.pos + b.pos) * 0.5, "ok": true}
