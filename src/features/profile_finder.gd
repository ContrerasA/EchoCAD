class_name ProfileFinder
extends RefCounted
## Closed-profile detection over a sketch (static + pure): builds a planar
## graph — nodes are point clusters (points merged by COINCIDENT constraints
## or identical position), edges are non-construction lines/arcs — and
## traces faces with the standard smallest-left-turn half-edge walk. Full
## circles are their own loops. Returns ccw polygons ready for
## triangulation/extrusion. Construction geometry never participates.

const MERGE_EPS := 0.001     # mm — coincident cluster tolerance
const ARC_SEGS := 32         # tessellation for arcs/circles


## -> Array of {polygon: PackedVector2Array (ccw), area: float,
##              entities: Array[String]}
static func profiles(sk: Sketch) -> Array:
	var out: Array = []

	# --- node clustering: union-find over points.
	var parent := {}
	for e in sk.entities():
		if e.kind() == "point":
			parent[e.id] = e.id
	var find := func(id: String) -> String:
		var r := id
		while parent[r] != r:
			r = parent[r]
		return r
	var union := func(a: String, b: String) -> void:
		var ra: String = find.call(a)
		var rb: String = find.call(b)
		if ra != rb:
			parent[rb] = ra
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.COINCIDENT \
				and c.operands.size() == 2 \
				and parent.has(c.operands[0]) and parent.has(c.operands[1]):
			union.call(c.operands[0], c.operands[1])
	# Same-position merge (chained tools share ids already; this catches
	# drawn-on-top geometry).
	var ids: Array = parent.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var pi := sk.point(ids[i])
			var pj := sk.point(ids[j])
			if pi != null and pj != null \
					and pi.pos.distance_to(pj.pos) < MERGE_EPS:
				union.call(ids[i], ids[j])

	# --- edges (lines and arcs); circles handled separately.
	var edges: Array = []    # {id, a, b, poly: PackedVector2Array a->b}
	for e in sk.entities():
		if e.construction:
			continue
		match e.kind():
			"line":
				var l := e as SketchLine
				var na: String = find.call(l.p0)
				var nb: String = find.call(l.p1)
				if na == nb:
					continue
				edges.append({"id": e.id, "a": na, "b": nb,
					"poly": PackedVector2Array(
						[sk.point(l.p0).pos, sk.point(l.p1).pos])})
			"arc":
				var arc := e as SketchArc
				var na2: String = find.call(arc.start)
				var nb2: String = find.call(arc.end)
				if na2 == nb2:
					continue
				edges.append({"id": e.id, "a": na2, "b": nb2,
					"poly": _arc_poly(sk, arc)})
			"circle":
				var ci := e as SketchCircle
				var cc := sk.point(ci.center)
				if cc == null or ci.radius < MERGE_EPS:
					continue
				var poly := PackedVector2Array()
				for k in ARC_SEGS:
					var ang := TAU * k / ARC_SEGS
					poly.append(cc.pos + Vector2(cos(ang), sin(ang)) * ci.radius)
				out.append({"polygon": poly, "area": _area(poly),
					"entities": [e.id]})

	# --- half-edge face tracing.
	var node_pos := {}
	for id: String in parent:
		var r: String = find.call(id)
		if not node_pos.has(r):
			node_pos[r] = sk.point(id).pos
	# Directed half-edges: (edge index, forward?) with used set.
	var used := {}
	for ei in edges.size():
		for fwd in [true, false]:
			var key := "%d:%s" % [ei, fwd]
			if used.has(key):
				continue
			var loop_entities: Array = []
			var loop_poly := PackedVector2Array()
			var cur_e := ei
			var cur_f: bool = fwd
			var ok := true
			var guard := 0
			while true:
				guard += 1
				if guard > edges.size() * 2 + 2:
					ok = false
					break
				used["%d:%s" % [cur_e, cur_f]] = true
				var ed: Dictionary = edges[cur_e]
				loop_entities.append(ed["id"])
				var seg: PackedVector2Array = ed["poly"]
				if cur_f:
					for k in seg.size() - 1:
						loop_poly.append(seg[k])
				else:
					for k in range(seg.size() - 1, 0, -1):
						loop_poly.append(seg[k])
				var arrive: String = ed["b"] if cur_f else ed["a"]
				# Incoming direction at the node.
				var pcount := seg.size()
				var in_dir: Vector2
				if cur_f:
					in_dir = (seg[pcount - 1] - seg[pcount - 2]).normalized()
				else:
					in_dir = (seg[0] - seg[1]).normalized()
				# Pick the outgoing half-edge with the smallest CCW turn
				# (most counter-clockwise) — traces faces to the left.
				var best := -1
				var best_f := true
				var best_turn := INF
				for oj in edges.size():
					var oe: Dictionary = edges[oj]
					for of in [true, false]:
						var from_n: String = oe["a"] if of else oe["b"]
						if from_n != arrive:
							continue
						if oj == cur_e and of != cur_f and edges.size() > 1 \
								and _has_other_out(edges, arrive, cur_e):
							continue   # avoid immediate U-turn when avoidable
						var op: PackedVector2Array = oe["poly"]
						var out_dir: Vector2
						if of:
							out_dir = (op[1] - op[0]).normalized()
						else:
							out_dir = (op[op.size() - 2] - op[op.size() - 1]).normalized()
						var turn := fposmod((-in_dir).angle_to(out_dir), TAU)
						if turn < 1e-9:
							turn = TAU
						if turn < best_turn:
							best_turn = turn
							best = oj
							best_f = of
				if best < 0:
					ok = false
					break
				cur_e = best
				cur_f = best_f
				if cur_e == ei and cur_f == fwd:
					break
			if not ok or loop_poly.size() < 3:
				continue
			var area := _area(loop_poly)
			# Keep ccw faces only (cw trace = the unbounded outer face).
			if area > MERGE_EPS:
				out.append({"polygon": loop_poly, "area": area,
					"entities": loop_entities})
	return out


static func _has_other_out(edges: Array, node: String, not_edge: int) -> bool:
	for j in edges.size():
		if j == not_edge:
			continue
		var e: Dictionary = edges[j]
		if e["a"] == node or e["b"] == node:
			return true
	return false


static func _arc_poly(sk: Sketch, arc: SketchArc) -> PackedVector2Array:
	var c := sk.point(arc.center).pos
	var s := sk.point(arc.start).pos
	var r := c.distance_to(s)
	var a0 := (s - c).angle()
	var sweep := SketchGeometry.arc_sweep(sk, arc)
	var n := maxi(4, int(ceil(absf(sweep) / (TAU / ARC_SEGS))))
	var out := PackedVector2Array()
	for k in n + 1:
		var ang := a0 + sweep * k / float(n)
		out.append(c + Vector2(cos(ang), sin(ang)) * r)
	# Endpoints exactly on the stored points so node walks stitch cleanly.
	out[0] = s
	out[out.size() - 1] = sk.point(arc.end).pos
	return out


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.cross(q)
	return a * 0.5


## The profile containing `at` (smallest containing area wins). {} if none.
static func profile_at(sk: Sketch, at: Vector2) -> Dictionary:
	var best := {}
	var best_area := INF
	for prof: Dictionary in profiles(sk):
		if Geometry2D.is_point_in_polygon(at, prof["polygon"]) \
				and float(prof["area"]) < best_area:
			best = prof
			best_area = prof["area"]
	return best
