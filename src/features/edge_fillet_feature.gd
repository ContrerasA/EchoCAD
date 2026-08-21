class_name EdgeFilletFeature
extends Feature
## M41 — fillet / chamfer on ANY edge of ANY body, after any boolean.
##
## Edges are kernel EDGE CHAINS (SolidKernel.edge_chains): the run of mesh
## edges between two faces (a straight box edge, a hole rim, a boss
## root). Each picked edge is remembered by its face pair + chain ordinal
## and a midpoint hint, and re-found on rebuild (healed by the hint when
## the ordinal moved).
##
## Geometry: per chain, a SWEEP of the corner section along the chain —
## chamfer = triangle (edge, leg on face A, leg on face B); fillet = the
## region between the two tangent points and the rolling-ball arc. Convex
## edges are CUT by their sweep, concave edges JOIN theirs. Sections follow
## the faces' normals vertex by vertex, so rims on cylinders round
## correctly. Where three convex filleted edges meet at a corner of planar
## faces, a ball-corner tool (corner box minus sphere minus the three edge
## cylinders) finishes the vertex.

const KIND_FILLET := "fillet"
const KIND_CHAMFER := "chamfer"

const ARC_STEPS := 10          # fillet arc samples per section
const OVERSHOOT := 0.3         # mm the section pokes past the edge

var body := ""
var treat := KIND_FILLET
var size_mm := 2.0
## [{fa: int, fb: int, k: int, hint: Vector3}]
var edges: Array = []
## Why the last build skipped something ("" = all good).
var last_note := ""


func kind() -> String:
	return "edge_fillet"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["treat"] = treat
	d["size_mm"] = size_mm
	var es: Array = []
	for e: Dictionary in edges:
		var h: Vector3 = e["hint"]
		es.append({"fa": int(e["fa"]), "fb": int(e["fb"]), "k": int(e["k"]),
			"hint": [h.x, h.y, h.z]})
	d["edges"] = es
	return d


static func from_dict(d: Dictionary) -> EdgeFilletFeature:
	var f := EdgeFilletFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.treat = String(d.get("treat", KIND_FILLET))
	f.size_mm = float(d.get("size_mm", 2.0))
	f.edges = []
	for e in (d.get("edges", []) as Array):
		var ed := e as Dictionary
		var h: Array = ed.get("hint", [0, 0, 0])
		f.edges.append({"fa": int(ed.get("fa", 0)), "fb": int(ed.get("fb", 0)),
			"k": int(ed.get("k", 0)),
			"hint": Vector3(float(h[0]), float(h[1]), float(h[2]))})
	return f


static func chain_midpoint(chain: Dictionary) -> Vector3:
	var pts: PackedVector3Array = chain["points"]
	if pts.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / pts.size()


## Match the stored edges against the body's current chains. Returns the
## matched chains; unmatched edges are reported in last_note and healed
## when a chain's midpoint is close to the hint (the chains renumber when
## an upstream feature changes).
func resolve_chains(chains: Array) -> Array:
	var out: Array = []
	var missing := 0
	for e: Dictionary in edges:
		var hit := {}
		for ch: Dictionary in chains:
			if int(ch["fa"]) == int(e["fa"]) and int(ch["fb"]) == int(e["fb"]) \
					and String(ch["key"]).ends_with("|%d" % int(e["k"])):
				hit = ch
				break
		if hit.is_empty() or chain_midpoint(hit).distance_to(e["hint"]) > 0.5 + size_mm:
			# Heal by hint: nearest chain midpoint.
			var best := {}
			var best_d := 0.5 + size_mm
			for ch: Dictionary in chains:
				var dd := chain_midpoint(ch).distance_to(e["hint"])
				if dd < best_d:
					best_d = dd
					best = ch
			if not best.is_empty():
				hit = best
				e["fa"] = int(best["fa"])
				e["fb"] = int(best["fb"])
				var parts: PackedStringArray = String(best["key"]).split("|")
				e["k"] = int(parts[parts.size() - 1])
		if hit.is_empty():
			missing += 1
			continue
		e["hint"] = chain_midpoint(hit)
		if not out.has(hit):
			out.append(hit)
	last_note = "" if missing == 0 else "%d edge(s) no longer exist — re-pick" % missing
	return out


