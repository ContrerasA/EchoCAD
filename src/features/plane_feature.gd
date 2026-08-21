class_name PlaneFeature
extends Feature
## A construction plane (M22). Two flavors:
##  - OFFSET: a base plane (origin-plane name or an earlier plane feature id)
##    displaced `offset` mm along the base normal. Parametric — editing the
##    offset moves every sketch on the plane.
##  - FACE (M39): a parametric link to a body face through a TopoRef. The
##    stored transform is the last RESOLVED pose (BodyBuilder refreshes it
##    in timeline order on every rebuild, so editing the extrude moves the
##    sketches on the face). When the reference cannot be resolved the last
##    pose stands and the feature carries a rebuild warning.
##  - CUSTOM: a plain basis+origin snapshot (pre-M39 face planes; on load
##    they become unbound FACE planes that adopt a matching face if one
##    exists, else keep behaving as snapshots).
## Like every feature it lives in the timeline: it is always created BEFORE
## the sketches that reference it, so resolution in timeline order is safe.

const KIND_OFFSET := "offset"
const KIND_CUSTOM := "custom"
const KIND_FACE := "face"

var plane_kind := KIND_OFFSET
var base := "XY"                 # origin plane name or plane feature id
var offset := 10.0               # mm along the base normal
var custom_xf := Transform3D.IDENTITY
## FACE planes: the face reference (null for the other kinds).
var ref: TopoRef = null

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


## M39: a plane bound to a body face. `xf` is the pose as clicked (the
## cache until the next rebuild resolves the reference).
static func make_face(p_ref: TopoRef, xf: Transform3D) -> PlaneFeature:
	var f := PlaneFeature.new()
	f.plane_kind = KIND_FACE
	f.ref = p_ref
	f.custom_xf = xf
	return f


## Re-resolve a FACE plane against the bodies built so far (BodyBuilder,
## timeline order). Returns true when the face was found; the transform
## cache is refreshed from the face's current plane, keeping the sketch's
## u/v axes stable across moves (only the origin slides along the normal
## unless the face actually tilts).
func resolve_face(bodies: Array) -> bool:
	if plane_kind != KIND_FACE or ref == null:
		return false
	var hit := {}
	if ref.body != "":
		for b: Dictionary in bodies:
			if String(b["id"]) == ref.body:
				hit = ref.resolve_on(b)
				break
	else:
		# Unbound (migrated snapshot): adopt the first body with a matching face.
		for b: Dictionary in bodies:
			hit = ref.resolve_on(b)
			if not hit.is_empty():
				ref.body = String(b["id"])
				break
	if hit.is_empty():
		return false
	var n: Vector3 = hit["normal"]
	var old_n: Vector3 = custom_xf.basis.z
	if n.dot(old_n) > 0.99999:
		# Same orientation: slide the plane, keep the axes.
		var origin := n * (hit["point"] as Vector3).dot(n)
		custom_xf = Transform3D(custom_xf.basis, origin)
	else:
		custom_xf = face_transform(hit["point"], n)
	return true


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
	if plane_kind == KIND_CUSTOM or plane_kind == KIND_FACE:
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
	if plane_kind == KIND_CUSTOM or plane_kind == KIND_FACE:
		var b := custom_xf.basis
		var o := custom_xf.origin
		d["xf"] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z,
			b.z.x, b.z.y, b.z.z, o.x, o.y, o.z]
		if ref != null and ref.body != "":
			d["ref"] = ref.to_dict()
		else:
			# Still a snapshot (migrated, never bound): write it as the
			# pre-M39 form so old files round-trip byte-identically.
			d["plane_kind"] = KIND_CUSTOM
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
	if d.has("ref"):
		f.ref = TopoRef.from_dict(d["ref"])
	elif f.plane_kind == KIND_CUSTOM and a.size() == 12:
		# Migration (M39): a pre-M39 face snapshot becomes an UNBOUND face
		# plane — it adopts the body face its plane matches on the first
		# rebuild and stays a snapshot otherwise.
		f.plane_kind = KIND_FACE
		f.ref = TopoRef.make("", -1, f.custom_xf.basis.z, f.custom_xf.origin)
	return f
