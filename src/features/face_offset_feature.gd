class_name FaceOffsetFeature
extends Feature
## M42 — press / pull: move a PLANAR face of a body along its normal. A
## positive distance adds material (the face's loops extruded outward are
## joined), a negative one removes it (extruded inward and cut). The face
## is a TopoRef, so the feature follows upstream edits.

var body := ""
var ref: TopoRef = null
var distance := 5.0


func kind() -> String:
	return "face_offset"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["distance"] = distance
	if ref != null:
		d["ref"] = ref.to_dict()
	return d


static func from_dict(d: Dictionary) -> FaceOffsetFeature:
	var f := FaceOffsetFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.distance = float(d.get("distance", 5.0))
	if d.has("ref"):
		f.ref = TopoRef.from_dict(d["ref"])
	return f


## Prism of a face's boundary loops from plane offset `lo` to `hi` along
## the face normal. -> MeshSolid or null.
static func face_prism(entry: Dictionary, face_id: int, normal: Vector3, point: Vector3,
		lo: float, hi: float, ordinal: int) -> RefCounted:
	var loops := TopoRef.face_loops(entry, face_id)
	if loops.is_empty():
		return null
	var xf := PlaneFeature.face_transform(point, normal)
	var inv := xf.affine_inverse()
	var rings: Array = []
	for lp: PackedVector3Array in loops:
		var r := PackedVector2Array()
		for p in lp:
			var l := inv * p
			r.append(Vector2(l.x, l.y))
		rings.append(r)
	# Outer = largest |area|; the rest are holes.
	var best := 0
	var best_a := 0.0
	for i in rings.size():
		var a := absf(SolidFeature.ring_area(rings[i]))
		if a > best_a:
			best_a = a
			best = i
	var outer: PackedVector2Array = rings[best]
	if SolidFeature.ring_area(outer) < 0.0:
		outer.reverse()
	var holes: Array = []
	for i in rings.size():
		if i != best and (rings[i] as PackedVector2Array).size() >= 3:
			holes.append(rings[i])
	var tri := ProfileFinder.triangulate_with_holes(outer, holes)
	var pts: PackedVector2Array = tri["points"]
	var idx: PackedInt32Array = tri["indices"]
	if idx.is_empty():
		return null
	var tris := PackedVector3Array()
	var at := func(p: Vector2, z: float) -> Vector3:
		return xf * Vector3(p.x, p.y, z)
	for t in range(0, idx.size(), 3):
		tris.append_array([at.call(pts[idx[t]], lo), at.call(pts[idx[t + 2]], lo), at.call(pts[idx[t + 1]], lo)])
		tris.append_array([at.call(pts[idx[t]], hi), at.call(pts[idx[t + 1]], hi), at.call(pts[idx[t + 2]], hi)])
	var walls: Array = [outer]
	for h in holes:
		var hc := (h as PackedVector2Array).duplicate()
		if SolidFeature.ring_area(hc) > 0.0:
			hc.reverse()
		walls.append(hc)
	for ring: PackedVector2Array in walls:
		for i in ring.size():
			var a2 := ring[i]
			var b2 := ring[(i + 1) % ring.size()]
			tris.append_array([at.call(a2, lo), at.call(b2, lo), at.call(b2, hi),
				at.call(a2, lo), at.call(b2, hi), at.call(a2, hi)])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return SolidKernel.from_mesh(mesh, ordinal)


func apply(entry: Dictionary) -> RefCounted:
	var solid: RefCounted = entry["solid"]
	if ref == null:
		rebuild_error = "pick a face"
		return solid
	var fp := ref.resolve_on(entry)
	if fp.is_empty():
		rebuild_error = "the face no longer exists — re-pick"
		rebuild_level = "warning"
		return solid
	if absf(distance) < 1e-6:
		return solid
	var ordinal := SolidKernel.ordinal_of(id)
	var tool: RefCounted
	var res: RefCounted
	if distance > 0.0:
		tool = face_prism(entry, int(fp["face"]), fp["normal"], fp["point"], -0.01, distance, ordinal)
		res = SolidKernel.boolean(solid, tool, SolidFeature.OP_JOIN) if tool != null else null
	else:
		tool = face_prism(entry, int(fp["face"]), fp["normal"], fp["point"], distance, 0.01, ordinal)
		res = SolidKernel.boolean(solid, tool, SolidFeature.OP_CUT) if tool != null else null
	if tool == null:
		rebuild_error = "could not build the face's prism"
		return solid
	if not SolidKernel.is_valid(res):
		if distance < 0.0:
			# Pushed through the whole body: it vanishes.
			return res
		rebuild_error = "press/pull produced nothing"
		return solid
	return res
