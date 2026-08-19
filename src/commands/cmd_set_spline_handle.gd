class_name CmdSetSplineHandle
extends Command
## M28: set (or clear, `to = null`) the explicit OUT-tangent override of one
## spline fit point. Handle drags push one of these per frame inside the
## select tool's CmdMergeBatch, so the whole gesture is one undo step.

var _feature_id: String
var _entity_id: String
var _index: int
var _to: Variant          # Vector2 or null
var _from: Variant = null


func _init(feature_id: String, entity_id: String, index: int, to: Variant) -> void:
	name = "Edit Handle"
	_feature_id = feature_id
	_entity_id = entity_id
	_index = index
	_to = to


func _spline() -> SketchSpline:
	var f := doc.sketch_feature(_feature_id)
	if f == null:
		return null
	return f.sketch.entity(_entity_id) as SketchSpline


func do_() -> void:
	var sp := _spline()
	if sp == null or _index < 0 or _index >= sp.points.size():
		return
	while sp.handles.size() < sp.points.size():
		sp.handles.append(null)
	_from = sp.handles[_index]
	sp.handles[_index] = _to


func undo() -> void:
	var sp := _spline()
	if sp == null or _index < 0 or _index >= sp.handles.size():
		return
	sp.handles[_index] = _from


## Continuous drag: same handle keeps one command; the first `_from` stands.
func merge_with(next: Command) -> bool:
	var n := next as CmdSetSplineHandle
	if n == null or n._feature_id != _feature_id \
			or n._entity_id != _entity_id or n._index != _index:
		return false
	_to = n._to
	return true
