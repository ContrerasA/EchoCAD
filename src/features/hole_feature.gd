class_name HoleFeature
extends SolidFeature
## M40 — the hole wizard's feature: N holes of one spec placed on a planar
## body face. Always a CUT. The face is a TopoRef (the holes follow the
## face, like a face sketch); positions are uv in the face plane (the
## plane's cache `plane_xf` has z = the face's OUTWARD normal; holes bore
## along -z).
##
## Spec: simple / counterbore / countersink, diameter + depth (or through
## all), drill tip (118° cone or flat), and an optional thread — cosmetic
## (no geometry, recorded for drawings/export) or MODELLED (a real helical
## ridge is left standing inside the hole, for printing).
##
## Geometry: each hole is a lathe of its (r, depth) profile; a modelled
## thread subtracts a helical ridge from the bore inside the kernel. Holes
## that overlap are unioned before they cut.

const TYPE_SIMPLE := "simple"
const TYPE_COUNTERBORE := "counterbore"
const TYPE_COUNTERSINK := "countersink"
const EXT_DISTANCE := "distance"
const EXT_THROUGH_ALL := "through_all"
const THREAD_NONE := "none"
const THREAD_COSMETIC := "cosmetic"
const THREAD_MODELED := "modeled"

const LATHE_SEGS := 48
const THREAD_SEGS_PER_TURN := 36
const OVERSHOOT := 0.5   # mm the tool starts above the face

var ref: TopoRef = null
var plane_xf := Transform3D.IDENTITY
var uv: Array = []                 # Array[Vector2]
var hole_type := TYPE_SIMPLE
var diameter := 6.6
var depth := 10.0
var extent := EXT_DISTANCE
var cb_diameter := 11.0
var cb_depth := 6.5
var cs_diameter := 12.6
var cs_angle := 90.0
var tip_angle := 118.0             # 0 = flat bottom
var thread_mode := THREAD_NONE
var thread_id := ""                # HoleTable id ("M6", "1/4-20")
var thread_depth := 0.0            # 0 = full depth
## Resolved through-all depth (prepare()).
var _depth_resolved := 10.0


func _init() -> void:
	operation = OP_CUT


func kind() -> String:
	return "hole"


func needs_bodies() -> bool:
	return true


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["operation"] = OP_CUT
	if ref != null:
		d["ref"] = ref.to_dict()
	var b := plane_xf.basis
	var o := plane_xf.origin
	d["xf"] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z,
		o.x, o.y, o.z]
	var pts: Array = []
	for p: Vector2 in uv:
		pts.append([p.x, p.y])
	d["uv"] = pts
	d["hole_type"] = hole_type
	d["diameter"] = diameter
	d["depth"] = depth
	d["extent"] = extent
	d["cb_diameter"] = cb_diameter
	d["cb_depth"] = cb_depth
	d["cs_diameter"] = cs_diameter
	d["cs_angle"] = cs_angle
	d["tip_angle"] = tip_angle
	d["thread_mode"] = thread_mode
	d["thread_id"] = thread_id
	d["thread_depth"] = thread_depth
	return d


static func from_dict(d: Dictionary) -> HoleFeature:
	var f := HoleFeature.new()
	f._read_base(d)
	f.operation = OP_CUT
	if d.has("ref"):
		f.ref = TopoRef.from_dict(d["ref"])
	var a: Array = d.get("xf", [])
	if a.size() == 12:
		f.plane_xf = Transform3D(
			Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]),
				Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))
	f.uv = []
	for p in (d.get("uv", []) as Array):
		f.uv.append(Vector2(float(p[0]), float(p[1])))
	f.hole_type = String(d.get("hole_type", TYPE_SIMPLE))
	f.diameter = float(d.get("diameter", 6.6))
	f.depth = float(d.get("depth", 10.0))
	f.extent = String(d.get("extent", EXT_DISTANCE))
	f.cb_diameter = float(d.get("cb_diameter", 11.0))
	f.cb_depth = float(d.get("cb_depth", 6.5))
	f.cs_diameter = float(d.get("cs_diameter", 12.6))
	f.cs_angle = float(d.get("cs_angle", 90.0))
	f.tip_angle = float(d.get("tip_angle", 118.0))
	f.thread_mode = String(d.get("thread_mode", THREAD_NONE))
	f.thread_id = String(d.get("thread_id", ""))
	f.thread_depth = float(d.get("thread_depth", 0.0))
	f._depth_resolved = f.depth
	return f


