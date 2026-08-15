class_name Feature
extends RefCounted
## Base of every timeline feature. The document is an ORDERED feature list
## (Sketch1, Sketch2, later Extrude1...); document state is the replay of
## features up to the rollback marker. Feature mutations happen only through
## commands.

## Stable id ("f<n>"), minted by CadDocument.next_feature_id(), never reused.
var id: String = ""
var name: String = ""
var suppressed := false


func kind() -> String:
	return ""


func to_dict() -> Dictionary:
	var d := {"id": id, "kind": kind(), "name": name}
	if suppressed:
		d["suppressed"] = true
	return d


func _read_base(d: Dictionary) -> void:
	id = String(d.get("id", ""))
	name = String(d.get("name", ""))
	suppressed = bool(d.get("suppressed", false))
