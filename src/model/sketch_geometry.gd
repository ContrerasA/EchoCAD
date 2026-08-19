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
		"spline":
			# Closest point on the tessellation — plenty for picking.
			var poly := (e as SketchSpline).polyline(sk)
			if poly.size() < 2:
				return {"ok": false}
			var best := poly[0]
			var best_d := INF
			for i in poly.size() - 1:
				var q := closest_on_segment(p, poly[i], poly[i + 1])
				var d2 := q.distance_to(p)
				if d2 < best_d:
					best_d = d2
					best = q
			return {"pos": best, "ok": true}
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


## Entity tessellated as a polyline in sketch mm (a point is one vertex).
static func entity_polyline(sk: Sketch, e: SketchEntity, segs := 32) -> PackedVector2Array:
	var out := PackedVector2Array()
	match e.kind():
		"point":
			out.append((e as SketchPoint).pos)
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0)
			var b := sk.point(l.p1)
			if a != null and b != null:
				out.append_array([a.pos, b.pos])
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center)
			if c != null:
				for k in segs + 1:
					var ang := TAU * k / segs
					out.append(c.pos + Vector2(cos(ang), sin(ang)) * ci.radius)
		"arc":
			var arc := e as SketchArc
			var c2 := sk.point(arc.center)
			var s := sk.point(arc.start)
			if c2 != null and s != null:
				var r := c2.pos.distance_to(s.pos)
				var a0 := (s.pos - c2.pos).angle()
				var sweep := arc_sweep(sk, arc)
				var n := maxi(4, int(ceil(absf(sweep) / (TAU / segs))))
				for k in n + 1:
					var ang2 := a0 + sweep * k / float(n)
					out.append(c2.pos + Vector2(cos(ang2), sin(ang2)) * r)
		"spline":
			out = (e as SketchSpline).polyline(sk)
	return out


## Marquee hit test (M20). `crossing` false = window select: the entity must
## lie ENTIRELY inside `rect`. `crossing` true = crossing select: touching
## the rect anywhere is enough.
static func entity_in_rect(sk: Sketch, e: SketchEntity, rect: Rect2,
		crossing: bool) -> bool:
	var poly := entity_polyline(sk, e)
	if poly.is_empty():
		return false
	if not crossing:
		for p in poly:
			if not rect.has_point(p):
				return false
		return true
	for p in poly:
		if rect.has_point(p):
			return true
	# No vertex inside — a segment may still cut across the rect.
	var corners: Array = [rect.position,
		rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size,
		rect.position + Vector2(0, rect.size.y)]
	for i in poly.size() - 1:
		for k in 4:
			if not intersect_segments(poly[i], poly[i + 1],
					corners[k], corners[(k + 1) % 4]).is_empty():
				return true
	return false


## Segment-segment intersection points (0 or 1).
static func intersect_segments(a1: Vector2, a2: Vector2, b1: Vector2,
		b2: Vector2) -> Array:
	var d1 := a2 - a1
	var d2 := b2 - b1
	var denom := d1.cross(d2)
	if absf(denom) < 1e-12:
		return []
	var t := (b1 - a1).cross(d2) / denom
	var u := (b1 - a1).cross(d1) / denom
	if t < -1e-9 or t > 1.0 + 1e-9 or u < -1e-9 or u > 1.0 + 1e-9:
		return []
	return [a1 + d1 * t]


## Segment-circle intersection points (0..2), optionally clamped to an arc's
## angular range via `arc` (SketchArc) + sketch.
static func intersect_segment_circle(a: Vector2, b: Vector2, c: Vector2,
		r: float) -> Array:
	var d := b - a
	var f := a - c
	var qa := d.dot(d)
	if qa < 1e-12:
		return []
	var qb := 2.0 * f.dot(d)
	var qc := f.dot(f) - r * r
	var disc := qb * qb - 4.0 * qa * qc
	if disc < 0.0:
		return []
	var sq := sqrt(disc)
	var out: Array = []
	for t in [(-qb - sq) / (2.0 * qa), (-qb + sq) / (2.0 * qa)]:
		if t >= -1e-9 and t <= 1.0 + 1e-9:
			var p: Vector2 = a + d * t
			if out.is_empty() or (out[0] as Vector2).distance_to(p) > 1e-9:
				out.append(p)
	return out


