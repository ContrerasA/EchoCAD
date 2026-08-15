class_name CmdAddEntities
extends Command
## Add pre-built entities (ids already minted via Sketch.next_id) to a
## sketch, optionally with constraints created alongside them (a rectangle =
## 4 points + 4 lines + H/V/coincident, one undo step). Ids are minted at
## construction time so redo re-adds the identical objects.

var _feature_id: String
var _entities: Array = []          # Array[SketchEntity]
var _constraints: Array = []       # Array[SketchConstraint]


func _init(feature_id: String, entities: Array, constraints: Array = []) -> void:
	name = "Add Entities"
	_feature_id = feature_id
	_entities = entities
	_constraints = constraints


func do_() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for e: SketchEntity in _entities:
		sk.add(e)
	for c: SketchConstraint in _constraints:
		sk.constraints.append(c)


func undo() -> void:
	var sk := doc.sketch_feature(_feature_id).sketch
	for c: SketchConstraint in _constraints:
		sk.constraints.erase(c)
	for i in range(_entities.size() - 1, -1, -1):
		sk.remove((_entities[i] as SketchEntity).id)


func is_noop() -> bool:
	return _entities.is_empty() and _constraints.is_empty()
