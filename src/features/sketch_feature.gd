class_name SketchFeature
extends Feature
## A sketch on a plane. Phase 1 planes are the three origin planes by name;
## face/offset planes come with phase 2.

const PLANES := ["XY", "XZ", "YZ"]

var plane: String = "XY"
var sketch: Sketch = null


## Sketch-plane basis in 3D world space (world units are mm, like the model).
## Columns: x = sketch +X, y = sketch +Y, z = plane normal. A sketch point
## (u, v) sits at world `plane_transform() * Vector3(u, v, 0)`.
##
## The world is Z-UP (Blender/Fusion convention): +Z is up, XY is the ground
## plane, and each basis is right-handed so the normal follows +u x +v.
static func plane_basis(plane_name: String) -> Basis:
	match plane_name:
		"XZ":                                  # front: +u = +X, +v = +Z, n = -Y
			return Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0))
		"YZ":                                  # right: +u = +Y, +v = +Z, n = +X
			return Basis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0))
	# XY = top/ground plane, normal +Z (up).
	return Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))


func plane_transform() -> Transform3D:
	return Transform3D(plane_basis(plane), Vector3.ZERO)


## Sketch (u, v) mm -> world position.
func to_world(p: Vector2) -> Vector3:
	return plane_transform() * Vector3(p.x, p.y, 0.0)


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
