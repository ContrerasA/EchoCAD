class_name SweepFeature
extends SolidFeature
## M34 sweep: a profile region (anchor uv in its sketch, extrude-style)
## swept along a PATH — a connected chain of lines/arcs/splines in another
## sketch, named by any one entity on it (the chain walks shared
## endpoints). Frames by parallel transport (no twist); the profile rides
## each frame at its drawn offset from the path start. Holes sweep as inner
## wall loops; both ends get caps. Refuses bends tighter than the profile's
## radial extent (self-intersection).

var sketch_id := ""          # profile sketch
var anchor := Vector2.ZERO
var path_sketch := ""
var path_entity := ""        # any entity on the path chain

## Sampling step for path polylines, mm-ish (curves already tessellate).
const MIN_SEG_MM := 0.01


static func make(p_sketch: String, p_anchor: Vector2, p_path_sketch: String,
		p_path_entity: String, op := OP_NEW_BODY) -> SweepFeature:
	var f := SweepFeature.new()
	f.sketch_id = p_sketch
	f.anchor = p_anchor
	f.path_sketch = p_path_sketch
	f.path_entity = p_path_entity
	f.operation = op
	return f


func kind() -> String:
	return "sweep"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["sketch"] = sketch_id
	d["anchor"] = [anchor.x, anchor.y]
	d["path_sketch"] = path_sketch
	d["path_entity"] = path_entity
	d["operation"] = operation
	return d


static func from_dict(d: Dictionary) -> SweepFeature:
	var f := SweepFeature.new()
	f._read_base(d)
	f.sketch_id = String(d.get("sketch", ""))
	var a: Array = d.get("anchor", [0, 0])
	f.anchor = Vector2(float(a[0]), float(a[1]))
	f.path_sketch = String(d.get("path_sketch", ""))
	f.path_entity = String(d.get("path_entity", ""))
	f.operation = String(d.get("operation", OP_NEW_BODY))
	return f


## The ordered 2D polyline of the path chain in ITS sketch (open chains
## only — a closed loop has no free end to start from and is refused).
## [] when anything is missing.
static func path_polyline(sk: Sketch, seed: String) -> PackedVector2Array:
	var seed_e := sk.entity(seed)
	if seed_e == null or seed_e.kind() in ["point", "circle"]:
		return PackedVector2Array()
	# Chain membership: entities reachable through shared END points.
	var ends := func(e: SketchEntity) -> Array:
		match e.kind():
			"line":
				return [(e as SketchLine).p0, (e as SketchLine).p1]
			"arc":
				return [(e as SketchArc).start, (e as SketchArc).end]
			"spline":
				var sp := e as SketchSpline
				if sp.closed or sp.points.size() < 2:
					return []
				return [sp.points[0], sp.points[sp.points.size() - 1]]
		return []
	var members := {seed: true}
	var grew := true
	while grew:
		grew = false
		var pts := {}
		for id in members:
			for pid in ends.call(sk.entity(id)):
				pts[pid] = true
		for e in sk.entities():
			if members.has(e.id) or e.construction:
				continue
			for pid in ends.call(e):
				if pts.has(pid):
					members[e.id] = true
					grew = true
					break
	# Point -> entities adjacency; start from a degree-1 end.
	var adj := {}
	for id in members:
		for pid in ends.call(sk.entity(id)):
			if not adj.has(pid):
				adj[pid] = []
			(adj[pid] as Array).append(id)
	var start_pid := ""
	for pid in adj:
		if (adj[pid] as Array).size() == 1:
			start_pid = pid
			break
	if start_pid == "":
		return PackedVector2Array()   # loop or degenerate
	# Walk the chain, appending each entity's polyline oriented forward.
	var out := PackedVector2Array()
	var cur_pid := start_pid
	var used := {}
	while true:
		var next_e := ""
		for id in (adj.get(cur_pid, []) as Array):
			if not used.has(id):
				next_e = id
				break
		if next_e == "":
			break
		used[next_e] = true
		var e := sk.entity(next_e)
		var poly := SketchGeometry.entity_polyline(sk, e)
		var epts: Array = ends.call(e)
		var fwd: bool = String(epts[0]) == cur_pid
		if not fwd:
			poly.reverse()
		var from := 1 if not out.is_empty() else 0
		for i in range(from, poly.size()):
			if out.is_empty() or out[out.size() - 1].distance_to(poly[i]) \
					> MIN_SEG_MM:
				out.append(poly[i])
		cur_pid = String(epts[1] if fwd else epts[0])
	return out


