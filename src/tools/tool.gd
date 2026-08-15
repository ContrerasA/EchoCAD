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


## Enter pressed (finish a chain, commit a value).
func commit() -> bool:
	return false


## Screen-space chrome (previews, glyphs). Called from the overlay's _draw.
func draw_overlay(_overlay: Control) -> void:
	pass


func sketch() -> Sketch:
	return app.active_sketch()


func view() -> SketchView:
	return app.sketch_view
