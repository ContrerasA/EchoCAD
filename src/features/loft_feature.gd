class_name LoftFeature
extends SolidFeature
## M34 loft: 2+ profile sections on different planes, side walls ruled
## between consecutive sections. Boundary loops resample to a common vertex
## count; correspondence picks the start offset (and direction) minimizing
## twist. Straight-line correspondence, outer loops only — sections with
## holes are refused (documented this round).

## sections: [{"sketch": id, "at": Vector2}]
var sections: Array = []

const RING_SAMPLES := 64


static func make(p_sections: Array, op := OP_NEW_BODY) -> LoftFeature:
	var f := LoftFeature.new()
	f.sections = p_sections.duplicate(true)
	f.operation = op
	return f


func kind() -> String:
	return "loft"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	var s: Array = []
	for sec: Dictionary in sections:
		s.append({"sketch": sec["sketch"],
			"at": [(sec["at"] as Vector2).x, (sec["at"] as Vector2).y]})
	d["sections"] = s
	d["operation"] = operation
	return d


static func from_dict(d: Dictionary) -> LoftFeature:
	var f := LoftFeature.new()
	f._read_base(d)
	for sec in d.get("sections", []):
		var a: Array = (sec as Dictionary).get("at", [0, 0])
		f.sections.append({"sketch": String((sec as Dictionary)["sketch"]),
			"at": Vector2(float(a[0]), float(a[1]))})
	f.operation = String(d.get("operation", OP_NEW_BODY))
	return f


## Resample a closed CCW ring to `n` points, evenly by arclength.
static func resample_ring(ring: PackedVector2Array, n: int) -> PackedVector2Array:
	var total := 0.0
	var m := ring.size()
	for i in m:
		total += ring[i].distance_to(ring[(i + 1) % m])
	var out := PackedVector2Array()
	if total < 1e-9:
		return out
	var step := total / n
	var seg := 0
	var seg_pos := 0.0
	for k in n:
		var want := step * k
		while true:
			var seg_len := ring[seg].distance_to(ring[(seg + 1) % m])
			if seg_pos + seg_len >= want - 1e-9 or seg >= m:
				var t := (want - seg_pos) / maxf(seg_len, 1e-12)
				out.append(ring[seg].lerp(ring[(seg + 1) % m],
					clampf(t, 0.0, 1.0)))
				break
			seg_pos += seg_len
			seg += 1
	return out


## World-space rings, one per section, resampled + twist-aligned. [] on
## any failure (missing region, holes present, < 2 sections).
func world_rings(doc: CadDocument) -> Array:
	if sections.size() < 2:
		return []
	var rings: Array = []
	for sec: Dictionary in sections:
		var sf := doc.sketch_feature(String(sec["sketch"]))
		if sf == null:
			return []
		var prof := ProfileFinder.profile_at(sf.sketch, sec["at"] as Vector2)
		if prof.is_empty() or not (prof.get("holes", []) as Array).is_empty():
			return []
		var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
		if ExtrudeFeature._signed_area(poly) < 0.0:
			poly.reverse()
		var flat := resample_ring(poly, RING_SAMPLES)
		if flat.is_empty():
			return []
		var xf := sf.plane_transform()
		var world := PackedVector3Array()
		for p in flat:
			world.append(xf * Vector3(p.x, p.y, 0.0))
		rings.append(world)
	# Twist alignment: rotate each ring's start (and direction) to hug the
	# previous ring.
	for k in range(1, rings.size()):
		rings[k] = _align_ring(rings[k - 1], rings[k])
	return rings


static func _align_ring(prev: PackedVector3Array,
		cur: PackedVector3Array) -> PackedVector3Array:
	var n := cur.size()
	var best := cur
	var best_cost := INF
	for reversed_ring in [false, true]:
		var base := cur.duplicate()
		if reversed_ring:
			base.reverse()
		for off in n:
			var cost := 0.0
			# Sample every 4th vertex — plenty to rank offsets.
			var i := 0
			while i < n and cost < best_cost:
				cost += prev[i].distance_squared_to(base[(i + off) % n])
				i += 4
			if cost < best_cost:
				best_cost = cost
				var rot := PackedVector3Array()
				for j in n:
					rot.append(base[(j + off) % n])
				best = rot
	return best


func build_mesh(doc: CadDocument) -> ArrayMesh:
	var rings := world_rings(doc)
	if rings.is_empty():
		return null
	var n := (rings[0] as PackedVector3Array).size()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	# Ruled walls.
	for k in rings.size() - 1:
		var r0: PackedVector3Array = rings[k]
		var r1: PackedVector3Array = rings[k + 1]
		for i in n:
			var a0 := r0[i]
			var b0 := r0[(i + 1) % n]
			var a1 := r1[i]
			var b1 := r1[(i + 1) % n]
			verts.append_array([a0, b0, b1, a0, b1, a1])
			var wn := ((b0 - a0).cross(b1 - a0)).normalized()
			for _i in 6:
				normals.append(wn)
	# Caps: triangulate each end ring in its own plane.
	for endi in [0, rings.size() - 1]:
		var ring: PackedVector3Array = rings[endi]
		# Build a local 2D frame from the ring.
		var o := ring[0]
		var ax := (ring[n / 3] - o).normalized()
		var nrm := ax.cross((ring[2 * n / 3] - o).normalized()).normalized()
		var ay := nrm.cross(ax)
		var flat := PackedVector2Array()
		for p in ring:
			flat.append(Vector2((p - o).dot(ax), (p - o).dot(ay)))
		var idx := Geometry2D.triangulate_polygon(flat)
		var outward: Vector3 = nrm if endi > 0 else nrm
		# Cap orientation is fixed by the outward-volume pass below; just
		# emit consistent triangles with the ring plane's normal.
		var t := 0
		while t + 2 < idx.size():
			verts.append_array([ring[idx[t]], ring[idx[t + 1]],
				ring[idx[t + 2]]])
			for _i in 3:
				normals.append(outward)
			t += 3
	if verts.is_empty():
		return null
	# Cap normals/orientation get fixed globally: flip everything if the
	# signed volume is negative, then re-derive cap normals from winding.
	SweepFeature._orient_outward(verts, normals)
	_fix_flat_normals(verts, normals)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var edges := PackedVector3Array()
	for ring: PackedVector3Array in rings:
		for i in n:
			edges.append_array([ring[i], ring[(i + 1) % n]])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


## Recompute each face's normal from its (now final) winding — the caps'
## provisional normals may disagree after the global orientation pass.
static func _fix_flat_normals(verts: PackedVector3Array,
		normals: PackedVector3Array) -> void:
	var t := 0
	while t + 2 < verts.size():
		var fn := ((verts[t + 1] - verts[t]).cross(
			verts[t + 2] - verts[t]))
		if fn.length() > 1e-12:
			fn = fn.normalized()
			normals[t] = fn
			normals[t + 1] = fn
			normals[t + 2] = fn
		t += 3


func solid_part(doc: CadDocument) -> Dictionary:
	var mesh := build_mesh(doc)
	if mesh == null:
		return {}
	return {"feature": self, "mesh": mesh,
		"aabb": mesh.get_aabb().grow(0.001)}


func csg_node(part: Dictionary) -> CSGShape3D:
	var node := CSGMesh3D.new()
	var src: ArrayMesh = part["mesh"]
	var solid := ArrayMesh.new()
	solid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
		src.surface_get_arrays(0))
	node.mesh = solid
	return node
