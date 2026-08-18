class_name ExtrudeFeature
extends SolidFeature
## Extrude a sketch profile into a solid. The profile is remembered by an
## ANCHOR POINT inside it (sketch uv, mm) rather than by entity ids — the
## sketch can be edited and the extrude re-finds the enclosing loop on
## replay, Fusion-style. Distance in mm along the sketch plane normal.
## The boolean `operation` (M18) comes from SolidFeature.

var sketch_id := ""
var anchor := Vector2.ZERO
var distance := 10.0


static func make(p_sketch_id: String, p_anchor: Vector2,
		p_distance: float, p_operation := OP_NEW_BODY) -> ExtrudeFeature:
	var f := ExtrudeFeature.new()
	f.sketch_id = p_sketch_id
	f.anchor = p_anchor
	f.distance = p_distance
	f.operation = p_operation
	return f


func kind() -> String:
	return "extrude"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["sketch_id"] = sketch_id
	d["anchor"] = [anchor.x, anchor.y]
	d["distance"] = distance
	d["operation"] = operation
	return d


static func from_dict(d: Dictionary) -> ExtrudeFeature:
	var f := ExtrudeFeature.new()
	f._read_base(d)
	f.sketch_id = String(d.get("sketch_id", ""))
	var a: Array = d.get("anchor", [0.0, 0.0])
	f.anchor = Vector2(float(a[0]), float(a[1]))
	f.distance = float(d.get("distance", 10.0))
	# Documents from before M18 carry no operation: they were all new bodies.
	f.operation = String(d.get("operation", OP_NEW_BODY))
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
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	# Normalize to CCW: cap and wall windings below assume it, and a CW
	# profile turned every face INWARD — front faces culled, so the solid
	# rendered as a see-through hollow shell.
	if _signed_area(poly) < 0.0:
		poly.reverse()
	# Holes (M18): caps are triangulated around them, and each hole boundary
	# gets its own wall loop. Hole loops walk CW so the shared wall code winds
	# their faces toward the cavity — outward for the solid.
	var holes_cw: Array = []
	for h in (prof.get("holes", []) as Array):
		var hp := (h as PackedVector2Array).duplicate()
		if _signed_area(hp) > 0.0:
			hp.reverse()
		holes_cw.append(hp)
	var tri := ProfileFinder.triangulate_with_holes(poly, prof.get("holes", []))
	var cap_pts: PackedVector2Array = tri["points"]
	var indices: PackedInt32Array = tri["indices"]
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
		var fwd: Array = [cap_pts[indices[t]], cap_pts[indices[t + 1]],
			cap_pts[indices[t + 2]]]
		var rev: Array = [cap_pts[indices[t]], cap_pts[indices[t + 2]],
			cap_pts[indices[t + 1]]]
		for p: Vector2 in (fwd if flip else rev):
			verts.append(bot.call(p))
		for _i in 3:
			normals.append(-n)
		for p: Vector2 in (rev if flip else fwd):
			verts.append(top.call(p))
		for _i in 3:
			normals.append(n)
	# Walls (winding mirrors with the distance sign too). One wall loop per
	# boundary ring: the CCW outer plus each CW hole.
	var rings: Array = [poly]
	rings.append_array(holes_cw)
	for ring: PackedVector2Array in rings:
		for i in ring.size():
			var a2 := ring[i]
			var b2 := ring[(i + 1) % ring.size()]
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
	for ring: PackedVector2Array in rings:
		var m := ring.size()
		for i in m:
			var a2 := ring[i]
			var b2 := ring[(i + 1) % m]
			edges.append_array([bot.call(a2), bot.call(b2)])
			edges.append_array([top.call(a2), top.call(b2)])
			var prev := ring[(i - 1 + m) % m]
			var din := (a2 - prev).normalized()
			var dout := (b2 - a2).normalized()
			if din.dot(dout) < cos(deg_to_rad(15.0)):   # sharp corner at a2
				edges.append_array([bot.call(a2), top.call(a2)])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


## Resolve this extrude's prism: region + plane transform + world AABB.
func solid_part(doc: CadDocument) -> Dictionary:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return {}
	var prof := ProfileFinder.profile_at(sf.sketch, anchor)
	if prof.is_empty():
		return {}
	var xf := sf.plane_transform()
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	var aabb := AABB()
	var first := true
	for z in [0.0, distance]:
		for p in outer:
			var w: Vector3 = xf * Vector3(p.x, p.y, 0.0) + xf.basis.z * float(z)
			if first:
				aabb = AABB(w, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(w)
	return {"feature": self, "prof": prof, "xf": xf,
		"aabb": aabb.grow(0.001)}


## The prism as a CSG node: the region's outer loop extruded `distance`
## along the plane normal, holes subtracted with a little overhang.
## CSGPolygon3D extrudes its local-XY polygon toward LOCAL -Z; for a
## positive distance the node is rotated PI about X (and the polygon
## y-mirrored to compensate) so -Z lands on +normal.
func csg_node(part: Dictionary) -> CSGShape3D:
	var prof: Dictionary = part["prof"]
	var xf: Transform3D = part["xf"]
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	var holes: Array = prof.get("holes", [])
	var d := absf(distance)
	var up := distance >= 0.0
	# CUT prisms extend EPS_MM past BOTH caps (the same trick the hole prisms
	# below use): a cut face coplanar with the target's cap leaves the CSG
	# classifier undecided and a zero-thickness cap skin behind (QA §M18.8).
	var cut := operation == OP_CUT
	var z0 := EPS_MM if cut else 0.0
	var depth := maxf(d, 0.001) + (2.0 * EPS_MM if cut else 0.0)
	var lift := Transform3D(Basis.IDENTITY, Vector3(0, 0, z0))
	if cut:
		# LATERAL coplanarity leaves skins too: a cut flush with the target's
		# outer face (QA §M18.3 follow-up — the roof over the notch) puts a
		# cut wall exactly ON a body wall. Grow the cut profile sideways by
		# the same hair; kept islands (holes) shrink by it.
		var grown := offset_ring(outer, EPS_MM)
		if grown.size() >= 3:
			outer = grown
		var kept: Array = []
		for h in holes:
			var hh := offset_ring(h as PackedVector2Array, -EPS_MM)
			if hh.size() >= 3:
				kept.append(hh)
		holes = kept
	var local := Transform3D(Basis.from_euler(Vector3(PI, 0, 0)), Vector3.ZERO) \
		if up else Transform3D.IDENTITY

	var map_poly := func(p_poly: PackedVector2Array) -> PackedVector2Array:
		if not up:
			return p_poly.duplicate()
		var out_p := PackedVector2Array()
		for p in p_poly:
			out_p.append(Vector2(p.x, -p.y))
		return out_p

	var outer_node := CSGPolygon3D.new()
	outer_node.polygon = map_poly.call(outer)
	outer_node.depth = depth
	if holes.is_empty():
		outer_node.transform = xf * local * lift
		return outer_node
	var c := CSGCombiner3D.new()
	c.transform = xf * local
	outer_node.transform = lift
	c.add_child(outer_node)
	for h in holes:
		var hn := CSGPolygon3D.new()
		hn.polygon = map_poly.call(h)
		hn.depth = depth + 2.0 * EPS_MM
		hn.position = Vector3(0, 0, z0 + EPS_MM)
		hn.operation = CSGShape3D.OPERATION_SUBTRACTION
		c.add_child(hn)
	return c


static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return a * 0.5


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
