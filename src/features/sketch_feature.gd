class_name SketchFeature
extends Feature
## A sketch on a plane. Phase 1 planes are the three origin planes by name;
## face/offset planes come with phase 2.

const PLANES := ["XY", "XZ", "YZ"]

var plane: String = "XY"
var sketch: Sketch = null


static func make(fname: String, fplane := "XY") -> SketchFeature:
	var f := SketchFeature.new()
	f.name = fname
	f.plane = fplane
	f.sketch = Sketch.new()
	return f


func kind() -> String:
	return "sketch"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["plane"] = plane
	d["sketch"] = sketch.to_dict()
	return d


static func from_dict(d: Dictionary) -> SketchFeature:
	var f := SketchFeature.new()
	f._read_base(d)
	f.plane = String(d.get("plane", "XY"))
	f.sketch = Sketch.from_dict(d.get("sketch", {}) as Dictionary)
	return f
