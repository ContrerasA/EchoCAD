class_name CmdMovePoints
extends Command
## Move SketchPoints to new positions (canonical mm). Merges with a previous
## CmdMovePoints over the SAME point set — the continuous-drag primitive; the
## solver's follower moves ride along inside a CmdMergeBatch.

const EPS := 0.0001   # mm

var _feature_id: String
var _targets := {}     # id -> Vector2 (new pos)
var _old := {}         # id -> Vector2, captured on first do_
var _captured := false


func _init(feature_id: String, targets: Dictionary) -> void:
	name = "Move"
	_feature_id = feature_id
	_targets = targets.duplicate()


func do_() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _targets:
		var p := sk.point(id)
		if p == null:
			continue
		if not _captured:
			_old[id] = p.pos
		p.pos = _targets[id]
	_captured = true


func undo() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for id: String in _old:
		var p := sk.point(id)
		if p != null:
			p.pos = _old[id]


func merge_with(next: Command) -> bool:
	if not (next is CmdMovePoints):
		return false
	var n := next as CmdMovePoints
	if n._feature_id != _feature_id:
		return false
	if n._targets.keys() != _targets.keys():
		return false
	_targets = n._targets.duplicate()   # old stays: first capture wins
	return true


func is_noop() -> bool:
	for id: String in _old:
		if (_old[id] as Vector2).distance_to(_targets.get(id, _old[id])) > EPS:
			return false
	return _captured
