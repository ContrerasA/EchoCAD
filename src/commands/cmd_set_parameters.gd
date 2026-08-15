class_name CmdSetParameters
extends Command
## Replace the document's whole parameter list (before/after snapshot).

var _before: Array = []
var _after: Array = []


func _init(before: Array, after: Array) -> void:
	name = "Parameters"
	_before = before.duplicate()
	_after = after.duplicate()


func do_() -> void:
	var typed: Array[CadParameter] = []
	for p: CadParameter in _after:
		typed.append(p)
	doc.parameters = typed


func undo() -> void:
	var typed: Array[CadParameter] = []
	for p: CadParameter in _before:
		typed.append(p)
	doc.parameters = typed


func is_noop() -> bool:
	return _before == _after
