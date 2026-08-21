class_name ShellFeature
extends Feature
## M42 — hollow a body to a wall thickness, opening the picked faces.
## Inside: the walls grow inward from the current faces (outer size kept);
## outside: the body becomes the cavity and the walls grow outward.
##
## Geometry: an OFFSET copy of the body is built by moving every vertex of
## the kernel mesh by a per-vertex displacement that keeps each adjacent
## face plane at the wall distance (3-plane corners exact, more planes by
## least squares, curved faces by their per-vertex normals); faces being
## REMOVED are pushed the other way past the original so the subtraction
## opens them. shell = body − offset (inside) or offset − body (outside).
## Thickness larger than the local feature size makes the offset fold on
## itself; the kernel then rejects it and the chip says so.

const DIR_INSIDE := "inside"
const DIR_OUTSIDE := "outside"

var body := ""
var thickness := 2.0
var direction := DIR_INSIDE
var remove: Array = []          # [TopoRef]


func kind() -> String:
	return "shell"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["thickness"] = thickness
	d["direction"] = direction
	var rs: Array = []
	for r: TopoRef in remove:
		rs.append(r.to_dict())
	d["remove"] = rs
	return d


static func from_dict(d: Dictionary) -> ShellFeature:
	var f := ShellFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.thickness = float(d.get("thickness", 2.0))
	f.direction = String(d.get("direction", DIR_INSIDE))
	f.remove = []
	for r in (d.get("remove", []) as Array):
		f.remove.append(TopoRef.from_dict(r as Dictionary))
	return f


## Offset copy of the entry's solid: every face plane moved by `dist`
## along its OUTWARD normal (negative = inward); faces in `open_ids` moved
## by `open_dist` instead. -> MeshSolid or null (kernel rejected the fold).
static func offset_solid(entry: Dictionary, dist: float, open_ids: Dictionary,
		open_dist: float, ordinal: int) -> RefCounted:
	var solid: Variant = entry.get("solid")
	if solid == null:
		return null
	var m: Dictionary = solid.call("to_mesh")
	var verts: PackedVector3Array = m["vertices"]
	var idx: PackedInt32Array = m["indices"]
	var fids: PackedInt32Array = m["face_ids"]
	var nt := idx.size() / 3
	# Per vertex: the set of (unit normal, wanted offset) constraints, one
	# per distinct face plane touching the vertex (curved faces contribute
	# their local triangle normal averaged per face id).
	var acc := {}   # vertex -> {face id -> [normal sum, count]}
	for t in nt:
		var a := verts[idx[t * 3]]
		var b := verts[idx[t * 3 + 1]]
		var c := verts[idx[t * 3 + 2]]
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-18:
			continue
		n = n.normalized()
		var fid := fids[t]
		for e in 3:
			var v := idx[t * 3 + e]
			if not acc.has(v):
				acc[v] = {}
			var per: Dictionary = acc[v]
			if not per.has(fid):
				per[fid] = [Vector3.ZERO, 0]
			var rec: Array = per[fid]
			rec[0] = (rec[0] as Vector3) + n
			rec[1] = int(rec[1]) + 1
	var out_verts := PackedVector3Array()
	out_verts.resize(verts.size())
	for v in verts.size():
		var per: Dictionary = acc.get(v, {})
		var normals: Array = []
		var targets: Array = []
		for fid in per:
			var rec: Array = per[fid]
			var n := (rec[0] as Vector3).normalized()
			# Merge near-parallel planes (a tessellated cylinder's facets at
			# one vertex are one constraint).
			var dup := false
			for k in normals.size():
				if (normals[k] as Vector3).dot(n) > 0.999:
					dup = true
					break
			if dup:
				continue
			normals.append(n)
			targets.append(open_dist if open_ids.has(fid) else dist)
		var d := Vector3.ZERO
		if normals.size() == 1:
			d = (normals[0] as Vector3) * float(targets[0])
		elif normals.size() == 2:
			# Exact in the plane of the two normals; no motion along the edge.
			var n0: Vector3 = normals[0]
			var n1: Vector3 = normals[1]
			var e := n0.cross(n1)
			if e.length_squared() < 1e-12:
				d = n0 * float(targets[0])
			else:
				var mtx := Basis(n0, n1, e.normalized()).transposed()
				d = mtx.inverse() * Vector3(float(targets[0]), float(targets[1]), 0.0)
		else:
			# Least squares over all constraints: minimise Σ (n_i·d - t_i)².
			var ata := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			var atb := Vector3.ZERO
			for k in normals.size():
				var n: Vector3 = normals[k]
				var tk := float(targets[k])
				ata.x += n * n.x
				ata.y += n * n.y
				ata.z += n * n.z
				atb += n * tk
			if absf(ata.determinant()) > 1e-9:
				d = ata.inverse() * atb
			else:
				d = (normals[0] as Vector3) * float(targets[0])
		# Miter limit: a needle corner would fly off.
		if d.length() > absf(dist) * 4.0 + absf(open_dist):
			d = d.normalized() * (absf(dist) * 4.0 + absf(open_dist))
		out_verts[v] = verts[v] + d
	# A fold-over (thickness past the local feature size) turns the offset
	# inside out: its signed volume flips sign relative to the source.
	var signed := 0.0
	for t in nt:
		signed += out_verts[idx[t * 3]].cross(out_verts[idx[t * 3 + 1]]).dot(out_verts[idx[t * 3 + 2]])
	if signed <= 0.0:
		return null
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_verts
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return SolidKernel.from_mesh(mesh, ordinal)


## Apply to a body entry: returns the shelled solid (the old one on
## failure, with rebuild_error set).
func apply(entry: Dictionary) -> RefCounted:
	var solid: RefCounted = entry["solid"]
	if thickness <= 0.0:
		rebuild_error = "thickness must be positive"
		return solid
	var open_ids := {}
	var lost := 0
	for r: TopoRef in remove:
		var fp := r.resolve_on(entry)
		if fp.is_empty():
			lost += 1
		else:
			open_ids[int(fp["face"])] = true
	var ordinal := SolidKernel.ordinal_of(id)
	var result: RefCounted = null
	var box := SolidKernel.aabb(solid).size
	if direction == DIR_INSIDE and thickness * 2.0 >= minf(box.x, minf(box.y, box.z)) - 1e-6:
		rebuild_error = "thickness too large for this body (at least half its smallest extent)"
		return solid
	if direction == DIR_INSIDE:
		var inner := offset_solid(entry, -thickness, open_ids, thickness + 1.0, ordinal)
		if inner == null:
			rebuild_error = "thickness too large for this body (the inner wall folds over itself)"
			return solid
		result = SolidKernel.boolean(solid, inner, SolidFeature.OP_CUT)
	else:
		var outer := offset_solid(entry, thickness, {}, 0.0, ordinal)
		if outer == null:
			rebuild_error = "could not offset the body outward"
			return solid
		# Outside: the body is the cavity; removed faces open the cavity to
		# the outside — cut a prism of the removed faces through the wall.
		result = SolidKernel.boolean(outer, solid, SolidFeature.OP_CUT)
		if not open_ids.is_empty():
			var opener := offset_solid(entry, -0.01, open_ids, thickness + 1.0, ordinal)
			if opener != null:
				var r2 := SolidKernel.boolean(result, opener, SolidFeature.OP_CUT)
				if SolidKernel.is_valid(r2):
					result = r2
	if not SolidKernel.is_valid(result):
		rebuild_error = "shell produced nothing — thickness too large?"
		return solid
	if lost > 0:
		rebuild_error = "%d face(s) to remove no longer exist — re-pick" % lost
		rebuild_level = "warning"
	return result
