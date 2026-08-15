class_name CmdSetEntityRef
extends Command
## Rewire one point-reference field of an entity (line p0/p1, arc
## center/start/end, circle center) to a different SketchPoint — the fillet
## seam: a shared corner point is split so each line gets its own endpoint.

var _feature_id: String
var _entity_id: String
var _field: String
var _to: String
var _from := ""


func _init(feature_id: String, entity_id: String, field: String, to: String) -> void:
	name = "Rewire"
	_feature_id = feature_id
	_entity_id = entity_id
	_field = field
	_to = to


func do_() -> void:
	var e := doc.sketch_feature(_feature_id).sketch.entity(_entity_id)
	if e == null:
		return
	_from = e.get(_field)
	e.set(_field, _to)


func undo() -> void:
	var e := doc.sketch_feature(_feature_id).sketch.entity(_entity_id)
	if e != null:
		e.set(_field, _from)


func is_noop() -> bool:
	return _from == _to
