class_name CmdMergeBatch
extends CmdBatch
## A CmdBatch that keeps ABSORBING the commands of a continuing gesture — the
## key CAD undo primitive (ported from echo_vector). "Drag points + re-solve
## constraint followers" is one undo step even though each frame pushes a
## move command plus a solve command: each incoming command is offered to the
## existing children in order (first merge_with that takes it wins); a
## command no child takes is APPENDED (its do_() already ran via
## CommandStack.push, so ordering stays truthful; undo runs in reverse).
##
## seal() closes the merge window at gesture end — otherwise the NEXT
## unrelated push() would silently join this undo step.

var _open := true


## Stop absorbing (call at pointer-up / gesture end).
func seal() -> void:
	_open = false


func merge_with(next: Command) -> bool:
	if not _open:
		return false
	var incoming: Array = []
	if next is CmdMergeBatch:
		incoming = (next as CmdMergeBatch).commands()
	elif next is CmdBatch:
		return false          # one-shot batches stay their own undo step
	else:
		incoming = [next]
	for c: Command in incoming:
		var absorbed := false
		for mine: Command in _cmds:
			if mine.merge_with(c):
				absorbed = true
				break
		if not absorbed:
			_cmds.append(c)
	return true


func is_noop() -> bool:
	for c: Command in _cmds:
		if not c.is_noop():
			return false
	return true
