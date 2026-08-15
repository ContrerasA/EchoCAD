class_name CmdSetConstraints
extends Command
## Replace a sketch's whole constraint list (before/after snapshot — the
## echo_vector pattern: simple, and immune to index bookkeeping bugs).
## Used for add/remove/edit of individual constraints by callers that build
## the after-list.

var _feature_id: String
var _before: Array = []
var _after: Array = []


func _init(feature_id: String, before: Array, after: Array) -> void:
	name = "Constraints"
	_feature_id = feature_id
	_before = before.duplicate()
	_after = after.duplicate()


func do_() -> void:
	var typed: Array[SketchConstraint] = []
	for c: SketchConstraint in _after:
		typed.append(c)
	doc.sketch_feature(_feature_id).sketch.constraints = typed


func undo() -> void:
	var typed: Array[SketchConstraint] = []
	for c: SketchConstraint in _before:
		typed.append(c)
	doc.sketch_feature(_feature_id).sketch.constraints = typed


func merge_with(next: Command) -> bool:
	if not (next is CmdSetConstraints):
		return false
	var n := next as CmdSetConstraints
	if n._feature_id != _feature_id:
		return false
	_after = n._after.duplicate()   # before stays: first snapshot wins
	return true


func is_noop() -> bool:
	return _before == _after
