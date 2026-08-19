class_name MirrorBodyFeature
extends Feature
## M33: mirror a BODY across an origin or construction plane — a new body,
## parametric against its source (edit the source, the mirror follows).
## Applied by BodyBuilder after boolean resolution, like moves and copies.

var source := ""     # root feature id of the mirrored body
var plane := "XY"    # origin-plane name or plane feature id


func kind() -> String:
	return "mirror_body"


## Reflection across the plane, in world space.
func mirror_transform() -> Transform3D:
	var p := _plane_transform()
	var flip := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, 0, -1)), Vector3.ZERO)
	return p * flip * p.affine_inverse()


func _plane_transform() -> Transform3D:
	if SketchFeature.PLANES.has(plane):
		return Transform3D(SketchFeature.plane_basis(plane), Vector3.ZERO)
	var d := document()
	return d.plane_transform(plane) if d != null else Transform3D.IDENTITY


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["source"] = source
	d["plane"] = plane
	return d


static func from_dict(d: Dictionary) -> MirrorBodyFeature:
	var f := MirrorBodyFeature.new()
	f._read_base(d)
	f.source = String(d.get("source", ""))
	f.plane = String(d.get("plane", "XY"))
	return f
