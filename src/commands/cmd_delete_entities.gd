class_name CmdDeleteEntities
extends Command
## Delete entities by id AND prune every constraint referencing them, in one
## undo step. Captures entities with their list indices on first do_ so undo
## restores original order; ids are never re-minted.

var _feature_id: String
var _ids: Array = []               # Array[String]
var _captured := false
var _removed: Array = []           # [{entity, index}] in ascending index order
var _constraints_before: Array = []
var _constraints_after: Array = []


func _init(feature_id: String, ids: Array) -> void:
	name = "Delete"
	_feature_id = feature_id
	_ids = ids.duplicate()


func do_() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	if not _captured:
		_captured = true
		_constraints_before = sk.constraints.duplicate()
		var pairs: Array = []
		for id: String in _ids:
			if sk.has(id):
				pairs.append({"entity": sk.entity(id), "index": sk.index_of(id)})
		pairs.sort_custom(func(a, b): return int(a["index"]) < int(b["index"]))
		_removed = pairs
		sk.prune_constraints_for(_ids)
		_constraints_after = sk.constraints.duplicate()
	else:
		sk.constraints = _constraints_after.duplicate()
	for r: Dictionary in _removed:
		sk.remove((r["entity"] as SketchEntity).id)


func undo() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for r: Dictionary in _removed:      # ascending index -> insertions line up
		sk.add(r["entity"] as SketchEntity, int(r["index"]))
	sk.constraints = _constraints_before.duplicate()


func is_noop() -> bool:
	return _captured and _removed.is_empty() \
		and _constraints_before == _constraints_after