## Axis direction (into the material), world.
func axis_dir() -> Vector3:
	return -plane_xf.basis.z


## World position of hole k's centre on the face.
func center_world(k: int) -> Vector3:
	var p: Vector2 = uv[k]
	return plane_xf * Vector3(p.x, p.y, 0.0)


## Re-resolve the face reference (slide the plane cache like PlaneFeature
## does) and the through-all depth against the bodies built so far.
func prepare(_doc: CadDocument, bodies: Array) -> String:
	if ref != null and ref.body != "":
		var hit := {}
		for b: Dictionary in bodies:
			if String(b["id"]) == ref.body:
				hit = ref.resolve_on(b)
				break
		if hit.is_empty():
			rebuild_level = "warning"
			rebuild_error = "face reference lost — the last position stands; re-pick the face"
		else:
			var n: Vector3 = hit["normal"]
			if n.dot(plane_xf.basis.z) > 0.99999:
				var origin := n * (hit["point"] as Vector3).dot(n)
				plane_xf = Transform3D(plane_xf.basis, origin)
			else:
				plane_xf = PlaneFeature.face_transform(hit["point"], n)
	_depth_resolved = depth
	if extent == EXT_THROUGH_ALL:
		var far := -INF
		var dir := axis_dir()
		for b: Dictionary in bodies:
			if not targets.is_empty() and not targets.has(String(b["id"])):
				continue
			var mesh: ArrayMesh = b.get("mesh")
			if mesh == null:
				continue
			var box := mesh.get_aabb()
			for i in 8:
				far = maxf(far, (box.get_endpoint(i) - plane_xf.origin).dot(dir))
		if far == -INF:
			return "through all: no body to drill through"
		_depth_resolved = far + 1.0
	if uv.is_empty():
		return "no hole positions"
	if diameter <= 0.0:
		return "diameter must be positive"
	return ""


## Bore radius the tool is lathed with: the hole diameter, or the thread's
## MAJOR diameter for a modelled thread (the ridge is subtracted after).
func _bore_radius() -> float:
	if thread_mode == THREAD_MODELED:
		var spec := thread_spec()
		if not spec.is_empty():
			return maxf(float(spec["major"]) * 0.5, diameter * 0.5)
	return diameter * 0.5


## The (r, z) profile of ONE hole's tool, z = depth into the material,
## starting OVERSHOOT above the face. ccw in the (r, z) half plane with z
## DOWN means: axis top -> outward along the top -> down the wall -> back
## to the axis at the bottom.
func _profile() -> PackedVector2Array:
	var r := _bore_radius()
	var dep := _depth_resolved
	var pts := PackedVector2Array()
	pts.append(Vector2(0.0, -OVERSHOOT))
	match hole_type:
		TYPE_COUNTERBORE:
			var rc := maxf(cb_diameter * 0.5, r + 1e-3)
			var cd := clampf(cb_depth, 1e-3, dep)
			pts.append(Vector2(rc, -OVERSHOOT))
			pts.append(Vector2(rc, cd))
			pts.append(Vector2(r, cd))
		TYPE_COUNTERSINK:
			var rs := maxf(cs_diameter * 0.5, r + 1e-3)
			var half := deg_to_rad(clampf(cs_angle, 10.0, 170.0) * 0.5)
			var cdz := (rs - r) / tan(half)
			pts.append(Vector2(rs, -OVERSHOOT))
			pts.append(Vector2(rs, 0.0))
			pts.append(Vector2(r, minf(cdz, dep)))
		_:
			pts.append(Vector2(r, -OVERSHOOT))
	# Straight bore to the depth, then the drill tip.
	pts.append(Vector2(r, dep))
	if extent == EXT_DISTANCE and tip_angle > 0.0:
		var tip := r / tan(deg_to_rad(clampf(tip_angle, 10.0, 179.0) * 0.5))
		pts.append(Vector2(0.0, dep + tip))
	else:
		pts.append(Vector2(0.0, dep))
	return pts


