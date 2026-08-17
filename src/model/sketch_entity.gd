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
## Projection link (M15 "Project"): the feature id + entity id this entity was
## projected FROM. Both "" = ordinary geometry. Projected geometry follows its
## source (Projector.refresh), is pinned in the solver and DOF analysis, and
## renders in its own colour. Deleting the source BREAKS the link (fields
## cleared) and the entity becomes ordinary geometry — never a crash.
var link_feature := ""
var link_entity := ""


func is_projected() -> bool:
	return link_feature != "" and link_entity != ""


func kind() -> String:
	return ""


## Ids of the SketchPoint entities this entity depends on (empty for a point).
func point_refs() -> Array[String]:
	return []


func to_dict() -> Dictionary:
	var d := {"id": id, "kind": kind()}
	if construction:
		d["construction"] = true
	if is_projected():
		d["link"] = [link_feature, link_entity]
	return d


func _read_base(d: Dictionary) -> void:
	id = String(d.get("id", ""))
	construction = bool(d.get("construction", false))
	var link: Array = d.get("link", [])
	if link.size() == 2:
		link_feature = String(link[0])
		link_entity = String(link[1])
