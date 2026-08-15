class_name SketchLine
extends SketchEntity
## A line segment between two SketchPoint entities (by id).

var p0: String = ""
var p1: String = ""


static func make(a: String, b: String) -> SketchLine:
	var e := SketchLine.new()
	e.p0 = a
	e.p1 = b
	return e


func kind() -> String:
	return "line"


func point_refs() -> Array[String]:
	return [p0, p1]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["p0"] = p0
	d["p1"] = p1
	return d


static func from_dict(d: Dictionary) -> SketchLine:
	var e := SketchLine.new()
	e._read_base(d)
	e.p0 = String(d.get("p0", ""))
	e.p1 = String(d.get("p1", ""))
	return e
