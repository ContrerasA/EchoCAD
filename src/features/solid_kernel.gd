class_name SolidKernel
extends RefCounted
## M38 — the solid kernel boundary. Everything that turns a feature's
## triangle mesh into a kernel solid (`MeshSolid`, Manifold inside the
## vendored geometry addon) and back into a renderable ArrayMesh lives here,
## so BodyBuilder reads like Fusion's operation list and the rest of the app
## never touches kernel types directly.
##
## Face ids: every triangle handed to the kernel carries an int that
## survives every boolean — `(feature_ordinal << FACE_SHIFT) | local_face`.
## Local faces are grouped by smooth adjacency (neighbouring triangles whose
## normals differ by less than SMOOTH_DEG), so a tessellated cylinder wall
## is ONE face and a box has six. Boolean results therefore know which
## feature face each triangle came from — the basis of M39's persistent
## face references, M41's edge picking and the per-face edge overlay below.

const FACE_SHIFT := 12
const FACE_MASK := (1 << FACE_SHIFT) - 1
const SMOOTH_DEG := 15.0
## Kernel tolerance: vertices/faces closer than this are coincident, so a
## cut wall flush with a body wall leaves no sliver skin. Well under any
## manufacturing tolerance, well over float noise.
const TOLERANCE_MM := 1e-4

## Why the last from_mesh / build failed ("" when it did not).
static var last_error := ""


## True when the Manifold-backed MeshSolid class is loaded (the addon binary
## exists for this platform). Without it BodyBuilder falls back to the
## legacy engine CSG path.
static func available() -> bool:
	return ClassDB.class_exists("MeshSolid")


## Stable per-feature ordinal for face ids: the number in the feature id
## ("f17" -> 17). Ids are minted once and never reused, so a face id keeps
## meaning the same feature face across timeline edits, rollbacks and loads
## (a list index would renumber everything after an insertion).
static func ordinal_of(feature_id: String) -> int:
	if feature_id.length() > 1 and feature_id.begins_with("f"):
		var n := feature_id.substr(1)
		if n.is_valid_int():
			return clampi(n.to_int(), 1, (1 << 18) - 1)
	return 1


static func feature_of_face(face_id: int) -> int:
	return face_id >> FACE_SHIFT


static func kernel_name() -> String:
	if not available():
		return "legacy CSG"
	return String(ClassDB.class_call_static("MeshSolid", "kernel_version"))


## Triangles of surface 0 of `mesh` as a flat vertex list (3 per triangle),
## indices expanded.
static func triangles_of(mesh: ArrayMesh) -> PackedVector3Array:
	var tris := PackedVector3Array()
	if mesh == null:
		return tris
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var iv: Variant = arrays[Mesh.ARRAY_INDEX]
		if iv != null and not (iv as PackedInt32Array).is_empty():
			for i in (iv as PackedInt32Array):
				tris.append(verts[i])
		else:
			tris.append_array(verts)
		break
	return tris


## Local face index per triangle of a flat triangle list: flood fill across
## shared edges while the dihedral stays under SMOOTH_DEG. Vertices are
## keyed on a 1 µm grid so per-face duplicate vertices count as one.
static func local_faces(tris: PackedVector3Array) -> PackedInt32Array:
	var nt := tris.size() / 3
	var out := PackedInt32Array()
	out.resize(nt)
	out.fill(-1)
	if nt == 0:
		return out
	var normals := PackedVector3Array()
	normals.resize(nt)
	var vid := {}
	var tri_v := PackedInt32Array()
	tri_v.resize(nt * 3)
	for t in nt:
		var a := tris[t * 3]
		var b := tris[t * 3 + 1]
		var c := tris[t * 3 + 2]
		normals[t] = (b - a).cross(c - a).normalized()
		for e in 3:
			var v := tris[t * 3 + e]
			var k := Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0),
				roundi(v.z * 1000.0))
			if not vid.has(k):
				vid[k] = vid.size()
			tri_v[t * 3 + e] = vid[k]
	# edge key -> [tri, tri]
	var edge_tris := {}
	for t in nt:
		for e in 3:
			var i0 := tri_v[t * 3 + e]
			var i1 := tri_v[t * 3 + (e + 1) % 3]
			var k := Vector2i(mini(i0, i1), maxi(i0, i1))
			if edge_tris.has(k):
				(edge_tris[k] as Array).append(t)
			else:
				edge_tris[k] = [t]
	var adj: Array = []
	adj.resize(nt)
	for t in nt:
		adj[t] = []
	for k in edge_tris:
		var lst: Array = edge_tris[k]
		if lst.size() == 2:
			(adj[lst[0]] as Array).append(lst[1])
			(adj[lst[1]] as Array).append(lst[0])
	var smooth_dot := cos(deg_to_rad(SMOOTH_DEG))
	var face := 0
	for seed in nt:
		if out[seed] >= 0:
			continue
		var stack: Array = [seed]
		out[seed] = face
		while not stack.is_empty():
			var t: int = stack.pop_back()
			for u in (adj[t] as Array):
				if out[u] >= 0:
					continue
				if normals[t].dot(normals[u]) >= smooth_dot:
					out[u] = face
					stack.append(u)
		face += 1
	return out