## Everything build_mesh needs, resolved once. {} = failure (reason in
## "error" when partial).
func _resolve(doc: CadDocument) -> Dictionary:
	var sf := doc.sketch_feature(sketch_id)
	var pf := doc.sketch_feature(path_sketch)
	if sf == null or pf == null:
		return {}
	var prof := ProfileFinder.profile_at(sf.sketch, anchor)
	if prof.is_empty():
		return {}
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	if ExtrudeFeature._signed_area(poly) < 0.0:
		poly.reverse()
	var holes_cw: Array = []
	for h in (prof.get("holes", []) as Array):
		var hp := (h as PackedVector2Array).duplicate()
		if ExtrudeFeature._signed_area(hp) > 0.0:
			hp.reverse()
		holes_cw.append(hp)
	var path2 := path_polyline(pf.sketch, path_entity)
	if path2.size() < 2:
		return {}
	var pxf := pf.plane_transform()
	var path3 := PackedVector3Array()
	for p in path2:
		path3.append(pxf * Vector3(p.x, p.y, 0.0))
	return {"poly": poly, "holes": holes_cw, "prof": prof,
		"profile_xf": sf.plane_transform(), "path": path3}


## Per-SEGMENT parallel-transported frames: [{x, y, t}] for each of the
## path's n-1 segments (x carried across joints by minimal rotation).
static func _segment_frames(path: PackedVector3Array,
		x_hint: Vector3) -> Array:
	var out: Array = []
	var x := Vector3.ZERO
	for j in path.size() - 1:
		var t := (path[j + 1] - path[j]).normalized()
		if j == 0:
			x = x_hint - t * x_hint.dot(t)
			if x.length() < 1e-6:
				x = t.cross(Vector3(0, 0, 1))
				if x.length() < 1e-6:
					x = t.cross(Vector3(0, 1, 0))
			x = x.normalized()
		else:
			var t_prev: Vector3 = out[j - 1]["t"]
			var axis := t_prev.cross(t)
			if axis.length() > 1e-9:
				x = x.rotated(axis.normalized(), t_prev.angle_to(t))
			x = (x - t * x.dot(t)).normalized()
		out.append({"x": x, "y": t.cross(x).normalized(), "t": t})
	return out


## One ring set per path JOINT: joints[j][ring_index] is that ring's 3D
## polygon at joint j. Interior joints slice the incoming leg's prism by
## the miter plane (exact corners). [] on degenerate projection.
static func _joint_rings(path: PackedVector3Array, profile_xf: Transform3D,
		s_uv: Vector2, rings: Array) -> Array:
	var segs := _segment_frames(path, profile_xf.basis.x)
	var out: Array = []
	for j in path.size():
		# Interior joints use the INCOMING leg's frame (j-1).
		var fr: Dictionary = segs[maxi(j - 1, 0)] if j > 0 else segs[0]
		var t_in: Vector3 = fr["t"]
		var n_m := t_in
		if j > 0 and j < path.size() - 1:
			n_m = (t_in + (segs[j]["t"] as Vector3)).normalized()
			if n_m.length() < 1e-6 or absf(t_in.dot(n_m)) < 1e-3:
				return []   # hairpin: projection degenerate
		var per_ring: Array = []
		for ring: PackedVector2Array in rings:
			var r3 := PackedVector3Array()
			for p in ring:
				var q: Vector3 = path[j] + (fr["x"] as Vector3) * (p.x - s_uv.x) \
					+ (fr["y"] as Vector3) * (p.y - s_uv.y)
				if j > 0 and j < path.size() - 1:
					# Slide along the incoming tangent onto the miter plane.
					q += t_in * ((path[j] - q).dot(n_m) / t_in.dot(n_m))
				r3.append(q)
			per_ring.append(r3)
		out.append(per_ring)
	return out


## Tightest bend radius along the path (INF for straight).
static func min_bend_radius(path: PackedVector3Array) -> float:
	var best := INF
	for i in range(1, path.size() - 1):
		var v1 := path[i] - path[i - 1]
		var v2 := path[i + 1] - path[i]
		var ang := v1.angle_to(v2)
		if ang < 1e-4:
			continue
		var l := minf(v1.length(), v2.length())
		best = minf(best, l / (2.0 * tan(ang * 0.5)))
	return best


