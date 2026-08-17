class_name SketchTool
extends RefCounted
## Base class for sketch-mode tools (pattern ported from echo_vector).
## Pointer events arrive PRE-MAPPED into sketch coordinates (mm, Y-up) plus
## the raw screen position for chrome; return true to consume. Tools push
## Commands — they never mutate the model directly.

## Identity.
var id: String = ""
var title: String = ""
var shortcut: Key = KEY_NONE

## Injected by ToolManager.
var app: AppRoot = null

## Entity under the cursor that a click would pick right now, "" for none.
## Lives on the base class so EVERY picking tool pre-highlights the same way —
## Fusion highlights under Dimension, Trim and the rest, not just under Select,
## and a tool that picks without showing what it would pick makes the user
## click to find out. Tools that pick call `update_hover` from pointer_move;
## tools that do not (pure placement) simply never set it.
var hover_id: String = ""


## Recompute `hover_id` from the cursor position. Returns true when it changed,
## which is the caller's cue to redraw the overlay.
##
## Uses the SAME hit test the click paths use, so the highlight can never
## promise something a click would not deliver.
func update_hover(world: Vector2, tol_px := 6.0) -> bool:
	var sk := sketch()
	var found := ""
	if sk != null and app != null and app.sketch_view != null:
		found = SketchGeometry.entity_at(sk, world, tol_px / view().zoom())
	if found == hover_id:
		return false
	hover_id = found
	return true


func clear_hover() -> bool:
	if hover_id == "":
		return false
	hover_id = ""
	return true


func activate() -> void:
	pass


func deactivate() -> void:
	pass


func pointer_down(_world: Vector2, _screen: Vector2, _event: InputEventMouseButton) -> bool:
	return false


func pointer_move(_world: Vector2, _screen: Vector2, _event: InputEventMouseMotion) -> bool:
	return false


func pointer_up(_world: Vector2, _screen: Vector2, _event: InputEventMouseButton) -> bool:
	return false


## Esc pressed. Return true if the tool consumed it (cancelled a gesture).
func cancel() -> bool:
	return false


## Raw key event while the tool is active (numeric type-in fields). Return
## true to consume BEFORE tool shortcuts run.
func key_input(_e: InputEventKey) -> bool:
	return false


## Enter pressed (finish a chain, commit a value).
func commit() -> bool:
	return false


## Once per frame while this tool is active (AppRoot drives it — tools are
## RefCounted and get no _process of their own). Use it to apply work that
## must happen at most once per displayed frame: pointer motion arrives faster
## than frames, so a gesture that acts on every event burns CPU producing
## states nobody ever sees.
func tick() -> void:
	pass


## Screen-space chrome (previews, glyphs). Called from the overlay's _draw.
func draw_overlay(_overlay: Control) -> void:
	pass


func sketch() -> Sketch:
	return app.active_sketch()


func view() -> SketchView:
	return app.sketch_view
