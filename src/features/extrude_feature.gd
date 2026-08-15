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
	var indices := Geometry2D.triangulate_polygon(poly)
	if indices.is_empty():
		return null
	var xf := sf.plane_transform()
	var n: Vector3 = xf.basis.z
	var verts := PackedVector3Array()

	var top := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0) + n * distance
	var bot := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0)

	# Caps (bottom wound to face -n, top to face +n).
	for t in range(0, indices.size(), 3):
		verts.append(bot.call(poly[indices[t]]))
		verts.append(bot.call(poly[indices[t + 2]]))
		verts.append(bot.call(poly[indices[t + 1]]))
		verts.append(top.call(poly[indices[t]]))
		verts.append(top.call(poly[indices[t + 1]]))
		verts.append(top.call(poly[indices[t + 2]]))
	# Walls.
	for i in poly.size():
		var a2 := poly[i]
		var b2 := poly[(i + 1) % poly.size()]
		var a0: Vector3 = bot.call(a2)
		var b0: Vector3 = bot.call(b2)
		var a1: Vector3 = top.call(a2)
		var b1: Vector3 = top.call(b2)
		verts.append_array([a0, b0, b1, a0, b1, a1])

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Signed volume of a triangle mesh (divergence theorem) — used by tests.
static func mesh_volume(mesh: ArrayMesh) -> float:
	var v := 0.0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for t in range(0, verts.size(), 3):
			v += verts[t].cross(verts[t + 1]).dot(verts[t + 2]) / 6.0
	return absf(v)
