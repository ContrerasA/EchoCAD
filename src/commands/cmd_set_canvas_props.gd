class_name CmdSetCanvasProps
extends Command
## M30: edit a canvas feature's placement/appearance. `props` may hold any
## of center / width_mm / rotation / opacity / locked; unmentioned fields
## keep their value. Merges with a previous edit of the same canvas so
## slider-style gestures stay one undo step.

var _feature_id: String
var _props: Dictionary
var _before := {}
var _captured := false


func _init(feature_id: String, props: Dictionary) -> void:
	name = "Edit Canvas"
	_feature_id = feature_id
	_props = props.duplicate()


func _canvas() -> CanvasFeature:
	return doc.feature_by_id(_feature_id) as CanvasFeature


const FIELDS := ["center", "width_mm", "rotation", "opacity", "locked"]


func do_() -> void:
	var f := _canvas()
	if f == null:
		return
	if not _captured:
		for k in FIELDS:
			_before[k] = f.get(k)
		_captured = true
	for k in FIELDS:
		if _props.has(k):
			f.set(k, _props[k])


func undo() -> void:
	var f := _canvas()
	if f == null:
		return
	for k in FIELDS:
		f.set(k, _before[k])


func merge_with(next: Command) -> bool:
	var n := next as CmdSetCanvasProps
	if n == null or n._feature_id != _feature_id:
		return false
	for k in n._props:
		_props[k] = n._props[k]
	return true
