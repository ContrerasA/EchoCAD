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
##              entities: Array[String],
##              holes: Array[PackedVector2Array] (ccw),
##              hole_entities: Array[String]}
## Faces are REGIONS, Fusion-style (M18): a loop lying wholly inside another
## with no connecting geometry is that face's HOLE — the containing face's
## `holes` lists it and `area` is net (outer minus holes). The inner loop is
## STILL its own face too, so clicking inside a hole picks the inner region
## and clicking the ring between them picks the outer-with-hole region.
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
			"spline":
				# A spline is a curved edge from its first to its last fit
				# point (M28); a CLOSED spline is its own loop like a circle.
				var sp := e as SketchSpline
				if sp.points.size() < 2:
					continue
				var spoly := sp.polyline(sk)
				if spoly.size() < 2:
					continue
				if sp.closed:
					var closed_poly := spoly.duplicate()
					if closed_poly[0].distance_to(
							closed_poly[closed_poly.size() - 1]) < MERGE_EPS:
						closed_poly.remove_at(closed_poly.size() - 1)
					out.append({"polygon": closed_poly,
						"area": _area(closed_poly), "entities": [e.id]})
					continue
				var nsa: String = find.call(sp.points[0])
				var nsb: String = find.call(sp.points[sp.points.size() - 1])
				if nsa == nsb:
					continue
				edges.append({"id": e.id, "a": nsa, "b": nsb, "poly": spoly})

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
	_attach_holes(out)
	return out


## Region pass: mark every face DIRECTLY contained in another as that face's
## hole. Containment only ever holds between DISCONNECTED loops (the half-edge
## walk already returns minimal faces within one component, and a hole bridged
## by real geometry traces as a single self-touching loop), so a vertex-inside
## test is exact here. "Directly": a loop inside a hole's island chain belongs
## to the island, not to the outermost face — standard even-odd nesting.
static func _attach_holes(faces: Array) -> void:
	var n := faces.size()
	var gross: Array = []
	for f: Dictionary in faces:
		gross.append(float(f["area"]))
		f["holes"] = []
		f["hole_entities"] = []
	var inside := {}      # "i:j" -> face j is inside face i
	for i in n:
		for j in n:
			if i == j or gross[j] >= gross[i]:
				continue
			var probe: Vector2 = (faces[j]["polygon"] as PackedVector2Array)[0]
			if Geometry2D.is_point_in_polygon(probe, faces[i]["polygon"]):
				inside["%d:%d" % [i, j]] = true
	for i in n:
		var net: float = gross[i]
		for j in n:
			if not inside.has("%d:%d" % [i, j]):
				continue
			var direct := true
			for k in n:
				if k != i and k != j and inside.has("%d:%d" % [i, k]) \
						and inside.has("%d:%d" % [k, j]):
					direct = false
					break
			if not direct:
				continue
			(faces[i]["holes"] as Array).append(faces[j]["polygon"])
			for eid in faces[j]["entities"]:
				(faces[i]["hole_entities"] as Array).append(eid)
			net -= gross[j]
		faces[i]["area"] = net


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


## Triangulate a region with holes by BRIDGING: each hole is spliced into the
## outer boundary through a doubled bridge edge (earcut's hole elimination),
## then the merged simple-but-self-touching polygon goes through the standard
## triangulator, which accepts it. -> {points: PackedVector2Array,
## indices: PackedInt32Array} (empty indices when triangulation fails).
static func triangulate_with_holes(outer: PackedVector2Array,
		holes: Array) -> Dictionary:
	var merged := outer.duplicate()
	if _area(merged) < 0.0:
		merged.reverse()
	var hs: Array = []
	for h in holes:
		var hp := (h as PackedVector2Array).duplicate()
		if _area(hp) > 0.0:
			hp.reverse()   # holes walk CW inside a CCW outer
		hs.append(hp)
	# Rightmost hole first: after each splice the bridge becomes part of the
	# outer boundary, so later (more-leftward) holes may bridge through it.
	hs.sort_custom(func(a: PackedVector2Array, b: PackedVector2Array) -> bool:
		return _max_x_of(a) > _max_x_of(b))
	for hp: PackedVector2Array in hs:
		merged = _splice_hole(merged, hp)
	return {"points": merged,
		"indices": Geometry2D.triangulate_polygon(merged)}