## Make every triangle's winding agree with its neighbours (flood fill over
## shared edges, flipping a neighbour that walks the shared edge the same
## way), then orient the whole shell outward (positive signed volume). The
## generators mostly get this right, but a partial revolve's caps or a
## loft's end rings can disagree with their walls; Manifold refuses any
## inconsistency as NotManifold, so this runs on every part.
static func make_consistent(tris: PackedVector3Array) -> PackedVector3Array:
	var nt := tris.size() / 3
	if nt == 0:
		return tris
	var out := tris.duplicate()
	var vid := {}
	var tv := PackedInt32Array()
	tv.resize(nt * 3)
	for i in nt * 3:
		var v := out[i]
		var k := Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0),
			roundi(v.z * 1000.0))
		if not vid.has(k):
			vid[k] = vid.size()
		tv[i] = vid[k]
	# undirected edge -> [tri...]
	var edge_tris := {}
	for t in nt:
		for e in 3:
			var i0 := tv[t * 3 + e]
			var i1 := tv[t * 3 + (e + 1) % 3]
			if i0 == i1:
				continue
			var k := Vector2i(mini(i0, i1), maxi(i0, i1))
			if edge_tris.has(k):
				(edge_tris[k] as Array).append(t)
			else:
				edge_tris[k] = [t]
	var seen := PackedByteArray()
	seen.resize(nt)
	var flipped := 0
	for seed in nt:
		if seen[seed] != 0:
			continue
		seen[seed] = 1
		var stack: Array = [seed]
		while not stack.is_empty():
			var t: int = stack.pop_back()
			for e in 3:
				var a := tv[t * 3 + e]
				var b := tv[t * 3 + (e + 1) % 3]
				if a == b:
					continue
				var k := Vector2i(mini(a, b), maxi(a, b))
				var lst: Array = edge_tris.get(k, [])
				if lst.size() != 2:
					continue
				var u: int = lst[0] if lst[1] == t else lst[1]
				if seen[u] != 0:
					continue
				# Does u walk a->b in the same direction? Then flip it.
				var same := false
				for f in 3:
					if tv[u * 3 + f] == a and tv[u * 3 + (f + 1) % 3] == b:
						same = true
						break
				if same:
					var tmp := out[u * 3 + 1]
					out[u * 3 + 1] = out[u * 3 + 2]
					out[u * 3 + 2] = tmp
					var tmpi := tv[u * 3 + 1]
					tv[u * 3 + 1] = tv[u * 3 + 2]
					tv[u * 3 + 2] = tmpi
					flipped += 1
				seen[u] = 1
				stack.append(u)
	var vol := 0.0
	for t in nt:
		vol += out[t * 3].cross(out[t * 3 + 1]).dot(out[t * 3 + 2])
	if vol < 0.0:
		for t in nt:
			var tmp := out[t * 3 + 1]
			out[t * 3 + 1] = out[t * 3 + 2]
			out[t * 3 + 2] = tmp
	return out


## Kernel solid of a feature mesh, triangles tagged with `ordinal`'s face
## ids. null (with last_error set) when the mesh is not a closed manifold.
static func from_mesh(mesh: ArrayMesh, ordinal: int) -> RefCounted:
	last_error = ""
	if not available():
		last_error = "kernel unavailable"
		return null
	var tris := make_consistent(triangles_of(mesh))
	if tris.size() < 12:
		last_error = "empty mesh"
		return null
	var faces := local_faces(tris)
	# Weld on the same 1 µm grid the topology passes use, so the kernel
	# receives SHARED vertices (its own merge tolerance is far tighter than
	# a generator's float noise — an unwelded soup with 1e-5 mm gaps reads
	# as NotManifold). Degenerate triangles (two corners welded) drop out.
	var vid := {}
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var fids := PackedInt32Array()
	for t in tris.size() / 3:
		var ids := [0, 0, 0]
		for e in 3:
			var v := tris[t * 3 + e]
			var k := Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0),
				roundi(v.z * 1000.0))
			if not vid.has(k):
				vid[k] = verts.size()
				verts.append(v)
			ids[e] = vid[k]
		if ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]:
			continue
		idx.append(ids[0])
		idx.append(ids[1])
		idx.append(ids[2])
		fids.append((ordinal << FACE_SHIFT) | (faces[t] & FACE_MASK))
	var solid: RefCounted = ClassDB.instantiate("MeshSolid")
	if not solid.call("from_mesh", verts, idx, fids):
		last_error = "mesh is not a closed solid (%s)" % solid.call("status")
		return null
	return solid.call("with_tolerance", TOLERANCE_MM)