## --- tool geometry ------------------------------------------------------------

## The section polygon at chain vertex i (world points, consistent order
## along every vertex of the chain). `convex` selects cut-vs-join shapes.
func _section(p: Vector3, na: Vector3, nb: Vector3, t: Vector3, convex: bool) -> PackedVector3Array:
	var out := PackedVector3Array()
	# In-face directions away from the edge.
	var da := t.cross(na).normalized()
	var db := t.cross(nb).normalized()
	if convex:
		if da.dot(nb) > 0.0:
			da = -da
		if db.dot(na) > 0.0:
			db = -db
	else:
		if da.dot(nb) < 0.0:
			da = -da
		if db.dot(na) < 0.0:
			db = -db
	var bis := (na + nb)
	if bis.length_squared() < 1e-12:
		bis = na
	bis = bis.normalized()
	# Apex poked outside (cut) or inside (join) the material so the tool's
	# faces never sit exactly on the body faces.
	var apex := p + bis * (OVERSHOOT if convex else -OVERSHOOT)
	var cos_half := sqrt(maxf((1.0 + na.dot(nb)) * 0.5, 1e-6))   # cos(φ/2)
	var sin_half := sqrt(maxf(1.0 - cos_half * cos_half, 0.0))
	if treat == KIND_CHAMFER:
		out.append(apex)
		out.append(p + da * size_mm)
		out.append(p + db * size_mm)
		return out
	# Fillet: tangent length r·tan(φ/2), centre along the in-face bisector.
	var tan_half := sin_half / maxf(cos_half, 1e-6)
	var tl := size_mm * tan_half
	var pa := p + da * tl
	var pb := p + db * tl
	var inward := (da + db).normalized()
	var c := p + inward * (size_mm / maxf(cos_half, 1e-6))
	out.append(apex)
	out.append(pa)
	var u0 := pa - c
	var u1 := pb - c
	var axis := u0.cross(u1)
	if axis.length_squared() < 1e-12:
		axis = t
	axis = axis.normalized()
	var ang := u0.angle_to(u1)
	for i in range(1, ARC_STEPS):
		var f := float(i) / ARC_STEPS
		out.append(c + u0.rotated(axis, ang * f))
	out.append(pb)
	return out


## Sweep the section along a chain into a closed triangle soup. Open
## chains are capped and, at convex-corner ends, overshoot by `ext` so
## neighbouring tools overlap instead of leaving a sliver.
func chain_tool(chain: Dictionary, ext_start: float, ext_end: float) -> ArrayMesh:
	var pts: PackedVector3Array = chain["points"]
	var na: PackedVector3Array = chain["na"]
	var nb: PackedVector3Array = chain["nb"]
	var closed: bool = chain["closed"]
	var convex: bool = chain["convex"]
	var n := pts.size()
	if n < 2:
		return null
	var sections: Array = []
	for i in n:
		var prev := pts[(i - 1 + n) % n] if (closed or i > 0) else pts[i]
		var nxt := pts[(i + 1) % n] if (closed or i < n - 1) else pts[i]
		var t := (nxt - prev)
		if t.length_squared() < 1e-12:
			t = pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		t = t.normalized()
		var p := pts[i]
		if not closed and i == 0 and ext_start > 0.0:
			p = p - t * ext_start
		elif not closed and i == n - 1 and ext_end > 0.0:
			p = p + t * ext_end
		sections.append(_section(p, na[i], nb[i], t, convex))
	var tris := PackedVector3Array()
	var m: int = (sections[0] as PackedVector3Array).size()
	var count := n if closed else n - 1
	for i in count:
		var s0: PackedVector3Array = sections[i]
		var s1: PackedVector3Array = sections[(i + 1) % n]
		for e in m:
			var a := s0[e]
			var b := s0[(e + 1) % m]
			var c := s1[(e + 1) % m]
			var d := s1[e]
			tris.append_array([a, b, c, a, c, d])
	if not closed:
		var s0: PackedVector3Array = sections[0]
		var sl: PackedVector3Array = sections[n - 1]
		for e in range(1, m - 1):
			tris.append_array([s0[0], s0[e + 1], s0[e]])
			tris.append_array([sl[0], sl[e], sl[e + 1]])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Apply this feature to a body entry's kernel solid. Returns the new
