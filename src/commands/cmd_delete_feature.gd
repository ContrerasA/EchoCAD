class_name CmdDeleteFeature
extends Command
## Remove a feature by id; undo restores it at its original index and
## restores the marker.

var _feature_id: String
var _feature: Feature = null
var _at := -1
var _marker_before := 0


func _init(feature_id: String) -> void:
	name = "Delete Feature"
	_feature_id = feature_id


func do_() -> void:
	_marker_before = doc.timeline_marker
	for i in doc.features.size():
		if doc.features[i].id == _feature_id:
			_at = i
			_feature = doc.features[i]
			doc.features.remove_at(i)
			break
	if _at >= 0 and doc.timeline_marker > _at:
		doc.timeline_marker -= 1


func undo() -> void:
	if _at < 0:
		return
	doc.attach(_feature)
	doc.features.insert(_at, _feature)
	doc.timeline_marker = _marker_before


func is_noop() -> bool:
	return _feature == null
