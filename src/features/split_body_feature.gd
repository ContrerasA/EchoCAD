class_name SplitBodyFeature
extends Feature
## M42 — split a body by a plane (origin / construction plane) or by a
## planar body face. Both halves stay: the original id keeps the half on
## the plane's positive side, the other half becomes body `<fid>`.

const BY_PLANE := "plane"
const BY_FACE := "face"

var body := ""
var by := BY_PLANE
var plane := "XY"              # origin-plane name or plane feature id
var face_ref: TopoRef = null   # BY_FACE
## Cached splitting plane (world), refreshed on build.
var plane_normal := Vector3(0, 0, 1)
var plane_offset := 0.0


func kind() -> String:
	return "split_body"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["by"] = by
	d["plane"] = plane
	if face_ref != null:
		d["face_ref"] = face_ref.to_dict()
	return d


static func from_dict(d: Dictionary) -> SplitBodyFeature:
	var f := SplitBodyFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.by = String(d.get("by", BY_PLANE))
	f.plane = String(d.get("plane", "XY"))
	if d.has("face_ref"):
		f.face_ref = TopoRef.from_dict(d["face_ref"])
	return f


## Resolve the splitting plane against the document / bodies. "" or error.
func resolve_plane(doc: CadDocument, bodies: Array) -> String:
	if by == BY_FACE:
		if face_ref == null:
			return "pick a face to split by"
		var entry := {}
		for b: Dictionary in bodies:
			if String(b["id"]) == face_ref.body:
				entry = b
		if entry.is_empty():
			return "the face's body no longer exists"
		var fp := face_ref.resolve_on(entry)
		if fp.is_empty():
			return "the face no longer exists — re-pick"
		plane_normal = (fp["normal"] as Vector3).normalized()
		plane_offset = (fp["point"] as Vector3).dot(plane_normal)
		return ""
	var xf: Transform3D
	if SketchFeature.PLANES.has(plane):
		xf = Transform3D(SketchFeature.plane_basis(plane), Vector3.ZERO)
	else:
		var pf := doc.plane_feature(plane)
		if pf == null:
			return "unknown plane %s" % plane
		xf = pf.transform()
	plane_normal = xf.basis.z.normalized()
	plane_offset = xf.origin.dot(plane_normal)
	return ""
