class_name ExtrudeFeature
extends Feature
## Extrude a sketch profile into a solid. The profile is remembered by an
## ANCHOR POINT inside it (sketch uv, mm) rather than by entity ids — the
## sketch can be edited and the extrude re-finds the enclosing loop on
## replay, Fusion-style. Distance in mm along the sketch plane normal.

var sketch_id := ""
var anchor := Vector2.ZERO
var distance := 10.0


static func make(p_sketch_id: String, p_anchor: Vector2,
		p_distance: float) -> ExtrudeFeature:
	var f := ExtrudeFeature.new()
	f.sketch_id = p_sketch_id
	f.anchor = p_anchor
	f.distance = p_distance
	return f


func kind() -> String:
	return "extrude"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["sketch_id"] = sketch_id
	d["anchor"] = [anchor.x, anchor.y]
	d["distance"] = distance
	return d


static func from_dict(d: Dictionary) -> ExtrudeFeature:
	var f := ExtrudeFeature.new()
	f._read_base(d)
	f.sketch_id = String(d.get("sketch_id", ""))
	var a: Array = d.get("anchor", [0.0, 0.0])
	f.anchor = Vector2(float(a[0]), float(a[1]))
	f.distance = float(d.get("distance", 10.0))
	return f


## Build the solid mesh from the CURRENT sketch state. null when the
## profile no longer exists.
func build_mesh(doc: CadDocument) -> ArrayMesh:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return null
	var prof := ProfileFinder.profile_at(sf.sketch, anchor)
	if prof.is_empty():
		return null
	var poly: PackedVector2Array = prof["polygon"]
	# Normalize to CCW: cap and wall windings below assume it, and a CW
	# profile turned every face INWARD — front faces culled, so the solid
	# rendered as a see-through hollow shell.
	var area2 := 0.0
	for i in poly.size():
		area2 += poly[i].cross(poly[(i + 1) % poly.size()])
	if area2 < 0.0:
		poly.reverse()
	var indices := Geometry2D.triangulate_polygon(poly)
	if indices.is_empty():
		return null
	var xf := sf.plane_transform()
	# `n` is the OUTWARD direction of the top cap: the plane normal for a
	# positive distance, its negation for a negative one. The top verts use
	# the true signed offset along the plane normal either way.
	var n: Vector3 = xf.basis.z if distance >= 0.0 else -xf.basis.z
	var offset: Vector3 = xf.basis.z * distance
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()

	var top := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0) + offset
	var bot := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0)

	# Caps (plane-level cap faces -n, offset cap faces +n; `n` is the outward
	# direction of the OFFSET cap, so a negative distance mirrors the
	# windings). Flat normals per face — without a normal array the lighting
	# has nothing to shade by and the whole solid renders as one flat tone.
	var flip := distance < 0.0
	for t in range(0, indices.size(), 3):
		var fwd: Array = [poly[indices[t]], poly[indices[t + 1]], poly[indices[t + 2]]]
		var rev: Array = [poly[indices[t]], poly[indices[t + 2]], poly[indices[t + 1]]]
		for p: Vector2 in (fwd if flip else rev):
			verts.append(bot.call(p))
		for _i in 3:
			normals.append(-n)
		for p: Vector2 in (rev if flip else fwd):
			verts.append(top.call(p))
		for _i in 3:
			normals.append(n)
	# Walls (winding mirrors with the distance sign too).
	for i in poly.size():
		var a2 := poly[i]
		var b2 := poly[(i + 1) % poly.size()]
		var a0: Vector3 = bot.call(a2)
		var b0: Vector3 = bot.call(b2)
		var a1: Vector3 = top.call(a2)
		var b1: Vector3 = top.call(b2)
		if flip:
			verts.append_array([a0, b1, b0, a0, a1, b1])
		else:
			verts.append_array([a0, b0, b1, a0, b1, a1])
		var wn := ((verts[-5] - verts[-6]).cross(verts[-4] - verts[-6])).normalized()
		for _i in 6:
			normals.append(wn)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Second surface: EDGE LINES (cap outlines + wall edges at sharp profile
	# corners), so the silhouette reads even under flat ambient light. Smooth
	# profile runs (a tessellated circle) get no vertical seams.
	var edges := PackedVector3Array()
	var m := poly.size()
	for i in m:
		var a2 := poly[i]
		var b2 := poly[(i + 1) % m]
		edges.append_array([bot.call(a2), bot.call(b2)])
		edges.append_array([top.call(a2), top.call(b2)])
		var prev := poly[(i - 1 + m) % m]
		var din := (a2 - prev).normalized()
		var dout := (b2 - a2).normalized()
		if din.dot(dout) < cos(deg_to_rad(15.0)):   # sharp corner at a2
			edges.append_array([bot.call(a2), top.call(a2)])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


## Signed volume of a triangle mesh (divergence theorem) — used by tests.
static func mesh_volume(mesh: ArrayMesh) -> float:
	var v := 0.0
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue   # the edge-line surface holds no volume
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for t in range(0, verts.size(), 3):
			v += verts[t].cross(verts[t + 1]).dot(verts[t + 2]) / 6.0
	return absf(v)
