class_name CmdSetRadii
extends Command
## Set circle radii (solver follower moves / radius edits). Merges with a
## previous CmdSetRadii over the same circle set — continuous-drag primitive.

var _feature_id: String
var _targets := {}     # circle id -> float
var _old := {}
var _captured := false


func _init(feature_id: String, targets: Dictionary) -> void:
	name = "Radius"
	_feature_id = feature_id
	_targets = targets.duplicate()


func do_() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _targets:
		var c := sk.entity(id) as SketchCircle
		if c == null:
			continue
		if not _captured:
			_old[id] = c.radius
		c.radius = _targets[id]
	_captured = true


func undo() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _old:
		var c := sk.entity(id) as SketchCircle
		if c != null:
			c.radius = _old[id]


func merge_with(next: Command) -> bool:
	if not (next is CmdSetRadii):
		return false
	var n := next as CmdSetRadii
	if n._feature_id != _feature_id or n._targets.keys() != _targets.keys():
		return false
	_targets = n._targets.duplicate()
	return true


func is_noop() -> bool:
	for id: String in _old:
		if absf(float(_old[id]) - float(_targets.get(id, _old[id]))) > 1e-9:
			return false
	return _captured