## solid (or the old one when nothing applied) and sets rebuild_error on
## failure.
func apply(entry: Dictionary) -> RefCounted:
	var solid: RefCounted = entry["solid"]
	var chains := SolidKernel.edge_chains(entry)
	var picked := resolve_chains(chains)
	if picked.is_empty():
		rebuild_error = "none of its edges exist any more — re-pick"
		return solid
	var ordinal := SolidKernel.ordinal_of(id)
	# Vertex convexity census: a chain end overshoots only into a corner
	# where every chain meeting there is convex (never into a wall).
	var corner_convex := {}
	for ch: Dictionary in chains:
		var cp: PackedVector3Array = ch["points"]
		if cp.is_empty() or bool(ch["closed"]):
			continue
		for endp in [cp[0], cp[cp.size() - 1]]:
			var key := Vector3i(roundi(endp.x * 1000.0), roundi(endp.y * 1000.0),
				roundi(endp.z * 1000.0))
			corner_convex[key] = bool(corner_convex.get(key, true)) and bool(ch["convex"])
	var cut_tool: RefCounted = null
	var join_tool: RefCounted = null
	var failed := 0
	for ch: Dictionary in picked:
		var cp: PackedVector3Array = ch["points"]
		var ext0 := 0.0
		var ext1 := 0.0
		if not bool(ch["closed"]):
			var k0 := Vector3i(roundi(cp[0].x * 1000.0), roundi(cp[0].y * 1000.0), roundi(cp[0].z * 1000.0))
			var k1 := Vector3i(roundi(cp[cp.size() - 1].x * 1000.0),
				roundi(cp[cp.size() - 1].y * 1000.0), roundi(cp[cp.size() - 1].z * 1000.0))
			ext0 = size_mm if bool(corner_convex.get(k0, false)) and bool(ch["convex"]) else 0.0
			ext1 = size_mm if bool(corner_convex.get(k1, false)) and bool(ch["convex"]) else 0.0
		var mesh := chain_tool(ch, ext0, ext1)
		var tool := SolidKernel.from_mesh(mesh, ordinal) if mesh != null else null
		if tool == null:
			failed += 1
			continue
		if bool(ch["convex"]):
			cut_tool = tool if cut_tool == null else SolidKernel.boolean(cut_tool, tool, SolidFeature.OP_JOIN)
		else:
			join_tool = tool if join_tool == null else SolidKernel.boolean(join_tool, tool, SolidFeature.OP_JOIN)
	if treat == KIND_FILLET:
		var ball := _ball_corners(picked, chains, ordinal)
		if ball != null:
			cut_tool = ball if cut_tool == null else SolidKernel.boolean(cut_tool, ball, SolidFeature.OP_JOIN)
	var result := solid
	if cut_tool != null:
		var r := SolidKernel.boolean(result, cut_tool, SolidFeature.OP_CUT)
		if SolidKernel.is_valid(r):
			result = r
		else:
			failed += 1
	if join_tool != null:
		var r2 := SolidKernel.boolean(result, join_tool, SolidFeature.OP_JOIN)
		if SolidKernel.is_valid(r2):
			result = r2
		else:
			failed += 1
	if failed > 0:
		rebuild_error = "%d edge(s) could not be %s — size too large for the geometry?" % [
			failed, "rounded" if treat == KIND_FILLET else "chamfered"]
		rebuild_level = "warning"
	elif last_note != "":
		rebuild_error = last_note
		rebuild_level = "warning"
	return result


