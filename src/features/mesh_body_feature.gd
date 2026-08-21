class_name MeshBodyFeature
extends SolidFeature
## M44 — a body that came from a mesh file (STL / OBJ / 3MF) instead of a
## sketch. The triangles live in the document (welded vertices + indices,
## base64 in .ecad) so the file stays portable. A NEW BODY like any other:
## it takes cuts, joins, targets, fillets, section, export. When the mesh
## is not a closed solid the kernel refuses it; the body is still shown
## (reference only, amber chip) but excluded from booleans.

var vertices := PackedVector3Array()
var indices := PackedInt32Array()
var source := ""            # original file name, for the browser tooltip
var transform := Transform3D.IDENTITY


func _init() -> void:
	operation = OP_NEW_BODY


func kind() -> String:
	return "mesh_body"


static func make(p_name: String, tris: PackedVector3Array, p_source := "") -> MeshBodyFeature:
	var f := MeshBodyFeature.new()
	f.name = p_name
	f.source = p_source
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = tris
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var w := MeshIo.weld(am)
	f.vertices = w["vertices"]
	f.indices = w["indices"]
	return f


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["source"] = source
	d["operation"] = OP_NEW_BODY
	d["vertices"] = Marshalls.raw_to_base64(vertices.to_byte_array())
	d["indices"] = Marshalls.raw_to_base64(indices.to_byte_array())
	var b := transform.basis
	var o := transform.origin
	d["xf"] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, o.x, o.y, o.z]
	return d


static func from_dict(d: Dictionary) -> MeshBodyFeature:
	var f := MeshBodyFeature.new()
	f._read_base(d)
	f.source = String(d.get("source", ""))
	var raw := Marshalls.base64_to_raw(String(d.get("vertices", "")))
	f.vertices = PackedVector3Array(_floats_to_vec3(raw.to_float32_array()))
	f.indices = Marshalls.base64_to_raw(String(d.get("indices", ""))).to_int32_array()
	var a: Array = d.get("xf", [])
	if a.size() == 12:
		f.transform = Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]),
			Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))
	return f


static func _floats_to_vec3(fl: PackedFloat32Array) -> Array:
	var out: Array = []
	for i in fl.size() / 3:
		out.append(Vector3(fl[i * 3], fl[i * 3 + 1], fl[i * 3 + 2]))
	return out


## Flat-shaded render mesh (with the kernel unavailable, also the display).
func build_mesh(_doc: CadDocument) -> ArrayMesh:
	if indices.is_empty():
		return null
	var tris := PackedVector3Array()
	var normals := PackedVector3Array()
	for t in indices.size() / 3:
		var a := transform * vertices[indices[t * 3]]
		var b := transform * vertices[indices[t * 3 + 1]]
		var c := transform * vertices[indices[t * 3 + 2]]
		var n := (b - a).cross(c - a).normalized()
		tris.append_array([a, b, c])
		normals.append_array([n, n, n])
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = tris
	arr[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func solid_part(doc: CadDocument) -> Dictionary:
	var mesh := build_mesh(doc)
	if mesh == null:
		return {}
	return {"feature": self, "mesh": mesh, "aabb": mesh.get_aabb().grow(0.001)}


func csg_node(part: Dictionary) -> CSGShape3D:
	var node := CSGMesh3D.new()
	node.mesh = part["mesh"]
	return node