## Renderable ArrayMesh of a kernel solid: surface 0 flat-shaded triangles,
## surface 1 edge lines wherever two different faces meet (feature seams
## and sharp corners), plus the solid's per-triangle face ids so pickers
## can map a hit triangle back to its face.
## -> {mesh: ArrayMesh, face_ids: PackedInt32Array}
static func to_mesh(solid: RefCounted) -> Dictionary:
	var out := {"mesh": null, "face_ids": PackedInt32Array()}
	if solid == null or bool(solid.call("is_empty")):
		return out
	var m: Dictionary = solid.call("to_mesh")
	var verts: PackedVector3Array = m["vertices"]
	var idx: PackedInt32Array = m["indices"]
	var fids: PackedInt32Array = m["face_ids"]
	var nt := idx.size() / 3
	var tris := PackedVector3Array()
	var normals := PackedVector3Array()
	tris.resize(nt * 3)
	normals.resize(nt * 3)
	var face_n := PackedVector3Array()
	face_n.resize(nt)
	for t in nt:
		var a := verts[idx[t * 3]]
		var b := verts[idx[t * 3 + 1]]
		var c := verts[idx[t * 3 + 2]]
		var n := (b - a).cross(c - a).normalized()
		face_n[t] = n
		tris[t * 3] = a
		tris[t * 3 + 1] = b
		tris[t * 3 + 2] = c
		normals[t * 3] = n
		normals[t * 3 + 1] = n
		normals[t * 3 + 2] = n
	# Edge overlay from the welded index topology: an edge draws when its two
	# triangles belong to different faces, or meet sharply anyway (a
	# boolean can leave two same-id triangles at a crease), or it is open.
	var edge_tris := {}
	for t in nt:
		for e in 3:
			var i0 := idx[t * 3 + e]
			var i1 := idx[t * 3 + (e + 1) % 3]
			var k := Vector2i(mini(i0, i1), maxi(i0, i1))
			if edge_tris.has(k):
				(edge_tris[k] as Array).append(t)
			else:
				edge_tris[k] = [t]
	var flat_dot := cos(deg_to_rad(SMOOTH_DEG))
	var edges := PackedVector3Array()
	for k in edge_tris:
		var lst: Array = edge_tris[k]
		var draw := lst.size() != 2
		if not draw:
			var t0: int = lst[0]
			var t1: int = lst[1]
			draw = fids[t0] != fids[t1] or face_n[t0].dot(face_n[t1]) < flat_dot
		if draw:
			var kk := k as Vector2i
			edges.append(verts[kk.x])
			edges.append(verts[kk.y])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if not edges.is_empty():
		var earr := []
		earr.resize(Mesh.ARRAY_MAX)
		earr[Mesh.ARRAY_VERTEX] = edges
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	out["mesh"] = mesh
	out["face_ids"] = fids
	return out


## Boolean of two kernel solids. op: SolidFeature.OP_JOIN / OP_CUT /
## OP_INTERSECT.
static func boolean(a: RefCounted, b: RefCounted, op: String) -> RefCounted:
	var code := 0
	match op:
		SolidFeature.OP_CUT:
			code = 2
		SolidFeature.OP_INTERSECT:
			code = 1
		_:
			code = 0
	return a.call("boolean", b, code)


static func transformed(solid: RefCounted, xf: Transform3D) -> RefCounted:
	return solid.call("transformed", xf)


static func volume(solid: RefCounted) -> float:
	return float(solid.call("volume")) if solid != null else 0.0


static func aabb(solid: RefCounted) -> AABB:
	return solid.call("aabb") if solid != null else AABB()


static func is_valid(solid: RefCounted) -> bool:
	return solid != null and bool(solid.call("is_valid"))
