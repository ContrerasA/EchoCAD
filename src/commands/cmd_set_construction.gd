class_name CmdSetConstruction
extends Command
## Toggle the construction flag on a set of entities (the X key, Fusion's
## normal/construction toggle). Points are excluded by the caller — a
## construction POINT has no distinct meaning here.

var _feature_id: String
var _targets := {}     # entity id -> bool (new construction state)
var _old := {}
var _captured := false


func _init(feature_id: String, targets: Dictionary) -> void:
	name = "Construction"
	_feature_id = feature_id
	_targets = targets.duplicate()


func do_() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _targets:
		var e := sk.entity(id)
		if e == null:
			continue
		if not _captured:
			_old[id] = e.construction
		e.construction = _targets[id]
	_captured = true


func undo() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _old:
		var e := sk.entity(id)
		if e != null:
			e.construction = _old[id]


func is_noop() -> bool:
	for id: String in _old:
		if bool(_old[id]) != bool(_targets.get(id, _old[id])):
			return false
	return _captured
