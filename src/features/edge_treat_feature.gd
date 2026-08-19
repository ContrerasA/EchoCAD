class_name EdgeTreatFeature
extends Feature
## M35 3D fillet/chamfer — PRISMATIC scope, honest about what mesh CSG can
## do without a B-rep kernel: it treats the edges of a body rooted at a
## single plain EXTRUDE (no booleans, no holes in the profile).
##   - lateral edges (parallel to the extrude direction): the profile's
##     corners are rounded/cut in 2D before extrusion — exact and cheap.
##   - cap rims (top/bottom): chamfer = a conical band to an inset ring;
##     fillet = quarter-round rings of insets (loft-style bands).
## Applied by BodyBuilder's post pass: the body's mesh is REBUILT from the
## extrude's own profile with the treatments baked in. Everything else
## (booleans, revolves, sweeps) is refused with a status hint.

const KIND_FILLET := "fillet"
const KIND_CHAMFER := "chamfer"

var body := ""              # root feature id (must be a plain extrude)
var treat := KIND_FILLET
var size_mm := 3.0          # radius (fillet) or leg distance (chamfer)
var lateral := true         # round/cut every profile corner
var top := true             # treat the offset-cap rim
var bottom := false         # treat the plane-cap rim

const FILLET_STEPS := 10
const CORNER_ARC_STEPS := 16
## Corners flatter than this are left alone (a tessellated circle's
## vertices are not "corners").
const CORNER_MIN_DEG := 25.0


func kind() -> String:
	return "edge_treat"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["treat"] = treat
	d["size_mm"] = size_mm
	d["lateral"] = lateral
	d["top"] = top
	d["bottom"] = bottom
	return d


static func from_dict(d: Dictionary) -> EdgeTreatFeature:
	var f := EdgeTreatFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.treat = String(d.get("treat", KIND_FILLET))
	f.size_mm = float(d.get("size_mm", 3.0))
	f.lateral = bool(d.get("lateral", true))
	f.top = bool(d.get("top", true))
	f.bottom = bool(d.get("bottom", false))
	return f


## Round/cut the sharp corners of a CCW ring in 2D. Fillet corners become
## sampled arcs; chamfer corners become a straight cut. Returns the new
## ring, or [] when the size does not fit an edge.
static func treat_corners(poly: PackedVector2Array, p_treat: String,
		size: float) -> PackedVector2Array:
	var n := poly.size()
	var out := PackedVector2Array()
	for i in n:
		var prev := poly[(i - 1 + n) % n]
		var cur := poly[i]
		var next := poly[(i + 1) % n]
		var u := (prev - cur).normalized()
		var w := (next - cur).normalized()
		var theta := acos(clampf(u.dot(w), -1.0, 1.0))
		var turn := PI - theta
		if rad_to_deg(turn) < CORNER_MIN_DEG:
			out.append(cur)
			continue
		# Convex corners only (a fillet on a reflex corner needs material
		# ADDED — out of scope; leave it sharp).
		if (cur - prev).cross(next - cur) <= 0.0:
			out.append(cur)
			continue
		var leg := size if p_treat == KIND_CHAMFER \
			else size / tan(theta * 0.5)
		if leg > prev.distance_to(cur) * 0.5 - 1e-6 \
				or leg > next.distance_to(cur) * 0.5 - 1e-6:
			return PackedVector2Array()   # does not fit
		var t1 := cur + u * leg
		var t2 := cur + w * leg
		if p_treat == KIND_CHAMFER:
			out.append(t1)
			out.append(t2)
			continue
		var bis := (u + w).normalized()
		var center := cur + bis * (size / sin(theta * 0.5))
		var a0 := (t1 - center).angle()
		var a1 := (t2 - center).angle()
		var sweep := wrapf(a1 - a0, -PI, PI)
		for k in CORNER_ARC_STEPS + 1:
			var a := a0 + sweep * k / CORNER_ARC_STEPS
			out.append(center + Vector2(cos(a), sin(a)) * size)
	return out


## Vertical inset schedule for a cap treatment: [{dz, inset}] from the rim
## toward the cap (dz measured INTO the body from the cap plane).
static func cap_schedule(p_treat: String, size: float) -> Array:
	var out: Array = []
	if p_treat == KIND_CHAMFER:
		out.append({"dz": size, "inset": 0.0})
		out.append({"dz": 0.0, "inset": size})
		return out
	for k in FILLET_STEPS + 1:
		var a := (PI * 0.5) * k / FILLET_STEPS
		out.append({"dz": size - size * sin(a),
			"inset": size - size * cos(a)})
	return out