## Circle-circle intersection points (0..2).
static func intersect_circles(c1: Vector2, r1: float, c2: Vector2,
		r2: float) -> Array:
	var d := c1.distance_to(c2)
	if d < 1e-12 or d > r1 + r2 + 1e-9 or d < absf(r1 - r2) - 1e-9:
		return []
	var a := (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
	var h2 := r1 * r1 - a * a
	var h := sqrt(maxf(0.0, h2))
	var mid := c1 + (c2 - c1) * (a / d)
	var n := ((c2 - c1) / d).orthogonal()
	if h < 1e-9:
		return [mid]
	return [mid + n * h, mid - n * h]


## Is world angle `ang` inside the arc's swept range?
static func arc_contains_angle(sk: Sketch, arc: SketchArc, ang: float) -> bool:
	var c := sk.point(arc.center)
	var s := sk.point(arc.start)
	if c == null or s == null:
		return false
	var a0 := (s.pos - c.pos).angle()
	var sweep := arc_sweep(sk, arc)
	var rel := fposmod(ang - a0, TAU) if sweep >= 0.0 else -fposmod(a0 - ang, TAU)
	return absf(rel) <= absf(sweep) + 1e-9


## Every intersection point between entity `id` and all OTHER curve entities.
static func entity_intersections(sk: Sketch, id: String) -> Array:
	var out: Array = []
	for hit: Dictionary in entity_intersections_ex(sk, id):
		out.append(hit["pos"])
	return out


## Like entity_intersections, but each hit carries WHICH entity produced it:
## [{"pos": Vector2, "other": String}]. Trim/extend use the source to tie the
## new endpoint onto the cutting entity with a POINT_ON constraint.
static func entity_intersections_ex(sk: Sketch, id: String) -> Array:
	var e := sk.entity(id)
	if e == null:
		return []
	var out: Array = []
	for other in sk.entities():
		if other.id == id or other.kind() == "point":
			continue
		for p in _intersect_pair(sk, e, other):
			out.append({"pos": p, "other": other.id})
	return out


static func _curve_params(sk: Sketch, e: SketchEntity) -> Dictionary:
	match e.kind():
		"line":
			var l := e as SketchLine
			return {"kind": "line", "a": sk.point(l.p0).pos, "b": sk.point(l.p1).pos}
		"circle":
			var ci := e as SketchCircle
			return {"kind": "circle", "c": sk.point(ci.center).pos, "r": ci.radius}
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center).pos
			return {"kind": "arc", "c": c,
				"r": c.distance_to(sk.point(arc.start).pos), "arc": arc}
	return {}


static func _intersect_pair(sk: Sketch, e1: SketchEntity, e2: SketchEntity) -> Array:
	var p1 := _curve_params(sk, e1)
	var p2 := _curve_params(sk, e2)
	if p1.is_empty() or p2.is_empty():
		return []
	var raw: Array = []
	if p1["kind"] == "line" and p2["kind"] == "line":
		raw = intersect_segments(p1["a"], p1["b"], p2["a"], p2["b"])
	elif p1["kind"] == "line":
		raw = intersect_segment_circle(p1["a"], p1["b"], p2["c"], p2["r"])
	elif p2["kind"] == "line":
		raw = intersect_segment_circle(p2["a"], p2["b"], p1["c"], p1["r"])
	else:
		raw = intersect_circles(p1["c"], p1["r"], p2["c"], p2["r"])
	# Clamp to arc ranges where applicable.
	var out: Array = []
	for p: Vector2 in raw:
		var ok := true
		for spec in [p1, p2]:
			if spec["kind"] == "arc" and not arc_contains_angle(sk,
					spec["arc"], (p - (spec["c"] as Vector2)).angle()):
				ok = false
		if ok:
			out.append(p)
	return out


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
