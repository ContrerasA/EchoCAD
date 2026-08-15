class_name SketchCircle
extends SketchEntity
## A full circle: center SketchPoint (by id) + radius (canonical mm). Radius
## is a first-class solver variable.

var center: String = ""
var radius := 0.0


static func make(c: String, r: float) -> SketchCircle:
	var e := SketchCircle.new()
	e.center = c
	e.radius = r
	return e


func kind() -> String:
	return "circle"


func point_refs() -> Array[String]:
	return [center]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["center"] = center
	d["radius"] = radius
	return d


static func from_dict(d: Dictionary) -> SketchCircle:
	var e := SketchCircle.new()
	e._read_base(d)
	e.center = String(d.get("center", ""))
	e.radius = float(d.get("radius", 0.0))
	return e