## The treated replacement mesh for `ef`'s body, or null (with the reason
## in "error" via the returned dict? -> null means refuse).
func build_treated_mesh(doc: CadDocument, ef: ExtrudeFeature) -> ArrayMesh:
	var sf := doc.sketch_feature(ef.sketch_id)
	if sf == null:
		return null
	var prof := ProfileFinder.profile_at(sf.sketch, ef.anchor)
	if prof.is_empty() or not (prof.get("holes", []) as Array).is_empty():
		return null
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	if ExtrudeFeature._signed_area(poly) < 0.0:
		poly.reverse()
	if lateral:
		poly = treat_corners(poly, treat, size_mm)
		if poly.is_empty():
			return null
	var h := absf(ef.distance)
	if size_mm <= 0.0 or ((top and bottom) and 2.0 * size_mm > h - 1e-6) \
			or ((top or bottom) and size_mm > h - 1e-6):
		return null
	var xf := sf.plane_transform()
	var zsign := 1.0 if ef.distance >= 0.0 else -1.0

	# Height/ring stations bottom -> top.
	var stations: Array = []   # {z (0..h), ring}
	if bottom:
		var sched := cap_schedule(treat, size_mm)
		for i in range(sched.size() - 1, -1, -1):
			var s: Dictionary = sched[i]
			var ring := SolidFeature.offset_ring(poly, -float(s["inset"]))
			if ring.size() < 3:
				return null
			stations.append({"z": float(s["dz"]), "ring": ring})
	else:
		stations.append({"z": 0.0, "ring": poly})
	if top:
		var sched2 := cap_schedule(treat, size_mm)
		# From the rim inward: dz decreases toward the cap.
		stations.append({"z": h - size_mm, "ring": poly})
		for s2: Dictionary in sched2:
			if absf(float(s2["dz"]) - size_mm) < 1e-9:
				continue   # rim station already added
			var ring2 := SolidFeature.offset_ring(poly, -float(s2["inset"]))
			if ring2.size() < 3:
				return null
			stations.append({"z": h - float(s2["dz"]), "ring": ring2})
	else:
		stations.append({"z": h, "ring": poly})

	# Bands need a common vertex count. When every station shares the SAME
	# ring (lateral-only treatments), use it verbatim — arclength resampling
	# would shave the sharp chamfer corners off. Offset rings (cap
	# treatments) resample densely instead, since Clipper offsets renumber
	# vertices freely.
	var uniform := true
	for st: Dictionary in stations:
		if (st["ring"] as PackedVector2Array) != poly:
			uniform = false
			break
	var samples := poly.size()
	if not uniform:
		for st: Dictionary in stations:
			samples = maxi(samples, (st["ring"] as PackedVector2Array).size())
		samples = maxi(samples * 4, 64)
	var rings3: Array = []
	for st: Dictionary in stations:
		var flat: PackedVector2Array = st["ring"] if uniform \
			else LoftFeature.resample_ring(st["ring"], samples)
		var world := PackedVector3Array()
		for p in flat:
			world.append(xf * Vector3(p.x, p.y, float(st["z"]) * zsign))
		rings3.append(world)
	if not uniform:
		for k in range(1, rings3.size()):
			rings3[k] = LoftFeature._align_ring(rings3[k - 1], rings3[k])

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for k in rings3.size() - 1:
		var r0: PackedVector3Array = rings3[k]
		var r1: PackedVector3Array = rings3[k + 1]
		for i in samples:
			var a0 := r0[i]
			var b0 := r0[(i + 1) % samples]
			var a1 := r1[i]
			var b1 := r1[(i + 1) % samples]
			verts.append_array([a0, b0, b1, a0, b1, a1])
			var wn := ((b0 - a0).cross(b1 - a0)).normalized()
			for _i in 6:
				normals.append(wn)
	# Caps: triangulate the first and last rings. A ccw-in-plane triangle
	# maps to a +plane-normal face, so the cap whose outward side is the
	# NEGATIVE normal gets its triangles reversed explicitly (the global
	# orientation pass below can only flip everything at once).
	for endi in [0, rings3.size() - 1]:
		var ring: PackedVector3Array = rings3[endi]
		var flat2 := PackedVector2Array()
		for p in ring:
			var local := xf.affine_inverse() * p
			flat2.append(Vector2(local.x, local.y))
		var idx := Geometry2D.triangulate_polygon(flat2)
		var outward := xf.basis.z * zsign * (1.0 if endi > 0 else -1.0)
		var reverse := outward.dot(xf.basis.z) < 0.0
		var t := 0
		while t + 2 < idx.size():
			if reverse:
				verts.append_array([ring[idx[t]], ring[idx[t + 2]],
					ring[idx[t + 1]]])
			else:
				verts.append_array([ring[idx[t]], ring[idx[t + 1]],
					ring[idx[t + 2]]])
			for _i in 3:
				normals.append(outward)
			t += 3
	if verts.is_empty():
		return null
	SweepFeature._orient_outward(verts, normals)
	LoftFeature._fix_flat_normals(verts, normals)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var edges := PackedVector3Array()
	for endi in [0, rings3.size() - 1]:
		var ring: PackedVector3Array = rings3[endi]
		for i in samples:
			edges.append_array([ring[i], ring[(i + 1) % samples]])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh
