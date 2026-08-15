class_name SketchPoint
extends SketchEntity
## A point in sketch-plane coordinates (canonical mm). Line endpoints, arc
## centers/endpoints, and circle centers are all real SketchPoints; the
## points ARE the solver variables. Coincidence links points via a
## constraint — never a topological merge.

var pos := Vector2.ZERO


static func make(p: Vector2) -> SketchPoint:
	var e := SketchPoint.new()
	e.pos = p
	return e


func kind() -> String:
	return "point"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["pos"] = [pos.x, pos.y]
	return d


static func from_dict(d: Dictionary) -> SketchPoint:
	var e := SketchPoint.new()
	e._read_base(d)
	var p: Array = d.get("pos", [0.0, 0.0])
	e.pos = Vector2(float(p[0]), float(p[1]))
	return e
