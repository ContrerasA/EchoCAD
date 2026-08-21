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

## M38: why the last rebuild could not compute this feature ("" = fine).
## Transient — set by BodyBuilder every build, never serialized; the
## timeline paints a chip red and shows this as its tooltip.
var rebuild_error := ""
## "error" (the feature computed nothing) or "warning" (it computed from a
## stale reference — M39 lost face refs). Drives the chip tint.
var rebuild_level := "error"

## Weak back-reference to the owning document (set by CadDocument.attach),
## so features that reference OTHER features — a sketch on a construction
## plane, an offset plane chained on another — can resolve them. Weak to
## avoid a RefCounted cycle. Null for a feature never added to a document
## (origin-plane sketches keep working without one).
var doc_ref: WeakRef = null


func document() -> CadDocument:
	if doc_ref == null:
		return null
	return doc_ref.get_ref() as CadDocument


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
