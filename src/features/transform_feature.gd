class_name TransformFeature
extends Feature
## M32 "Move Body": rotate a body about its own center (axis + angle) then
## translate it. A timeline feature — parametric, editable, suppressible —
## applied by BodyBuilder AFTER the body's boolean chain resolves (known
## limitation carried from M18: booleans target by pre-move AABB overlap).

var body := ""                    # root feature id of the body it moves
var translation := Vector3.ZERO   # mm
var rot_axis := Vector3(0, 0, 1)
var rot_deg := 0.0


func kind() -> String:
	return "transform"


## The world transform this feature applies, rotating about `center`.
func transform3d(center: Vector3) -> Transform3D:
	var basis := Basis.IDENTITY
	if absf(rot_deg) > 1e-9 and rot_axis.length() > 1e-9:
		basis = Basis(rot_axis.normalized(), deg_to_rad(rot_deg))
	return Transform3D(Basis.IDENTITY, translation) \
		* Transform3D(Basis.IDENTITY, center) \
		* Transform3D(basis, Vector3.ZERO) \
		* Transform3D(Basis.IDENTITY, -center)


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["translation"] = [translation.x, translation.y, translation.z]
	d["rot_axis"] = [rot_axis.x, rot_axis.y, rot_axis.z]
	d["rot_deg"] = rot_deg
	return d


static func from_dict(d: Dictionary) -> TransformFeature:
	var f := TransformFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	var t: Array = d.get("translation", [0, 0, 0])
	f.translation = Vector3(float(t[0]), float(t[1]), float(t[2]))
	var a: Array = d.get("rot_axis", [0, 0, 1])
	f.rot_axis = Vector3(float(a[0]), float(a[1]), float(a[2]))
	f.rot_deg = float(d.get("rot_deg", 0.0))
	return f
