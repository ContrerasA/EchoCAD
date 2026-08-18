class_name RectTool
extends SketchTool
## 2-point rectangle. Fusion semantics: the rectangle is MADE OF sketch
## geometry — 4 shared corner points + 4 lines + 2 HORIZONTAL + 2 VERTICAL —
## committed as one undo step. W/H type-in fields (Tab to switch, Enter to
## commit with typed sizes).

var _armed := false              # first corner placed
var _anchor := Vector2.ZERO
var _preview := Vector2.ZERO
var _hover := false
var _fields := DimFields.new(["W", "H"])


func _init() -> void:
	id = "rect"
	title = "Rectangle"
	shortcut = KEY_R


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_armed = false
	_hover = false
	_fields.reset()


func cancel() -> bool:
	if _armed or _hover:
		_reset()
		return true
	return false


func commit() -> bool:
	if not _armed:
		return false
	_commit_rect(_resolve_second())
	return true


func key_input(e: InputEventKey) -> bool:
	if not _armed:
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return commit()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = _snap(world)
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pos := _snap(world)
	if not _armed:
		_armed = true
		_anchor = pos
		_fields.reset()
		return true
	_preview = pos
	_commit_rect(_resolve_second())
	return true


func _snap(world: Vector2) -> Vector2:
	var tol := SnapEngine.TOL_PX / view().zoom()
	var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
	return app.snap.snap_point(world, tol, grid)["pos"]


## Second corner honoring typed W/H (direction from the live preview).
func _resolve_second() -> Vector2:
	var second := _preview
	var unit := app.doc.display_unit
	var w := _fields.value_mm(0, unit)
	var h := _fields.value_mm(1, unit)
	if not is_nan(w):
		second.x = _anchor.x + absf(w) * (1.0 if _preview.x >= _anchor.x else -1.0)
	if not is_nan(h):
		second.y = _anchor.y + absf(h) * (1.0 if _preview.y >= _anchor.y else -1.0)
	return second


func _commit_rect(second: Vector2) -> void:
	if absf(second.x - _anchor.x) < 1e-6 or absf(second.y - _anchor.y) < 1e-6:
		_reset()
		return   # degenerate
	var sk := sketch()
	var p00 := SketchPoint.make(_anchor)
	var p10 := SketchPoint.make(Vector2(second.x, _anchor.y))
	var p11 := SketchPoint.make(second)
	var p01 := SketchPoint.make(Vector2(_anchor.x, second.y))
	for p: SketchPoint in [p00, p10, p11, p01]:
		p.id = sk.next_id()
	var bottom := SketchLine.make(p00.id, p10.id)
	var right := SketchLine.make(p10.id, p11.id)
	var top := SketchLine.make(p11.id, p01.id)
	var left := SketchLine.make(p01.id, p00.id)
	for l: SketchLine in [bottom, right, top, left]:
		l.id = sk.next_id()
	var cons: Array = [
		SketchConstraint.make(SketchConstraint.Type.HORIZONTAL, [bottom.id]),
		SketchConstraint.make(SketchConstraint.Type.HORIZONTAL, [top.id]),
		SketchConstraint.make(SketchConstraint.Type.VERTICAL, [right.id]),
		SketchConstraint.make(SketchConstraint.Type.VERTICAL, [left.id]),
	]
	var ents: Array = [p00, p10, p11, p01, bottom, right, top, left]
	var extra := _extras(sk, [p00, p10, p11, p01])
	ents.append_array(extra.get("entities", []))
	cons.append_array(extra.get("cons", []))
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id,
		stamp_construction(ents), cons))
	app.rebuild_snap_index()
	_reset()


## Variant hook: extra geometry committed WITH the rectangle (same undo
## step). `corners` are the four SketchPoints in p00/p10/p11/p01 order.
## The base 2-point rectangle adds nothing (Fusion's plain rect has no
## center either); CenterRect overrides this.
func _extras(_sk: Sketch, _corners: Array) -> Dictionary:
	return {}


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _armed:
		var second := _resolve_second()
		var a := v.world_to_screen(_anchor)
		var b := v.world_to_screen(second)
		var r := Rect2(a, b - a).abs()
		overlay.draw_rect(r, Color(1, 1, 1, 0.9), false, 1.0)
		_fields.draw(overlay, v.world_to_screen(_preview), app.doc.display_unit,
			[absf(second.x - _anchor.x), absf(second.y - _anchor.y)])
	else:
		var p := v.world_to_screen(_preview)
		overlay.draw_circle(p, 2.0, Color(1, 1, 1, 0.7))
