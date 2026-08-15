class_name SketchArc
extends SketchEntity
## A circular arc: center + start + end SketchPoints (by id), winding flag.
## Radius is DERIVED (|start - center|); the solver keeps |start-center| ==
## |end-center| as an implicit coupling. ccw = true means the arc sweeps
## counter-clockwise from start to end.

var center: String = ""
var start: String = ""
var end: String = ""
var ccw := true


static func make(c: String, s: String, e: String, is_ccw := true) -> SketchArc:
	var a := SketchArc.new()
	a.center = c
	a.start = s
	a.end = e
	a.ccw = is_ccw
	return a


func kind() -> String:
	return "arc"


func point_refs() -> Array[String]:
	return [center, start, end]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["center"] = center
	d["start"] = start
	d["end"] = end
	d["ccw"] = ccw
	return d


static func from_dict(d: Dictionary) -> SketchArc:
	var a := SketchArc.new()
	a._read_base(d)
	a.center = String(d.get("center", ""))
	a.start = String(d.get("start", ""))
	a.end = String(d.get("end", ""))
	a.ccw = bool(d.get("ccw", true))
	return a
