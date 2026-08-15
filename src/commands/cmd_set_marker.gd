class_name CmdSetMarker
extends Command
## Move the timeline rollback marker. Features at index >= marker are
## rolled back (hidden from the world and from downstream computation).

var _before := 0
var _after := 0
## Merge window: one drag merges into one step; seal at drag end.
var open := true


func _init(before: int, after: int) -> void:
	name = "Rollback"
	_before = before
	_after = after


func do_() -> void:
	doc.timeline_marker = clampi(_after, 0, doc.features.size())


func undo() -> void:
	doc.timeline_marker = clampi(_before, 0, doc.features.size())


func merge_with(next: Command) -> bool:
	if not open or not (next is CmdSetMarker):
		return false
	_after = (next as CmdSetMarker)._after
	return true


func is_noop() -> bool:
	return _before == _after