func build_mesh(doc: CadDocument) -> ArrayMesh:
	var res := _resolve(doc)
	if res.is_empty():
		return null
	var poly: PackedVector2Array = res["poly"]
	var holes: Array = res["holes"]
	var path: PackedVector3Array = res["path"]
	var profile_xf: Transform3D = res["profile_xf"]

	# Profile coords relative to the path start, in the profile plane.
	var s_local := profile_xf.affine_inverse() * path[0]
	var s_uv := Vector2(s_local.x, s_local.y)
	var max_ext := 0.0
	var rings: Array = [poly]
	rings.append_array(holes)
	for ring: PackedVector2Array in rings:
		for p in ring:
			max_ext = maxf(max_ext, (p - s_uv).length())
	if min_bend_radius(path) < max_ext:
		return null   # would self-intersect; callers report the refusal

	# Per-SEGMENT transported frames + exact miter joints: the ring at an
	# interior joint is the previous leg's prism sliced by the miter plane
	# (projecting along the leg's tangent). Plain averaged-tangent frames
	# pinch corners — an L sweep lost ~15% of its corner volume that way.
	var joints := _joint_rings(path, profile_xf, s_uv, rings)
	if joints.is_empty():
		return null

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for ri in rings.size():
		var ring: PackedVector2Array = rings[ri]
		for ji in joints.size() - 1:
			var r0: PackedVector3Array = joints[ji][ri]
			var r1: PackedVector3Array = joints[ji + 1][ri]
			for i in ring.size():
				var a0 := r0[i]
				var b0 := r0[(i + 1) % ring.size()]
				var a1 := r1[i]
				var b1 := r1[(i + 1) % ring.size()]
				verts.append_array([a0, b0, b1, a0, b1, a1])
				var wn := ((b0 - a0).cross(b1 - a0)).normalized()
				for _i in 6:
					normals.append(wn)
	# Caps: triangulate the 2D profile, then map through the end joints.
	# Cap points may include hole-bridge steiner points, so map by frame,
	# not by ring index: rebuild the end frames.
	var tri := ProfileFinder.triangulate_with_holes(poly, res["prof"].get(
		"holes", []))
	var cap_pts: PackedVector2Array = tri["points"]
	var idx: PackedInt32Array = tri["indices"]
	var segs := _segment_frames(path, profile_xf.basis.x)
	var first: Dictionary = segs[0]
	var last: Dictionary = segs[segs.size() - 1]
	var at_first := func(p: Vector2) -> Vector3:
		return path[0] + (first["x"] as Vector3) * (p.x - s_uv.x) \
			+ (first["y"] as Vector3) * (p.y - s_uv.y)
	var at_last := func(p: Vector2) -> Vector3:
		return path[path.size() - 1] \
			+ (last["x"] as Vector3) * (p.x - s_uv.x) \
			+ (last["y"] as Vector3) * (p.y - s_uv.y)
	for t in range(0, idx.size(), 3):
		var tri_pts: Array = [cap_pts[idx[t]], cap_pts[idx[t + 1]],
			cap_pts[idx[t + 2]]]
		for p: Vector2 in [tri_pts[0], tri_pts[2], tri_pts[1]]:
			verts.append(at_first.call(p))
		for _i in 3:
			normals.append(-(first["t"] as Vector3))
		for p: Vector2 in tri_pts:
			verts.append(at_last.call(p))
		for _i in 3:
			normals.append(last["t"] as Vector3)

	_orient_outward(verts, normals)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Edge overlay: ring outlines at both ends.
	var edges := PackedVector3Array()
	for ring: PackedVector2Array in rings:
		for i in ring.size():
			var a2 := ring[i]
			var b2 := ring[(i + 1) % ring.size()]
			edges.append_array([at_first.call(a2), at_first.call(b2)])
			edges.append_array([at_last.call(a2), at_last.call(b2)])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


## Winding safety net shared by sweep + loft: if the assembled solid's
## signed volume is negative, every face points inward — flip them all.
static func _orient_outward(verts: PackedVector3Array,
		normals: PackedVector3Array) -> void:
	var vol := 0.0
	var t := 0
	while t + 2 < verts.size():
		vol += verts[t].cross(verts[t + 1]).dot(verts[t + 2])
		t += 3
	if vol >= 0.0:
		return
	t = 0
	while t + 2 < verts.size():
		var tmp := verts[t + 1]
		verts[t + 1] = verts[t + 2]
		verts[t + 2] = tmp
		t += 3
	for i in normals.size():
		normals[i] = -normals[i]


func solid_part(doc: CadDocument) -> Dictionary:
	var mesh := build_mesh(doc)
	if mesh == null:
		return {}
	return {"feature": self, "mesh": mesh,
		"aabb": mesh.get_aabb().grow(0.001)}


func csg_node(part: Dictionary) -> CSGShape3D:
	var node := CSGMesh3D.new()
	var src: ArrayMesh = part["mesh"]
	# CSG wants the closed shell only — the line overlay surface confuses it.
	var solid := ArrayMesh.new()
	solid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
		src.surface_get_arrays(0))
	node.mesh = solid
	return node
