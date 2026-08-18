class_name PlaneFeature
extends Feature
## A construction plane (M22). Two flavors:
##  - OFFSET: a base plane (origin-plane name or an earlier plane feature id)
##    displaced `offset` mm along the base normal. Parametric — editing the
##    offset moves every sketch on the plane.
##  - CUSTOM: a stored basis+origin snapshot, minted by clicking a flat body
##    face while picking a sketch plane. A snapshot, not a parametric link to
##    the face (documented limitation).
## Like every feature it lives in the timeline: it is always created BEFORE
## the sketches that reference it, so resolution in timeline order is safe.

const KIND_OFFSET := "offset"
const KIND_CUSTOM := "custom"

var plane_kind := KIND_OFFSET
var base := "XY"                 # origin plane name or plane feature id
var offset := 10.0               # mm along the base normal
var custom_xf := Transform3D.IDENTITY

## Guard against a base-reference cycle (should be impossible through the
## UI, but a hand-edited file must not hang the app).
const MAX_CHAIN := 32


static func make_offset(p_base: String, p_offset: float) -> PlaneFeature:
	var f := PlaneFeature.new()
	f.plane_kind = KIND_OFFSET
	f.base = p_base
	f.offset = p_offset
	return f


static func make_custom(xf: Transform3D) -> PlaneFeature:
	var f := PlaneFeature.new()
	f.plane_kind = KIND_CUSTOM
	f.custom_xf = xf
	return f


## Build a plane transform from a face hit: z = the face normal, x/y the
## least-skewed world axes projected onto the plane, origin = the WORLD
## ORIGIN projected onto the face plane (Fusion keeps the sketch origin at
## the model origin's projection, which keeps coordinates relatable).
static func face_transform(point: Vector3, normal: Vector3) -> Transform3D:
	var n := normal.normalized()
	# Seed u with the world axis least parallel to n so the projection below
	# never degenerates.
	var seed := Vector3(1, 0, 0)
	if absf(n.x) > 0.9:
		seed = Vector3(0, 1, 0)
	var u := (seed - n * seed.dot(n)).normalized()
	var v := n.cross(u)   # right-handed: u x v = n
	var origin := n * point.dot(n)   # world origin projected onto the plane
	return Transform3D(Basis(u, v, n), origin)


func kind() -> String:
	return "plane"


func transform() -> Transform3D:
	return _transform_depth(0)


func _transform_depth(depth: int) -> Transform3D:
	if plane_kind == KIND_CUSTOM:
		return custom_xf
	if depth > MAX_CHAIN:
		push_warning("[PlaneFeature] base chain too deep/cyclic at %s" % id)
		return Transform3D.IDENTITY
	var base_xf := Transform3D(SketchFeature.plane_basis("XY"), Vector3.ZERO)
	if SketchFeature.PLANES.has(base):
		base_xf = Transform3D(SketchFeature.plane_basis(base), Vector3.ZERO)
	else:
		var d := document()
		var pf: PlaneFeature = null
		if d != null:
			pf = d.feature_by_id(base) as PlaneFeature
		if pf == null:
			push_warning("[PlaneFeature] %s: base plane %s not found — using XY"
				% [id, base])
		else:
			base_xf = pf._transform_depth(depth + 1)
	return Transform3D(base_xf.basis,
		base_xf.origin + base_xf.basis.z * offset)


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["plane_kind"] = plane_kind
	if plane_kind == KIND_CUSTOM:
		var b := custom_xf.basis
		var o := custom_xf.origin
		d["xf"] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z,
			b.z.x, b.z.y, b.z.z, o.x, o.y, o.z]
	else:
		d["base"] = base
		d["offset"] = offset
	return d


static func from_dict(d: Dictionary) -> PlaneFeature:
	var f := PlaneFeature.new()
	f._read_base(d)
	f.plane_kind = String(d.get("plane_kind", KIND_OFFSET))
	f.base = String(d.get("base", "XY"))
	f.offset = float(d.get("offset", 0.0))
	var a: Array = d.get("xf", [])
	if a.size() == 12:
		f.custom_xf = Transform3D(
			Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]),
				Vector3(a[6], a[7], a[8])),
			Vector3(a[9], a[10], a[11]))
	return f
