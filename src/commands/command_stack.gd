class_name CommandStack
extends RefCounted
## Undo/redo via an explicit command stack — the single funnel for all
## document mutations. Custom (not Godot's UndoRedo) so the model stays
## engine-agnostic and commands carry their own merge/diff logic.
## (Ported from echo_vector.)

signal changed                # any push / undo / redo (UI should refresh)

var doc: CadDocument
var bridge: RefCounted = null

var _undo: Array[Command] = []
var _redo: Array[Command] = []
var _merge_enabled := true

# Save point: the command on top of the undo stack when the document was last
# saved (null = saved with empty history). Dirty whenever the current top
# differs — correct across undo/redo and "undo past save, then edit".
var _saved_top: Command = null


func _init(document: CadDocument, render_bridge: RefCounted = null) -> void:
	doc = document
	bridge = render_bridge


## Execute a command and record it. Clears the redo stack. If the previous
## command accepts a merge (continuous drag), the new one is folded in.
func push(cmd: Command) -> void:
	cmd.doc = doc
	cmd.bridge = bridge
	cmd.do_()
	_redo.clear()
	if _merge_enabled and not _undo.is_empty() and _undo.back().merge_with(cmd):
		if _undo.back().is_noop():
			_undo.pop_back()
	else:
		_undo.append(cmd)
	changed.emit()


## Push without attempting to merge (start a fresh undo step).
func push_no_merge(cmd: Command) -> void:
	var prev := _merge_enabled
	_merge_enabled = false
	push(cmd)
	_merge_enabled = prev


## Drop `cmd` from the top of the undo stack if it is there and does nothing —
## a drag that never moved anything must not leave a phantom undo step the
## user has to press Ctrl+Z through (QA §M19.8).
func drop_if_noop(cmd: Command) -> void:
	if cmd != null and not _undo.is_empty() and _undo.back() == cmd \
			and cmd.is_noop():
		_undo.pop_back()
		changed.emit()


## Most recent undoable command (or null). Never mutate through this.
func peek() -> Command:
	return _undo.back() if not _undo.is_empty() else null


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> void:
	if _undo.is_empty():
		return
	var cmd: Command = _undo.pop_back()
	cmd.undo()
	_redo.append(cmd)
	changed.emit()


func redo() -> void:
	if _redo.is_empty():
		return
	var cmd: Command = _redo.pop_back()
	cmd.do_()
	_undo.append(cmd)
	changed.emit()


func clear() -> void:
	_undo.clear()
	_redo.clear()
	_saved_top = null
	changed.emit()


# --- save point (dirty tracking) ---------------------------------------------

func mark_saved() -> void:
	_saved_top = _undo.back() if not _undo.is_empty() else null
	changed.emit()


func is_dirty() -> bool:
	var top: Command = _undo.back() if not _undo.is_empty() else null
	return top != _saved_top
