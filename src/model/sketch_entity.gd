class_name SketchEntity
extends RefCounted
## Base for every typed sketch entity. Geometry is TYPED (point/line/arc/
## circle) — never bezier paths; conversion to render paths happens only at
## the render boundary. Every endpoint and center is a real SketchPoint
## entity, so solver variables and constraint refs are simply entity ids.

## Stable per-sketch id ("e<n>"), minted by Sketch.next_id(), never reused.
var id: String = ""
## Construction geometry: dashed render, excluded from profiles/solids,
## still selectable and constrainable.
var construction := false


func kind() -> String:
	return ""


## Ids of the SketchPoint entities this entity depends on (empty for a point).
func point_refs() -> Array[String]:
	return []


func to_dict() -> Dictionary:
	var d := {"id": id, "kind": kind()}
	if construction:
		d["construction"] = true
	return d


func _read_base(d: Dictionary) -> void:
	id = String(d.get("id", ""))
	construction = bool(d.get("construction", false))
