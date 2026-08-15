class_name Command
extends RefCounted
## Base class for every document mutation. EVERY change to the document goes
## through a Command so undo/redo is universal and never retrofitted.
## (Pattern ported from echo_vector.)
##
## A command captures enough state to both apply and reverse itself. `do_()`
## runs on first execution and on redo; `undo()` reverses it. Both must keep
## the model AND the render bridge (once one exists) in sync.

var name: String = "Command"

# Injected by the CommandStack before do_/undo so commands can reach the
# model and renderer without each carrying its own references. `bridge` stays
# null until the render layer lands (M2).
var doc: CadDocument
var bridge: RefCounted = null


func do_() -> void:
	push_error("[Command] do_() not implemented for " + name)


func undo() -> void:
	push_error("[Command] undo() not implemented for " + name)


## Optional coalescing: absorb `next` into self (continuous drags). Return
## true if absorbed.
func merge_with(_next: Command) -> bool:
	return false


## True when before/after states are (approximately) identical — e.g. a drag
## that returned to its origin. The stack drops a merged command that became
## a no-op.
func is_noop() -> bool:
	return false