static func _max_x_of(poly: PackedVector2Array) -> float:
	var mx := -INF
	for p in poly:
		mx = maxf(mx, p.x)
	return mx


## Join `hole` (cw) into `outer` (ccw) with a doubled bridge edge from the
## hole's rightmost vertex to a mutually visible outer vertex (Eberly's
## ray-cast + reflex-in-triangle refinement).
static func _splice_hole(outer: PackedVector2Array,
		hole: PackedVector2Array) -> PackedVector2Array:
	var mi := 0
	for i in hole.size():
		if hole[i].x > hole[mi].x:
			mi = i
	var m := hole[mi]
	# Closest +x ray hit on the outer boundary (half-open y test so a ray
	# through a shared vertex counts one edge, not two).
	var best_t := INF
	var best_edge := -1
	var n := outer.size()
	for i in n:
		var a := outer[i]
		var b := outer[(i + 1) % n]
		if not ((a.y <= m.y and b.y > m.y) or (b.y <= m.y and a.y > m.y)):
			continue
		var x := a.x + (b.x - a.x) * (m.y - a.y) / (b.y - a.y)
		if x >= m.x - 1e-9 and x - m.x < best_t:
			best_t = x - m.x
			best_edge = i
	if best_edge < 0:
		return outer   # hole not actually inside — leave it out
	var hit := Vector2(m.x + best_t, m.y)
	# Candidate bridge vertex: the intersected edge's endpoint with max x.
	var e0 := outer[best_edge]
	var e1 := outer[(best_edge + 1) % n]
	var pi := best_edge if e0.x > e1.x else (best_edge + 1) % n
	# A reflex outer vertex inside triangle (m, hit, candidate) would block
	# the bridge; take the blocker closest in angle (then distance) to +x.
	var best_pi := pi
	var best_key := Vector2(INF, INF)
	for i in n:
		var prev := outer[(i - 1 + n) % n]
		var v := outer[i]
		var next := outer[(i + 1) % n]
		if (v - prev).cross(next - v) >= 0.0:
			continue   # convex
		if not Geometry2D.point_is_inside_triangle(v, m, hit, outer[pi]):
			continue
		var d := v - m
		var key := Vector2(absf(d.angle()), d.length())
		if key.x < best_key.x or (key.x == best_key.x and key.y < best_key.y):
			best_key = key
			best_pi = i
	pi = best_pi
	var out := PackedVector2Array()
	for i in pi + 1:
		out.append(outer[i])
	for k in hole.size() + 1:
		out.append(hole[(mi + k) % hole.size()])
	out.append(outer[pi])
	for i in range(pi + 1, n):
		out.append(outer[i])
	return out


## The REGION containing `at` (smallest containing outer wins). {} if none.
## A point inside one of a face's holes is not in that region — it falls
## through to the inner face, so clicking inside a drilled circle picks the
## circle, not the plate around it.
static func profile_at(sk: Sketch, at: Vector2) -> Dictionary:
	var best := {}
	var best_area := INF
	for prof: Dictionary in profiles(sk):
		if not Geometry2D.is_point_in_polygon(at, prof["polygon"]):
			continue
		var in_hole := false
		for h: PackedVector2Array in (prof["holes"] as Array):
			if Geometry2D.is_point_in_polygon(at, h):
				in_hole = true
				break
		if in_hole:
			continue
		if float(prof["area"]) < best_area:
			best = prof
			best_area = prof["area"]
	return best
