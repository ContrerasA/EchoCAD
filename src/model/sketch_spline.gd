class_name SketchSpline
extends SketchEntity
## A cubic bezier chain through N fit points (SketchPoint ids). The fit
## points are ordinary sketch points — draggable, constrainable, solver
## variables — so the curve follows the solve for free. Tangents are DERIVED
## (Catmull-Rom from the neighbours) unless a fit point carries an explicit
## handle override (set by dragging its handle in the editor).
##
## Typed entity per the project rule: the model stores fit points + handle
## overrides only; bezier flattening happens at the consumers (render path,
## profile tessellation, hit testing) — never ahead of time in the model.
## The static *positions* helpers run the same math on raw Vector2s so tool
## previews show exactly the curve that will commit.

var points: Array[String] = []
## Parallel to `points`: null = auto tangent, or a Vector2 OUT-tangent (mm).
## The IN tangent at a point mirrors the OUT tangent (G1-smooth).
var handles: Array = []
var closed := false

## Flatness tolerance for tessellation, mm. One value everywhere so the
## profile a region is built from matches what was drawn on screen.
const FLAT_TOL := 0.05
const MAX_DEPTH := 10


static func make(pt_ids: Array, is_closed := false) -> SketchSpline:
	var e := SketchSpline.new()
	for id in pt_ids:
		e.points.append(String(id))
	e.handles.resize(e.points.size())
	e.closed = is_closed
	return e


func kind() -> String:
	return "spline"


func point_refs() -> Array[String]:
	return points.duplicate()


## Fit point positions in order; [] when any referenced point is missing.
func fit_positions(sk: Sketch) -> Array:
	var ps: Array = []
	for id in points:
		var p := sk.point(id)
		if p == null:
			return []
		ps.append(p.pos)
	return ps


## OUT-tangent at fit point `i` (mm).
func tangent_at(sk: Sketch, i: int) -> Vector2:
	var ps := fit_positions(sk)
	if ps.is_empty():
		return Vector2.ZERO
	return tangent_for(ps, handles, i, closed)


## The four bezier control points of span `i` (fit point i -> i+1, wrapping
## when closed). [] when a referenced point is missing.
func span(sk: Sketch, i: int) -> Array:
	var ps := fit_positions(sk)
	if ps.is_empty():
		return []
	return span_for(ps, handles, i, closed)


func span_count() -> int:
	if points.size() < 2:
		return 0
	return points.size() if closed else points.size() - 1


## Adaptive tessellation of the whole chain, first fit point to last.
func polyline(sk: Sketch, tol := FLAT_TOL) -> PackedVector2Array:
	var ps := fit_positions(sk)
	return positions_polyline(ps, handles, closed, tol)


## --- static core (shared with tool previews) --------------------------------

## Catmull-Rom tangent from the neighbours, or the explicit override.
static func tangent_for(ps: Array, hs: Array, i: int, is_closed: bool) -> Vector2:
	if i >= 0 and i < hs.size() and hs[i] is Vector2:
		return hs[i]
	var n := ps.size()
	if n < 2:
		return Vector2.ZERO
	var prev: Vector2 = ps[(i - 1 + n) % n] if is_closed else ps[maxi(i - 1, 0)]
	var next: Vector2 = ps[(i + 1) % n] if is_closed else ps[mini(i + 1, n - 1)]
	return (next - prev) * 0.5


static func span_for(ps: Array, hs: Array, i: int, is_closed: bool) -> Array:
	var n := ps.size()
	var a: Vector2 = ps[i]
	var b: Vector2 = ps[(i + 1) % n]
	var ta := tangent_for(ps, hs, i, is_closed)
	var tb := tangent_for(ps, hs, (i + 1) % n, is_closed)
	return [a, a + ta / 3.0, b - tb / 3.0, b]


static func positions_polyline(ps: Array, hs: Array, is_closed: bool,
		tol := FLAT_TOL) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := ps.size()
	if n < 2:
		return out
	var spans := n if is_closed else n - 1
	out.append(ps[0])
	for i in spans:
		var cp := span_for(ps, hs, i, is_closed)
		_flatten(cp[0], cp[1], cp[2], cp[3], tol, 0, out)
	return out


static func _flatten(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2,
		tol: float, depth: int, out: PackedVector2Array) -> void:
	# Flat enough when both control points sit within tol of the chord.
	var d := p3 - p0
	var len2 := d.length_squared()
	var flat := false
	if len2 < 1e-12:
		flat = p1.distance_to(p0) < tol and p2.distance_to(p0) < tol
	else:
		var d1 := absf(d.cross(p1 - p0)) / sqrt(len2)
		var d2 := absf(d.cross(p2 - p0)) / sqrt(len2)
		flat = d1 < tol and d2 < tol
	if flat or depth >= MAX_DEPTH:
		out.append(p3)
		return
	# de Casteljau split at t = 0.5.
	var q0 := (p0 + p1) * 0.5
	var q1 := (p1 + p2) * 0.5
	var q2 := (p2 + p3) * 0.5
	var r0 := (q0 + q1) * 0.5
	var r1 := (q1 + q2) * 0.5
	var s := (r0 + r1) * 0.5
	_flatten(p0, q0, r0, s, tol, depth + 1, out)
	_flatten(s, r1, q2, p3, tol, depth + 1, out)


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["points"] = points.duplicate()
	var hs: Array = []
	for h in handles:
		hs.append([h.x, h.y] if h is Vector2 else null)
	d["handles"] = hs
	d["closed"] = closed
	return d


static func from_dict(d: Dictionary) -> SketchSpline:
	var e := SketchSpline.new()
	e._read_base(d)
	for id in d.get("points", []):
		e.points.append(String(id))
	for h in d.get("handles", []):
		e.handles.append(Vector2(float(h[0]), float(h[1])) if h is Array else null)
	while e.handles.size() < e.points.size():
		e.handles.append(null)
	e.closed = bool(d.get("closed", false))
	return e
