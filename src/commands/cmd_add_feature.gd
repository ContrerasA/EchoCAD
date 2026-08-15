class_name CmdAddFeature
extends Command
## Insert a feature at the timeline marker (Fusion behavior: new features
## land where the marker is) and advance the marker past it.

var _feature: Feature
var _at := -1


func _init(feature: Feature) -> void:
	name = "Add %s" % feature.kind().capitalize()
	_feature = feature


func do_() -> void:
	_at = clampi(doc.timeline_marker, 0, doc.features.size())
	doc.features.insert(_at, _feature)
	doc.timeline_marker = _at + 1


func undo() -> void:
	doc.features.remove_at(_at)
	doc.timeline_marker = _at
