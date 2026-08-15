class_name CenterRectTool
extends RectTool
## Center rectangle: first click is the CENTER, second the corner. Emits the
## same 4-point/4-line/2H/2V geometry plus a construction center point tied
## by symmetry-in-position (center point placed exactly; symmetry constraint
## arrives with the constraint milestone). W/H fields measure full size.


func _init() -> void:
	super._init()
	id = "center_rect"
	title = "Center Rect"
	shortcut = KEY_NONE


## Second corner honoring typed FULL W/H around the center.
func _resolve_second() -> Vector2:
	var second := _preview
	var unit := app.doc.display_unit
	var w := _fields.value_mm(0, unit)
	var h := _fields.value_mm(1, unit)
	if not is_nan(w):
		second.x = _anchor.x + absf(w) * 0.5 \
			* (1.0 if _preview.x >= _anchor.x else -1.0)
	if not is_nan(h):
		second.y = _anchor.y + absf(h) * 0.5 \
			* (1.0 if _preview.y >= _anchor.y else -1.0)
	return second


func _commit_rect(second: Vector2) -> void:
	# Mirror the corner about the center to get the true anchor corner, then
	# reuse the base commit.
	var center := _anchor
	_anchor = center * 2.0 - second
	super._commit_rect(second)
	_anchor = center


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _armed:
		var second := _resolve_second()
		var opposite := _anchor * 2.0 - second
		var a := v.world_to_screen(opposite)
		var b := v.world_to_screen(second)
		overlay.draw_rect(Rect2(a, b - a).abs(), Color(1, 1, 1, 0.9), false, 1.0)
		var c := v.world_to_screen(_anchor)
		overlay.draw_line(c - Vector2(4, 0), c + Vector2(4, 0), Color(1, 1, 1, 0.6))
		overlay.draw_line(c - Vector2(0, 4), c + Vector2(0, 4), Color(1, 1, 1, 0.6))
		_fields.draw(overlay, v.world_to_screen(_preview), app.doc.display_unit,
			[absf(second.x - _anchor.x) * 2.0, absf(second.y - _anchor.y) * 2.0])
	else:
		overlay.draw_circle(v.world_to_screen(_preview), 2.0, Color(1, 1, 1, 0.7))
