class_name CmdBatch
extends Command
## Run several commands as ONE undo step. Children run in order; undo runs in
## reverse. (Ported from echo_vector.)

var _cmds: Array = []   # Array[Command]


func _init(batch_name: String, cmds: Array) -> void:
	name = batch_name
	_cmds = cmds


func commands() -> Array:
	return _cmds


func do_() -> void:
	for c: Command in _cmds:
		c.doc = doc
		c.bridge = bridge
		c.do_()


func undo() -> void:
	for i in range(_cmds.size() - 1, -1, -1):
		(_cmds[i] as Command).undo()
