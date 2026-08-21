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

## M40 extents. `distance` keeps its meaning (signed, along the plane
## normal) for DISTANCE; the other kinds read it as the primary side:
##   symmetric   — both ways; `symmetric_whole` = distance is the TOTAL
##   two_sided   — distance one way, distance2 the other (both magnitudes
##                 as entered; distance2 goes opposite to distance's sign)
##   to_object   — up to the face in `to_ref` (planar) along the normal
##   to_next     — up to the first body face the profile meets
##   through_all — past every body in the direction of distance's sign
## `taper_deg` drafts the walls (positive = grows with the extrusion).
const EXT_DISTANCE := "distance"
const EXT_SYMMETRIC := "symmetric"
const EXT_TWO_SIDED := "two_sided"
const EXT_TO_OBJECT := "to_object"
const EXT_TO_NEXT := "to_next"
const EXT_THROUGH_ALL := "through_all"
const EXTENTS := [EXT_DISTANCE, EXT_SYMMETRIC, EXT_TWO_SIDED, EXT_TO_OBJECT,
	EXT_TO_NEXT, EXT_THROUGH_ALL]

var extent := EXT_DISTANCE
var distance2 := 0.0
var symmetric_whole := false
var taper_deg := 0.0
var to_ref: TopoRef = null
## Resolved plane offsets of the two caps (mm along the plane normal),
## refreshed by prepare() for body-dependent extents.
var _lo := 0.0
var _hi := 10.0


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
	if extent != EXT_DISTANCE:
		d["extent"] = extent
	if distance2 != 0.0:
		d["distance2"] = distance2
	if symmetric_whole:
		d["symmetric_whole"] = true
	if taper_deg != 0.0:
		d["taper_deg"] = taper_deg
	if to_ref != null:
		d["to_ref"] = to_ref.to_dict()
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
	f.extent = String(d.get("extent", EXT_DISTANCE))
	if not EXTENTS.has(f.extent):
		f.extent = EXT_DISTANCE
	f.distance2 = float(d.get("distance2", 0.0))
	f.symmetric_whole = bool(d.get("symmetric_whole", false))
	f.taper_deg = float(d.get("taper_deg", 0.0))
	if d.has("to_ref"):
		f.to_ref = TopoRef.from_dict(d["to_ref"])
	f._lo = 0.0
	f._hi = f.distance
	return f


func needs_bodies() -> bool:
	return extent in [EXT_TO_OBJECT, EXT_TO_NEXT, EXT_THROUGH_ALL]


## Resolve the cap offsets. Distance-type extents need nothing; the body-
## dependent ones measure against `bodies` (BodyBuilder entries).
func prepare(doc: CadDocument, bodies: Array) -> String:
	_lo = 0.0
	_hi = distance
	match extent:
		EXT_SYMMETRIC:
			var h := absf(distance) * (0.5 if symmetric_whole else 1.0)
			_lo = -h
			_hi = h
		EXT_TWO_SIDED:
			var s := 1.0 if distance >= 0.0 else -1.0
			_lo = -absf(distance2) * s
			_hi = distance
		EXT_THROUGH_ALL, EXT_TO_NEXT, EXT_TO_OBJECT:
			var sf := doc.sketch_feature(sketch_id)
			if sf == null:
				return "profile no longer resolves"
			var healed := ProfileFinder.profile_at_healed(sf.sketch, anchor)
			if healed.is_empty():
				return "profile no longer resolves"
			var xf := sf.plane_transform()
			var n: Vector3 = xf.basis.z
			var s2 := 1.0 if distance >= 0.0 else -1.0
			var dir := n * s2
			var poly: PackedVector2Array = healed["prof"]["polygon"]
			var pool := targets if not targets.is_empty() else []
			if extent == EXT_THROUGH_ALL:
				var far := -INF
				for b: Dictionary in bodies:
					if not pool.is_empty() and not pool.has(String(b["id"])):
						continue
					var mesh: ArrayMesh = b.get("mesh")
					if mesh == null:
						continue
					var box := mesh.get_aabb()
					for i in 8:
						var corner := box.get_endpoint(i)
						far = maxf(far, (corner - xf.origin).dot(dir))
				if far == -INF:
					return "through all: no body to extrude through"
				_hi = (far + 1.0) * s2
			elif extent == EXT_TO_NEXT:
				var reach := -INF
				var samples: Array = []
				var cen := Vector2.ZERO
				for p in poly:
					cen += p
				cen /= maxf(poly.size(), 1)
				samples.append(cen)
				for p in poly:
					samples.append(p.lerp(cen, 0.02))
				for uv: Vector2 in samples:
					var o: Vector3 = xf * Vector3(uv.x, uv.y, 0.0)
					var hit := BodyBuilder.ray_hit(bodies, o, dir, 1e-3, pool)
					if not hit.is_empty():
						reach = maxf(reach, float(hit["t"]))
				if reach == -INF:
					return "to next: nothing in that direction to extrude to"
				_hi = reach * s2
			else:
				if to_ref == null:
					return "to object: pick a face"
				var entry := {}
				for b: Dictionary in bodies:
					if String(b["id"]) == to_ref.body:
						entry = b
				if entry.is_empty():
					return "to object: its body no longer exists"
				var fp := to_ref.resolve_on(entry)
				if fp.is_empty():
					return "to object: the face no longer exists — re-pick"
				var fn: Vector3 = fp["normal"]
				var denom := dir.dot(fn)
				if absf(denom) < 1e-6:
					return "to object: the face is parallel to the extrusion"
				var cen3: Vector2 = Vector2.ZERO
				for p in poly:
					cen3 += p
				cen3 /= maxf(poly.size(), 1)
				var o3: Vector3 = xf * Vector3(cen3.x, cen3.y, 0.0)
				var t := ((fp["point"] as Vector3) - o3).dot(fn) / denom
				if t <= 1e-6:
					return "to object: the face is behind the profile"
				_hi = t * s2
	return ""


