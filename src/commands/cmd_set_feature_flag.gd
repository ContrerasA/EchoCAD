class_name CmdSetFeatureFlag
extends Command
## Toggle a feature's suppressed flag (or rename it).

var _feature_id: String
var _field: String
var _to: Variant
var _from: Variant


func _init(feature_id: String, field: String, to: Variant) -> void:
	name = "Feature " + field.capitalize()
	_feature_id = feature_id
	_field = field
	_to = to


func do_() -> void:
	var f := doc.feature_by_id(_feature_id)
	if f == null:
		return
	_from = f.get(_field)
	f.set(_field, _to)


func undo() -> void:
	var f := doc.feature_by_id(_feature_id)
	if f != null:
		f.set(_field, _from)


func is_noop() -> bool:
	return _from == _to
