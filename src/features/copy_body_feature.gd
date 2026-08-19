class_name CopyBodyFeature
extends Feature
## M32 "Copy Body": a PARAMETRIC duplicate of another body, offset by a
## translation — edit the source and the copy follows (pattern-style).
## Applied by BodyBuilder after boolean resolution; the copy is a body of
## its own (browser row, eye, STL export, its own later moves).

var source := ""                  # root feature id of the copied body
var translation := Vector3.ZERO   # mm


func kind() -> String:
	return "copy_body"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["source"] = source
	d["translation"] = [translation.x, translation.y, translation.z]
	return d


static func from_dict(d: Dictionary) -> CopyBodyFeature:
	var f := CopyBodyFeature.new()
	f._read_base(d)
	f.source = String(d.get("source", ""))
	var t: Array = d.get("translation", [0, 0, 0])
	f.translation = Vector3(float(t[0]), float(t[1]), float(t[2]))
	return f
