class_name Inspect
extends RefCounted
## M43 — inspection helpers over BodyBuilder entries: mass properties with
## a material density, pairwise interference, section cuts, overhang
## census for printing, bed fit. Pure functions; the app owns the UI.

## Densities in g/cm³. Ids are stable (saved per document).
const MATERIALS := {
	"pla": {"name": "PLA", "density": 1.24},
	"petg": {"name": "PETG", "density": 1.27},
	"abs": {"name": "ABS", "density": 1.04},
	"nylon": {"name": "Nylon (PA12)", "density": 1.01},
	"tpu": {"name": "TPU", "density": 1.21},
	"resin": {"name": "Resin (SLA)", "density": 1.15},
	"aluminium": {"name": "Aluminium 6061", "density": 2.70},
	"steel": {"name": "Steel", "density": 7.85},
	"stainless": {"name": "Stainless 304", "density": 8.00},
	"brass": {"name": "Brass", "density": 8.50},
	"copper": {"name": "Copper", "density": 8.96},
	"titanium": {"name": "Titanium", "density": 4.43},
	"wood": {"name": "Plywood", "density": 0.60},
	"acrylic": {"name": "Acrylic", "density": 1.18},
}
const DEFAULT_MATERIAL := "pla"


static func material_ids() -> Array:
	return MATERIALS.keys()


static func density_of(material_id: String) -> float:
	var m: Dictionary = MATERIALS.get(material_id, {})
	return float(m.get("density", 1.0))


static func material_name(material_id: String) -> String:
	var m: Dictionary = MATERIALS.get(material_id, {})
	return String(m.get("name", material_id))


## {volume_mm3, area_mm2, mass_g, centroid: Vector3, inertia_gmm2: Basis
## (about the centroid), aabb, watertight}
static func mass_properties(entry: Dictionary, density_g_cm3: float) -> Dictionary:
	var solid: Variant = entry.get("solid")
	var out := {"volume_mm3": 0.0, "area_mm2": 0.0, "mass_g": 0.0,
		"centroid": Vector3.ZERO, "inertia_gmm2": Basis(), "aabb": AABB(),
		"watertight": false}
	if solid == null:
		var mesh: ArrayMesh = entry.get("mesh")
		if mesh != null:
			out["volume_mm3"] = BodyBuilder.mesh_volume(mesh)
			out["aabb"] = mesh.get_aabb()
			out["mass_g"] = out["volume_mm3"] / 1000.0 * density_g_cm3
		return out
	var mp: Dictionary = solid.call("mass_properties")
	var vol := float(mp["volume"])
	var rho := density_g_cm3 / 1000.0   # g/mm³
	out["volume_mm3"] = vol
	out["area_mm2"] = float(mp["area"])
	out["mass_g"] = vol * rho
	out["centroid"] = mp["centroid"]
	var inertia: Basis = mp["inertia"]   # unit density, mm^5
	out["inertia_gmm2"] = Basis(inertia.x * rho, inertia.y * rho, inertia.z * rho)
	out["aabb"] = SolidKernel.aabb(solid)
	out["watertight"] = SolidKernel.is_valid(solid)
	return out


## Pairwise overlaps among entries: [{a, b, a_name, b_name, volume, mesh}].
static func interference(entries: Array) -> Array:
	var out: Array = []
	for i in entries.size():
		for j in range(i + 1, entries.size()):
			var ea: Dictionary = entries[i]
			var eb: Dictionary = entries[j]
			if ea.get("solid") == null or eb.get("solid") == null:
				continue
			if not SolidKernel.aabb(ea["solid"]).intersects(SolidKernel.aabb(eb["solid"])):
				continue
			var x := SolidKernel.boolean(ea["solid"], eb["solid"], SolidFeature.OP_INTERSECT)
			if not SolidKernel.is_valid(x):
				continue
			var v := SolidKernel.volume(x)
			if v < 1e-6:
				continue
			out.append({"a": String(ea["id"]), "b": String(eb["id"]),
				"a_name": String(ea["name"]), "b_name": String(eb["name"]),
				"volume": v, "mesh": SolidKernel.to_mesh(x)["mesh"]})
	return out