## Ball corners: wherever exactly three PICKED convex chains meet at a
## vertex, and all three are straight (planar faces), remove the corner
## box minus the sphere and the three edge cylinders. -> solid or null.
func _ball_corners(picked: Array, _chains: Array, ordinal: int) -> RefCounted:
	var r := size_mm
	var by_vertex := {}
	for ch: Dictionary in picked:
		if bool(ch["closed"]) or not bool(ch["convex"]):
			continue
		var cp: PackedVector3Array = ch["points"]
		if cp.size() != 2:
			continue
		for ei in 2:
			var endp := cp[ei]
			var key := Vector3i(roundi(endp.x * 1000.0), roundi(endp.y * 1000.0), roundi(endp.z * 1000.0))
			if not by_vertex.has(key):
				by_vertex[key] = []
			(by_vertex[key] as Array).append({"chain": ch, "end": ei})
	var tool: RefCounted = null
	for key in by_vertex:
		var lst: Array = by_vertex[key]
		if lst.size() != 3:
			continue
		var v: Vector3 = ((lst[0]["chain"] as Dictionary)["points"] as PackedVector3Array)[int(lst[0]["end"])]
		# Edge directions pointing AWAY from the corner, and the three face
		# normals (each face appears on two of the edges).
		var dirs: Array = []
		var normals := {}
		for rec: Dictionary in lst:
			var ch: Dictionary = rec["chain"]
			var cp: PackedVector3Array = ch["points"]
			var ei := int(rec["end"])
			var other := cp[1 - ei]
			dirs.append((other - v).normalized())
			normals[int(ch["fa"])] = (ch["na"] as PackedVector3Array)[ei]
			normals[int(ch["fb"])] = (ch["nb"] as PackedVector3Array)[ei]
		if normals.size() != 3:
			continue
		var ns: Array = normals.values()
		# Sphere centre: r inside all three faces.
		var inward := -((ns[0] as Vector3) + (ns[1] as Vector3) + (ns[2] as Vector3))
		if inward.length_squared() < 1e-9:
			continue
		# Solve for the point at distance r from each of the three planes
		# through v: c = v + M^-1 * (-r, -r, -r) with rows = normals.
		var m := Basis(ns[0], ns[1], ns[2]).transposed()   # rows = normals
		if absf(m.determinant()) < 1e-9:
			continue
		var c: Vector3 = v + m.inverse() * Vector3(-r, -r, -r)
		# Corner box: spanned by the three edge directions from v, side = the
		# tangent distance along each edge... use 2r for safety (the sweeps
		# already cleaned everything beyond the corner region).
		var side := r * 2.0
		var box_pts := PackedVector3Array()
		for i in 8:
			var p := v
			if i & 1:
				p += (dirs[0] as Vector3) * side
			if i & 2:
				p += (dirs[1] as Vector3) * side
			if i & 4:
				p += (dirs[2] as Vector3) * side
			box_pts.append(p)
		# Push the corner vertex slightly outward so the box clears the faces.
		var outward := (ns[0] as Vector3 + ns[1] as Vector3 + ns[2] as Vector3).normalized()
		for i in box_pts.size():
			box_pts[i] = box_pts[i] + outward * OVERSHOOT
		var corner_box: RefCounted = ClassDB.class_call_static("MeshSolid", "hull_points", box_pts)
		if corner_box == null or not SolidKernel.is_valid(corner_box):
			continue
		var sphere := _sphere_solid(c, r, ordinal)
		var keep := sphere
		for i in 3:
			var cyl := _cylinder_solid(c, dirs[i] as Vector3, r, side * 2.0, ordinal)
			if cyl != null:
				keep = SolidKernel.boolean(keep, cyl, SolidFeature.OP_JOIN)
		var t2 := SolidKernel.boolean(corner_box, keep, SolidFeature.OP_CUT)
		if not SolidKernel.is_valid(t2):
			continue
		tool = t2 if tool == null else SolidKernel.boolean(tool, t2, SolidFeature.OP_JOIN)
	return tool


static func _sphere_solid(c: Vector3, r: float, ordinal: int) -> RefCounted:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 32
	sm.rings = 16
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sm.get_mesh_arrays())
	var s := SolidKernel.from_mesh(am, ordinal)
	return SolidKernel.transformed(s, Transform3D(Basis.IDENTITY, c)) if s != null else null


static func _cylinder_solid(c: Vector3, dir: Vector3, r: float, length: float, ordinal: int) -> RefCounted:
	var prof := PackedVector2Array([Vector2(0, -0.01), Vector2(r, -0.01), Vector2(r, length), Vector2(0, length)])
	var tris := HoleFeature.lathe(prof, 32)
	var am := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var s := SolidKernel.from_mesh(am, ordinal)
	if s == null:
		return null
	var z := dir.normalized()
	var x := z.cross(Vector3(0, 0, 1))
	if x.length() < 1e-3:
		x = z.cross(Vector3(0, 1, 0))
	x = x.normalized()
	var y := z.cross(x)
	return SolidKernel.transformed(s, Transform3D(Basis(x, y, z), c))
