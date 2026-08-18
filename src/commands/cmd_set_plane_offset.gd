class_name CmdSetPlaneOffset
extends Command
## Edit a construction plane's offset (M22). Parametric: every sketch on the
## plane (and everything built from those sketches) follows on the rebuild
## the stack-change signal triggers.

var _fid: String
var _to := 0.0
var _from := 0.0


func _init(fid: String, to: float) -> void:
	name = "Edit Plane Offset"
	_fid = fid
	_to = to


func do_() -> void:
	var pf := doc.plane_feature(_fid)
	if pf == null:
		push_error("[CmdSetPlaneOffset] no plane feature %s" % _fid)
		return
	_from = pf.offset
	pf.offset = _to


func undo() -> void:
	var pf := doc.plane_feature(_fid)
	if pf != null:
		pf.offset = _from


func is_noop() -> bool:
	return is_equal_approx(_from, _to)