## Cut away the half-space in front of the plane (normal·x > offset) and
## return {mesh: ArrayMesh (kept part, flat shaded + edges), cap:
## ArrayMesh (the section face only)} — or {} when nothing remains.
static func section(entry: Dictionary, normal: Vector3, offset: float) -> Dictionary:
	var solid: Variant = entry.get("solid")
	if solid == null:
		return {}
	var n := normal.normalized()
	# Manifold keeps the side the normal points INTO; we keep what lies
	# behind the plane (the viewer looks at the cut), so flip.
	var kept: RefCounted = solid.call("trim_by_plane", -n, -offset)
	if kept == null or not SolidKernel.is_valid(kept):
		return {}
	var tm := SolidKernel.to_mesh(kept)
	var mesh: ArrayMesh = tm["mesh"]
	# Cap: the triangles lying on the plane, facing +n.
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cap := PackedVector3Array()
	for t in verts.size() / 3:
		var a := verts[t * 3]
		var b := verts[t * 3 + 1]
		var c := verts[t * 3 + 2]
		var tn := (b - a).cross(c - a).normalized()
		if tn.dot(n) < 0.999:
			continue
		if absf(a.dot(n) - offset) > 1e-3:
			continue
		cap.append_array([a, b, c])
	var cap_mesh := ArrayMesh.new()
	if not cap.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = cap
		cap_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return {"mesh": mesh, "cap": cap_mesh, "volume": SolidKernel.volume(kept)}


## Overhang census for printing with build direction `up` (faces whose
## outward normal points down by more than `max_deg` from horizontal need
## support). -> {area_total, area_overhang, ratio, tris: PackedVector3Array}
static func overhangs(entry: Dictionary, up: Vector3, max_deg: float) -> Dictionary:
	var mesh: ArrayMesh = entry.get("mesh")
	var out := {"area_total": 0.0, "area_overhang": 0.0, "ratio": 0.0,
		"tris": PackedVector3Array()}
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var u := up.normalized()
	var limit := -sin(deg_to_rad(max_deg))   # normal·up below this = overhang
	var tris := PackedVector3Array()
	var total := 0.0
	var over := 0.0
	var lowest := INF
	for i in verts.size():
		lowest = minf(lowest, verts[i].dot(u))
	for t in verts.size() / 3:
		var a := verts[t * 3]
		var b := verts[t * 3 + 1]
		var c := verts[t * 3 + 2]
		var nv := (b - a).cross(c - a)
		var area := nv.length() * 0.5
		if area < 1e-12:
			continue
		total += area
		var nd := (nv / (area * 2.0)).dot(u)
		# The bed face itself (lowest, flat down) is not an overhang.
		var on_bed := nd < -0.999 and absf(a.dot(u) - lowest) < 1e-3
		if nd < limit and not on_bed:
			over += area
			tris.append_array([a, b, c])
	out["area_total"] = total
	out["area_overhang"] = over
	out["ratio"] = over / total if total > 0.0 else 0.0
	out["tris"] = tris
	return out


## Does the body's bounding box fit the bed (any of the 6 axis
## permutations of its extents)? -> {fits, size, bed}
static func fits_bed(entry: Dictionary, bed: Vector3) -> Dictionary:
	var mesh: ArrayMesh = entry.get("mesh")
	if mesh == null:
		return {"fits": false, "size": Vector3.ZERO, "bed": bed}
	var s := mesh.get_aabb().size
	var dims := [s.x, s.y, s.z]
	var fits := false
	for p in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
		if dims[p[0]] <= bed.x + 1e-6 and dims[p[1]] <= bed.y + 1e-6 and dims[p[2]] <= bed.z + 1e-6:
			fits = true
			break
	return {"fits": fits, "size": s, "bed": bed}
