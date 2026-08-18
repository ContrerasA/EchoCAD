class_name StlExporter
extends RefCounted
## STL writer (M24): bodies -> binary STL (the 3D-printing default) or ASCII
## STL (diffable). Coordinates are the model's canonical MILLIMETRES — the
## unit every slicer assumes. Triangles come straight from the body meshes
## (exact meshes for plain extrudes/revolves, CSG bakes for booleans), which
## are already wound outward; facet normals are recomputed flat per face so
## the file never inherits smoothed vertex normals.


## Collect the triangles (world mm, flat triples) of one body mesh.
static func mesh_triangles(mesh: ArrayMesh) -> PackedVector3Array:
	var tris := PackedVector3Array()
	if mesh == null:
		return tris
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue   # the edge-line overlay surface is display-only
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var iv: Variant = arrays[Mesh.ARRAY_INDEX]
		if iv != null and not (iv as PackedInt32Array).is_empty():
			for i in (iv as PackedInt32Array):
				tris.append(verts[i])
		else:
			tris.append_array(verts)
	return tris


## Write `bodies` — [{name: String, mesh: ArrayMesh}] — to `path`.
## -> {"ok": bool, "triangles": int, "error": String}
static func write(bodies: Array, path: String, ascii := false) -> Dictionary:
	var tris := PackedVector3Array()
	for b: Dictionary in bodies:
		tris.append_array(mesh_triangles(b.get("mesh") as ArrayMesh))
	if tris.is_empty():
		return {"ok": false, "triangles": 0,
			"error": "nothing to export — no solid bodies"}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "triangles": 0, "error": "cannot write %s: %s"
			% [path, error_string(FileAccess.get_open_error())]}
	var count := tris.size() / 3
	if ascii:
		_write_ascii(f, tris)
	else:
		_write_binary(f, tris, count)
	f.close()
	return {"ok": true, "triangles": count, "error": ""}


static func _normal_of(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	return n.normalized() if n.length_squared() > 1e-12 else Vector3.ZERO


static func _write_binary(f: FileAccess, tris: PackedVector3Array,
		count: int) -> void:
	# 80-byte header. Must NOT begin with "solid" or sloppy readers treat the
	# file as ASCII.
	var header := "EchoCAD binary STL (units: mm)".to_ascii_buffer()
	header.resize(80)
	f.store_buffer(header)
	f.store_32(count)
	for t in range(0, tris.size(), 3):
		var n := _normal_of(tris[t], tris[t + 1], tris[t + 2])
		for v in [n, tris[t], tris[t + 1], tris[t + 2]]:
			f.store_float((v as Vector3).x)
			f.store_float((v as Vector3).y)
			f.store_float((v as Vector3).z)
		f.store_16(0)   # attribute byte count


static func _write_ascii(f: FileAccess, tris: PackedVector3Array) -> void:
	f.store_string("solid echocad\n")
	for t in range(0, tris.size(), 3):
		var n := _normal_of(tris[t], tris[t + 1], tris[t + 2])
		f.store_string("  facet normal %.6f %.6f %.6f\n" % [n.x, n.y, n.z])
		f.store_string("    outer loop\n")
		for i in 3:
			var v := tris[t + i]
			f.store_string("      vertex %.6f %.6f %.6f\n" % [v.x, v.y, v.z])
		f.store_string("    endloop\n")
		f.store_string("  endfacet\n")
	f.store_string("endsolid echocad\n")
