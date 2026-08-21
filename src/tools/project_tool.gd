class_name ProjectTool
extends SketchTool
## Fusion's Project (M15): click geometry belonging to ANOTHER sketch — the
## dimmed reference geometry drawn behind the active one — to copy it into
## the active sketch as linked, source-following entities (see Projector).
## One click = one projection = one undo step.

## Reference entity under the cursor: {"feat": SketchFeature, "eid": String}.
var _target := {}


func _init() -> void:
	id = "project"
	title = "Project"


func activate() -> void:
	_target = {}
	if app != null:
		app.set_status_hint("Project: click dimmed geometry from another sketch")


func deactivate() -> void:
	_target = {}


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	var tol := 6.0 / view().zoom()
	var found := {}
	for rf in app.reference_features():
		var sf := rf as SketchFeature
		var eid := SketchGeometry.entity_at(sf.sketch, world, tol)
		# A reference sketch's origin sits exactly under the active one's —
		# projecting it would only mint a duplicate of a datum that exists.
		if eid != "" and not sf.sketch.is_origin(eid):
			found = {"feat": sf, "eid": eid}
			break
	if found.get("eid", "") == _target.get("eid", "") \
			and found.get("feat") == _target.get("feat"):
		return false
	_target = found
	return true


func pointer_down(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT or _target.is_empty():
		return false
	var src: SketchFeature = _target["feat"]
	var feat := app.doc.sketch_feature(app.active_sketch_id)
	var r := Projector.build(feat, src, String(_target["eid"]))
	if String(r["error"]) != "":
		app.set_status_hint("Cannot project: " + String(r["error"]))
		return true
	app.stack.push_no_merge(
		CmdAddEntities.new(app.active_sketch_id, r["entities"]))
	app.rebuild_snap_index()
	app.set_status_hint("Projected %d entities from %s"
		% [(r["entities"] as Array).size(), src.name])
	return true


func draw_overlay(_overlay: Control) -> void:
	if _target.is_empty():
		return
	var sf: SketchFeature = _target["feat"]
	var e := sf.sketch.entity(String(_target["eid"]))
	if e != null:
		# Same outline the selection highlight uses, drawn on the app overlay.
		app._draw_entity_outline(sf.sketch, e, AppRoot.COLOR_HOVER(), 3.0)