## Lathe a (r, z) profile about the local z axis into a closed triangle
## soup (local frame: z along the bore). Consecutive profile points with
## r == 0 collapse to the axis (no degenerate bands).
static func lathe(profile: PackedVector2Array, segs: int) -> PackedVector3Array:
	var tris := PackedVector3Array()
	var n := profile.size()
	var pos := func(p: Vector2, th: float) -> Vector3:
		return Vector3(p.x * cos(th), p.x * sin(th), p.y)
	for i in n - 1:
		var p := profile[i]
		var q := profile[i + 1]
		if p.x < 1e-9 and q.x < 1e-9:
			continue
		for j in segs:
			var th0 := TAU * j / segs
			var th1 := TAU * (j + 1) / segs
			if j == segs - 1:
				th1 = 0.0
			var a0: Vector3 = pos.call(p, th0)
			var a1: Vector3 = pos.call(p, th1)
			var b0: Vector3 = pos.call(q, th0)
			var b1: Vector3 = pos.call(q, th1)
			if p.x >= 1e-9:
				tris.append_array([a0, b0, a1])
			if q.x >= 1e-9:
				tris.append_array([a1, b0, b1])
	return tris


## Helical ridge (the material a modelled internal thread leaves standing):
## a trapezoid profile — wide root sunk past the major radius, narrow crest
## at the minor radius — swept along a helix of `pitch` from z0 to z1.
static func thread_ridge(r_minor: float, r_major: float, pitch: float,
		z0: float, z1: float) -> PackedVector3Array:
	var tris := PackedVector3Array()
	var turns := (z1 - z0) / pitch
	var steps := maxi(int(ceil(turns * THREAD_SEGS_PER_TURN)), 4)
	var root_w := pitch * 0.875
	var crest_w := pitch * 0.25
	var sink := 0.15 * (r_major - r_minor) + 0.05
	var prof := [Vector2(r_minor, -crest_w * 0.5), Vector2(r_major + sink, -root_w * 0.5),
		Vector2(r_major + sink, root_w * 0.5), Vector2(r_minor, crest_w * 0.5)]
	var ring := func(k: int) -> Array:
		var th := TAU * turns * k / steps
		var z := z0 + (z1 - z0) * k / steps
		var out: Array = []
		for p: Vector2 in prof:
			out.append(Vector3(p.x * cos(th), p.x * sin(th), z + p.y))
		return out
	var prev: Array = ring.call(0)
	# Start cap.
	tris.append_array([prev[0], prev[2], prev[1], prev[0], prev[3], prev[2]])
	for k in range(1, steps + 1):
		var cur: Array = ring.call(k)
		for e in 4:
			var a: Vector3 = prev[e]
			var b: Vector3 = prev[(e + 1) % 4]
			var c: Vector3 = cur[(e + 1) % 4]
			var d: Vector3 = cur[e]
			tris.append_array([a, b, c, a, c, d])
		prev = cur
	# End cap.
	tris.append_array([prev[0], prev[1], prev[2], prev[0], prev[2], prev[3]])
	return tris


## Local -> world for hole k: local z (bore direction) maps to -plane z.
func _hole_xf(k: int) -> Transform3D:
	var b := plane_xf.basis
	return Transform3D(Basis(b.x, -b.y, -b.z), center_world(k))


