class_name CopyBodyFeature
extends Feature
## M32 "Copy Body": a PARAMETRIC duplicate of another body, offset by a
## translation — edit the source and the copy follows (pattern-style).
## Applied by BodyBuilder after boolean resolution; the copy is a body of
## its own (browser row, eye, STL export, its own later moves).

var source := ""                  # root feature id of the copied body
var translation := Vector3.ZERO   # mm
## Own appearance (QA §M32.5): alpha 0 = inherit the source body's color
## (the default); an explicit Color… on the copy sets an opaque own color.
var color := Color(0, 0, 0, 0)


func kind() -> String:
	return "copy_body"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["source"] = source
	d["translation"] = [translation.x, translation.y, translation.z]
	if color.a > 0.0:
		d["color"] = [color.r, color.g, color.b]
	return d


static func from_dict(d: Dictionary) -> CopyBodyFeature:
	var f := CopyBodyFeature.new()
	f._read_base(d)
	f.source = String(d.get("source", ""))
	var t: Array = d.get("translation", [0, 0, 0])
	f.translation = Vector3(float(t[0]), float(t[1]), float(t[2]))
	if d.has("color"):
		var c: Array = d["color"]
		f.color = Color(float(c[0]), float(c[1]), float(c[2]), 1.0)
	return f
