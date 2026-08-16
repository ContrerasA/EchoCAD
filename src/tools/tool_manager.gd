class_name ToolManager
extends RefCounted
## Registers sketch tools, tracks the active one, and fans pointer/key
## events out to it. The single place UI input becomes tool calls — both the
## real SketchView input path and headless tests drive THIS API.

signal active_changed(id: String)
signal overlay_needs_redraw

var app: AppRoot = null

var _tools := {}                 # id -> SketchTool
var _order: Array[String] = []
var _active: SketchTool = null


func _init(p_app: AppRoot) -> void:
	app = p_app


func register(tool: SketchTool) -> void:
	tool.app = app
	_tools[tool.id] = tool
	_order.append(tool.id)


func tool_ids() -> Array[String]:
	return _order.duplicate()


func get_tool(id: String) -> SketchTool:
	return _tools.get(id)


func active_id() -> String:
	return _active.id if _active != null else ""


func set_active(id: String) -> void:
	if _active != null and _active.id == id:
		return
	if _active != null:
		_active.deactivate()
	_active = _tools.get(id)
	if _active != null:
		_active.activate()
	active_changed.emit(active_id())
	overlay_needs_redraw.emit()


func handle_pointer_down(world: Vector2, screen: Vector2,
		event: InputEventMouseButton) -> bool:
	if _active == null:
		return false
	var used := _active.pointer_down(world, screen, event)
	overlay_needs_redraw.emit()
	return used


func handle_pointer_move(world: Vector2, screen: Vector2,
		event: InputEventMouseMotion) -> bool:
	if _active == null:
		return false
	var used := _active.pointer_move(world, screen, event)
	overlay_needs_redraw.emit()
	return used


func handle_pointer_up(world: Vector2, screen: Vector2,
		event: InputEventMouseButton) -> bool:
	if _active == null:
		return false
	var used := _active.pointer_up(world, screen, event)
	overlay_needs_redraw.emit()
	return used


func handle_cancel() -> bool:
	if _active == null:
		return false
	var used := _active.cancel()
	overlay_needs_redraw.emit()
	return used


func handle_commit() -> bool:
	if _active == null:
		return false
	var used := _active.commit()
	overlay_needs_redraw.emit()
	return used


## Per-frame tick for the active tool — see `SketchTool.tick`.
func handle_tick() -> void:
	if _active != null:
		_active.tick()


func draw_overlay(overlay: Control) -> void:
	if _active != null:
		_active.draw_overlay(overlay)
