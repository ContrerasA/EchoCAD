class_name PatternBodyFeature
extends Feature
## M33: linear (1–2 directions) or circular pattern of a BODY. Instances
## are parametric copies applied by BodyBuilder after boolean resolution
## (like moves/copies/mirrors); each instance is a body of its own
## (id "<fid>:<k>") with a browser row and eye.

const MODE_LINEAR := "linear"
const MODE_CIRCULAR := "circular"

var source := ""
var mode := MODE_LINEAR
## Linear: count1 copies stepped by offset1, count2 by offset2 (count2 = 1
## disables the second direction).
var count1 := 2
var offset1 := Vector3(20, 0, 0)
var count2 := 1
var offset2 := Vector3.ZERO
## Circular: `count` instances about the axis through `axis_origin`.
var axis_origin := Vector3.ZERO
var axis_dir := Vector3(0, 0, 1)
var total_deg := 360.0


## Every instance transform EXCEPT the identity (the source body itself).
func instance_transforms() -> Array:
	var out: Array = []
	if mode == MODE_CIRCULAR:
		var n := clampi(count1, 2, 128)
		var step := deg_to_rad(step_deg(n, total_deg))
		var dir := axis_dir.normalized() if axis_dir.length() > 1e-9 \
			else Vector3(0, 0, 1)
		for k in range(1, n):
			out.append(Transform3D(Basis.IDENTITY, axis_origin)
				* Transform3D(Basis(dir, step * k), Vector3.ZERO)
				* Transform3D(Basis.IDENTITY, -axis_origin))
		return out
	var n1 := clampi(count1, 1, 64)
	var n2 := clampi(count2, 1, 64)
	for j in n2:
		for i in n1:
			if i == 0 and j == 0:
				continue
			out.append(Transform3D(Basis.IDENTITY,
				offset1 * i + offset2 * j))
	return out


## Same convention as the sketch circular pattern: full circle spaces
## evenly; a partial angle lands the last instance ON it.
static func step_deg(count: int, total: float) -> float:
	if absf(fposmod(total, 360.0)) < 1e-9:
		return total / count
	return total / maxi(count - 1, 1)


func kind() -> String:
	return "pattern_body"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["source"] = source
	d["mode"] = mode
	d["count1"] = count1
	d["offset1"] = [offset1.x, offset1.y, offset1.z]
	d["count2"] = count2
	d["offset2"] = [offset2.x, offset2.y, offset2.z]
	d["axis_origin"] = [axis_origin.x, axis_origin.y, axis_origin.z]
	d["axis_dir"] = [axis_dir.x, axis_dir.y, axis_dir.z]
	d["total_deg"] = total_deg
	return d


static func from_dict(d: Dictionary) -> PatternBodyFeature:
	var f := PatternBodyFeature.new()
	f._read_base(d)
	f.source = String(d.get("source", ""))
	f.mode = String(d.get("mode", MODE_LINEAR))
	f.count1 = int(d.get("count1", 2))
	var o1: Array = d.get("offset1", [20, 0, 0])
	f.offset1 = Vector3(float(o1[0]), float(o1[1]), float(o1[2]))
	f.count2 = int(d.get("count2", 1))
	var o2: Array = d.get("offset2", [0, 0, 0])
	f.offset2 = Vector3(float(o2[0]), float(o2[1]), float(o2[2]))
	var ao: Array = d.get("axis_origin", [0, 0, 0])
	f.axis_origin = Vector3(float(ao[0]), float(ao[1]), float(ao[2]))
	var ad: Array = d.get("axis_dir", [0, 0, 1])
	f.axis_dir = Vector3(float(ad[0]), float(ad[1]), float(ad[2]))
	f.total_deg = float(d.get("total_deg", 360.0))
	return f