static func _soup_mesh(tris: PackedVector3Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if tris.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	var normals := PackedVector3Array()
	normals.resize(tris.size())
	for t in tris.size() / 3:
		var n := (tris[t * 3 + 1] - tris[t * 3]).cross(tris[t * 3 + 2] - tris[t * 3]).normalized()
		normals[t * 3] = n
		normals[t * 3 + 1] = n
		normals[t * 3 + 2] = n
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## One hole's tool as a local-frame triangle soup (bore + thread handled by
## the kernel in kernel_mesh; this is the plain lathe).
func _hole_tris_local() -> PackedVector3Array:
	return lathe(_profile(), LATHE_SEGS)


## Plain union-by-concatenation tool (holes assumed apart) — the render /
## AABB mesh. The kernel path (kernel_mesh) unions overlapping holes and
## carves modelled threads.
func build_mesh(_doc: CadDocument) -> ArrayMesh:
	var all := PackedVector3Array()
	var local := _hole_tris_local()
	for k in uv.size():
		var xf := _hole_xf(k)
		for v in local:
			all.append(xf * v)
	return _soup_mesh(all)


func solid_part(doc: CadDocument) -> Dictionary:
	if uv.is_empty():
		return {}
	var mesh := build_mesh(doc)
	if mesh.get_surface_count() == 0:
		return {}
	return {"feature": self, "mesh": mesh, "aabb": mesh.get_aabb().grow(0.001)}


## Thread spec from the table: {pitch, major} or {} when none applies.
func thread_spec() -> Dictionary:
	if thread_mode == THREAD_NONE or thread_id == "":
		return {}
	var e := HoleTable.find(thread_id)
	if e.is_empty():
		return {}
	return {"pitch": float(e["pitch"]), "major": float(e["major"]),
		"minor": HoleTable.tap_drill(e)}


func kernel_mesh(_doc: CadDocument, part: Dictionary) -> ArrayMesh:
	if not SolidKernel.available():
		return part.get("mesh")
	var spec := thread_spec()
	var modeled := thread_mode == THREAD_MODELED and not spec.is_empty()
	if uv.size() == 1 and not modeled:
		return part.get("mesh")
	var ordinal := SolidKernel.ordinal_of(id)
	var local_mesh := _soup_mesh(_hole_tris_local())
	var one := SolidKernel.from_mesh(local_mesh, ordinal)
	if one == null:
		return part.get("mesh")
	if modeled:
		# The bore is drilled at the MAJOR diameter and the helical ridge is
		# left standing: tool = bore − ridge. Ridge spans from just under
		# the counterbore/countersink (or the face) to thread_depth.
		var r_major := _bore_radius()
		var r_minor := minf(float(spec["minor"]) * 0.5, r_major - 0.05)
		var z_top := 0.0
		match hole_type:
			TYPE_COUNTERBORE:
				z_top = clampf(cb_depth, 1e-3, _depth_resolved)
			TYPE_COUNTERSINK:
				var rs := maxf(cs_diameter * 0.5, diameter * 0.5 + 1e-3)
				z_top = (rs - diameter * 0.5) / tan(deg_to_rad(clampf(cs_angle, 10.0, 170.0) * 0.5))
		var z_end := _depth_resolved if thread_depth <= 0.0 \
			else minf(thread_depth, _depth_resolved)
		if z_end - z_top > float(spec["pitch"]) * 1.5 and r_major > r_minor:
			var ridge_mesh := _soup_mesh(thread_ridge(r_minor, r_major,
				float(spec["pitch"]), z_top + float(spec["pitch"]) * 0.5,
				z_end - float(spec["pitch"]) * 0.5))
			var ridge := SolidKernel.from_mesh(ridge_mesh, ordinal)
			if ridge != null:
				var cut := SolidKernel.boolean(one, ridge, SolidFeature.OP_CUT)
				if SolidKernel.is_valid(cut):
					one = cut
	var solid: RefCounted = null
	for k in uv.size():
		var placed := SolidKernel.transformed(one, _hole_xf(k))
		if solid == null:
			solid = placed
		else:
			var u := SolidKernel.boolean(solid, placed, SolidFeature.OP_JOIN)
			if SolidKernel.is_valid(u):
				solid = u
	return SolidKernel.to_mesh(solid)["mesh"]