## Per-vertex miter offset of a ring by `d` mm (positive = outward for a
## ccw ring). Keeps the vertex count, so tapered walls stay quads between
## matching cap vertices. Sharp spikes are clamped (miter limit 4).
static func miter_offset(ring: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := ring.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var p := ring[(i - 1 + n) % n]
		var c := ring[i]
		var q := ring[(i + 1) % n]
		var e0 := (c - p).normalized()
		var e1 := (q - c).normalized()
		# Outward normals of a ccw polygon point right of the edge direction.
		var n0 := Vector2(e0.y, -e0.x)
		var n1 := Vector2(e1.y, -e1.x)
		var bis := (n0 + n1)
		if bis.length_squared() < 1e-12:
			out[i] = c + n0 * d
			continue
		bis = bis.normalized()
		var cosh := bis.dot(n0)
		var scale := 1.0 / maxf(cosh, 0.25)
		out[i] = c + bis * d * scale
	return out


## Build the solid mesh from the CURRENT sketch state. null when the
## profile no longer exists.
func build_mesh(doc: CadDocument) -> ArrayMesh:
	if not needs_bodies():
		prepare(doc, [])   # distance-type extents resolve from fields alone
	return _prism_mesh(doc, _lo, _hi, 0.0)


## M38: the solid the kernel booleans with. Cut prisms overshoot both caps
## by EPS_MM so a cut flush with the target's cap removes it cleanly; the
## overshoot lies outside the body, so the cut's dimensions stay exact (no
## sideways growth — coplanar walls are the kernel's job, see
## SolidKernel.TOLERANCE_MM).
func kernel_mesh(doc: CadDocument, _part: Dictionary) -> ArrayMesh:
	if operation != OP_CUT:
		return build_mesh(doc)
	if not needs_bodies():
		prepare(doc, [])
	var s := 1.0 if _hi >= _lo else -1.0
	return _prism_mesh(doc, _lo - EPS_MM * s, _hi + EPS_MM * s, 0.0)


## The prism between plane offsets `lo` and `hi` (signed, along the plane
## normal) with the outer loop grown by `grow` mm (holes shrunk by it).
func _prism_mesh(doc: CadDocument, lo: float, hi: float, grow: float) -> ArrayMesh:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return null
	var healed := ProfileFinder.profile_at_healed(sf.sketch, anchor)
	if healed.is_empty():
		return null
	var prof: Dictionary = healed["prof"]
	anchor = healed["at"]
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
	var holes_src: Array = prof.get("holes", [])
	if grow != 0.0:
		var g := offset_ring(poly, grow)
		if g.size() >= 3:
			poly = g
			if _signed_area(poly) < 0.0:
				poly.reverse()
		var kept: Array = []
		for h in holes_src:
			var hc := (h as PackedVector2Array).duplicate()
			if _signed_area(hc) < 0.0:
				hc.reverse()
			var hh := offset_ring(hc, -grow)
			if hh.size() >= 3:
				kept.append(hh)
		holes_src = kept
	for h in holes_src:
		var hp := (h as PackedVector2Array).duplicate()
		if _signed_area(hp) > 0.0:
			hp.reverse()
		holes_cw.append(hp)
	var tri := ProfileFinder.triangulate_with_holes(poly, holes_src)
	var cap_pts: PackedVector2Array = tri["points"]
	var indices: PackedInt32Array = tri["indices"]
	if indices.is_empty():
		return null
	var xf := sf.plane_transform()
	# `n` is the OUTWARD direction of the top cap: the plane normal for a
	# positive distance, its negation for a negative one. The top verts use
	# the true signed offset along the plane normal either way.
	var n: Vector3 = xf.basis.z if hi >= lo else -xf.basis.z
	var offset: Vector3 = xf.basis.z * hi
	var base: Vector3 = xf.basis.z * lo
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()

	var top := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0) + offset
	var bot := func(p: Vector2) -> Vector3:
		return xf * Vector3(p.x, p.y, 0.0) + base
	# Draft (M40): the far cap is the profile offset by tan(taper) * height;
	# walls run between matching vertices (miter offset keeps the count).
	var taper := clampf(taper_deg, -80.0, 80.0)
	var top_of := {}   # ring index -> offset ring
	var cap_top_pts := cap_pts
	if absf(taper) > 1e-6:
		var d_off := tan(deg_to_rad(taper)) * absf(hi - lo)
		var top_poly := miter_offset(poly, d_off)
		var top_holes: Array = []
		for h in holes_cw:
			top_holes.append(miter_offset(h as PackedVector2Array, d_off))
		var tri_top := ProfileFinder.triangulate_with_holes(top_poly,
			top_holes.map(func(h): var hh := (h as PackedVector2Array).duplicate(); hh.reverse(); return hh))
		if (tri_top["indices"] as PackedInt32Array).size() == indices.size():
			cap_top_pts = tri_top["points"]
		else:
			# Triangulations disagree — fall back to mapping each cap point
			# through the ring offset (robust for convex-ish profiles).
			cap_top_pts = PackedVector2Array()
			for p in cap_pts:
				cap_top_pts.append(_map_to_offset(p, poly, top_poly, holes_cw, top_holes))
		top_of[0] = top_poly
		for k in holes_cw.size():
			top_of[k + 1] = top_holes[k]

	# Caps (plane-level cap faces -n, offset cap faces +n; `n` is the outward
	# direction of the OFFSET cap, so a negative distance mirrors the
	# windings). Flat normals per face — without a normal array the lighting
	# has nothing to shade by and the whole solid renders as one flat tone.
	var flip := hi < lo
	for t in range(0, indices.size(), 3):
		var fwd: Array = [cap_pts[indices[t]], cap_pts[indices[t + 1]],
			cap_pts[indices[t + 2]]]
		var rev: Array = [cap_pts[indices[t]], cap_pts[indices[t + 2]],
			cap_pts[indices[t + 1]]]
		for p: Vector2 in (fwd if flip else rev):
			verts.append(bot.call(p))
		for _i in 3:
			normals.append(-n)
		var fwd_t: Array = [cap_top_pts[indices[t]], cap_top_pts[indices[t + 1]],
			cap_top_pts[indices[t + 2]]]
		var rev_t: Array = [cap_top_pts[indices[t]], cap_top_pts[indices[t + 2]],
			cap_top_pts[indices[t + 1]]]
		for p: Vector2 in (rev_t if flip else fwd_t):
			verts.append(top.call(p))
		for _i in 3:
			normals.append(n)
	# Walls (winding mirrors with the distance sign too). One wall loop per
	# boundary ring: the CCW outer plus each CW hole.
	var rings: Array = [poly]
	rings.append_array(holes_cw)
	for ri in rings.size():
		var ring: PackedVector2Array = rings[ri]
		var tring: PackedVector2Array = top_of.get(ri, ring)
		for i in ring.size():
			var a2 := ring[i]
			var b2 := ring[(i + 1) % ring.size()]
			var a0: Vector3 = bot.call(a2)
			var b0: Vector3 = bot.call(b2)
			var a1: Vector3 = top.call(tring[i])
			var b1: Vector3 = top.call(tring[(i + 1) % ring.size()])
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
	for ri in rings.size():
		var ring: PackedVector2Array = rings[ri]
		var tring: PackedVector2Array = top_of.get(ri, ring)
		var m := ring.size()
		for i in m:
			var a2 := ring[i]
			var b2 := ring[(i + 1) % m]
			edges.append_array([bot.call(a2), bot.call(b2)])
			edges.append_array([top.call(tring[i]), top.call(tring[(i + 1) % m])])
			var prev := ring[(i - 1 + m) % m]
			var din := (a2 - prev).normalized()
			var dout := (b2 - a2).normalized()
			if din.dot(dout) < cos(deg_to_rad(15.0)):   # sharp corner at a2
				edges.append_array([bot.call(a2), top.call(tring[i])])
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
	var healed := ProfileFinder.profile_at_healed(sf.sketch, anchor)
	if healed.is_empty():
		return {}
	var prof: Dictionary = healed["prof"]
	anchor = healed["at"]
	var xf := sf.plane_transform()
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	var aabb := AABB()
	var first := true
	if not needs_bodies():
		prepare(doc, [])
	var spread := absf(tan(deg_to_rad(clampf(taper_deg, -80.0, 80.0)))) * absf(_hi - _lo)
	for z in [_lo, _hi]:
		for p in outer:
			var w: Vector3 = xf * Vector3(p.x, p.y, 0.0) + xf.basis.z * float(z)
			if first:
				aabb = AABB(w, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(w)
	return {"feature": self, "prof": prof, "xf": xf,
		"aabb": aabb.grow(0.001 + spread)}


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


## Map a cap triangulation point to the offset cap: ring vertices map to
## their offset twin, interior (Steiner) points stay put.
static func _map_to_offset(p: Vector2, poly: PackedVector2Array, top_poly: PackedVector2Array,
		holes: Array, top_holes: Array) -> Vector2:
	for i in poly.size():
		if poly[i].distance_squared_to(p) < 1e-12:
			return top_poly[i]
	for k in holes.size():
		var h: PackedVector2Array = holes[k]
		var th: PackedVector2Array = top_holes[k]
		for i in h.size():
			if h[i].distance_squared_to(p) < 1e-12:
				return th[i]
	return p


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
