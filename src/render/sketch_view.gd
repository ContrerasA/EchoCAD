class_name SketchView
extends Control
## The 2D sketch canvas shown in sketch mode. Owns the camera state — `_zoom`
## (screen px per mm) and `_pan` (the sketch point at the panel center) — and
## the ONE world<->screen mapping every tool, overlay, and hit test uses.
## Sketch coords are Y-up; screen is Y-down.
##
## Draws (bottom to top): background, adaptive grid + axes in _draw, then the
## ThorVG raster in a child TextureRect. Editor chrome above lives in the
## separate Overlay control. Re-renders on view change or model change —
## never per frame.

signal view_changed

const ZOOM_MIN := 0.05      # px per mm  (~fit 8m)
const ZOOM_MAX := 400.0
const GRID_TARGET_PX := 48.0   # aim one minor line every ~this many px
const COLOR_BG := Color(0.13, 0.14, 0.16)
const COLOR_GRID_MINOR := Color(1, 1, 1, 0.05)
const COLOR_GRID_MAJOR := Color(1, 1, 1, 0.11)
const COLOR_AXIS_X := Color(0.85, 0.30, 0.30, 0.8)
const COLOR_AXIS_Y := Color(0.35, 0.80, 0.35, 0.8)

var bridge: RenderBridge = null
## The unit whose steps the grid follows (document display unit).
var grid_unit: UnitConverter.Unit = UnitConverter.Unit.IN

var _zoom := 4.0
var _pan := Vector2.ZERO
var _raster: TextureRect = null
var _texture: ImageTexture = null
var _sketch: Sketch = null
var _dirty := false


func _ready() -> void:
	clip_contents = true
	_raster = TextureRect.new()
	_raster.name = "Raster"
	_raster.set_anchors_preset(Control.PRESET_FULL_RECT)
	_raster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_raster.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_raster)
	resized.connect(_on_view_changed)


## --- camera ------------------------------------------------------------------

func zoom() -> float:
	return _zoom


func pan() -> Vector2:
	return _pan


func set_view(p_pan: Vector2, p_zoom: float) -> void:
	_pan = p_pan
	_zoom = clampf(p_zoom, ZOOM_MIN, ZOOM_MAX)
	_on_view_changed()


func world_to_screen(p: Vector2) -> Vector2:
	var c := size * 0.5
	var d := p - _pan
	return c + Vector2(d.x, -d.y) * _zoom


func screen_to_world(s: Vector2) -> Vector2:
	var c := size * 0.5
	var d := (s - c) / _zoom
	return _pan + Vector2(d.x, -d.y)


## Visible sketch rect (mm, Y-up).
func view_rect() -> Rect2:
	var half := size / (2.0 * _zoom)
	return Rect2(_pan - Vector2(half.x, half.y), size / _zoom)


## Cursor-anchored zoom: the world point under `at_screen` stays put.
func zoom_at(factor: float, at_screen: Vector2) -> void:
	var before := screen_to_world(at_screen)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var after := screen_to_world(at_screen)
	_pan += before - after
	_on_view_changed()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_at(1.1, mb.position)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_at(1.0 / 1.1, mb.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan += Vector2(-mm.relative.x, mm.relative.y) / _zoom
			_on_view_changed()
			accept_event()


## --- rendering ---------------------------------------------------------------

## Point the view at a sketch and (re)build the raster.
func show_sketch(sketch: Sketch) -> void:
	_sketch = sketch
	mark_dirty()


## Model changed: rebuild canvas + re-render.
func mark_dirty() -> void:
	_dirty = true
	_refresh()


func _on_view_changed() -> void:
	queue_redraw()
	# Zoom changes stroke width in mm, so the canvas needs a rebuild too.
	_dirty = true
	_refresh()
	view_changed.emit()


func _refresh() -> void:
	if _sketch == null or bridge == null or not bridge.available():
		return
	var w := int(size.x)
	var h := int(size.y)
	if w <= 0 or h <= 0:
		return
	if _dirty:
		bridge.full_sync(_sketch, _zoom)
		_dirty = false
	if _texture == null:
		_texture = ImageTexture.new()
	if bridge.render(view_rect(), w, h, _texture):
		_raster.texture = _texture


## --- grid --------------------------------------------------------------------

## Minor grid spacing in mm: 1/10/100... of the grid unit, times 1, 2, or 5,
## chosen so lines land ~GRID_TARGET_PX apart on screen.
func grid_step_mm() -> float:
	var unit_mm := UnitConverter.to_mm(1.0, grid_unit)
	var target_mm := GRID_TARGET_PX / _zoom
	var step := unit_mm
	while step < target_mm:
		step *= 10.0
	while step * 0.1 >= target_mm:
		step *= 0.1
	for mult in [1.0, 2.0, 5.0]:
		if step * mult >= target_mm:
			return step * mult
	return step * 10.0


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	var step := grid_step_mm()
	var major_every := 5
	var view := view_rect()
	var x0 := floorf(view.position.x / step) * step
	var y0 := floorf(view.position.y / step) * step
	var x := x0
	while x <= view.end.x:
		var sx := world_to_screen(Vector2(x, 0)).x
		var major := absf(fposmod(x / step, float(major_every))) < 0.01
		draw_line(Vector2(sx, 0), Vector2(sx, size.y),
			COLOR_GRID_MAJOR if major else COLOR_GRID_MINOR, 1.0)
		x += step
	var y := y0
	while y <= view.end.y:
		var sy := world_to_screen(Vector2(0, y)).y
		var major := absf(fposmod(y / step, float(major_every))) < 0.01
		draw_line(Vector2(0, sy), Vector2(size.x, sy),
			COLOR_GRID_MAJOR if major else COLOR_GRID_MINOR, 1.0)
		y += step
	# Origin axes on top of the grid.
	var o := world_to_screen(Vector2.ZERO)
	if o.y >= 0 and o.y <= size.y:
		draw_line(Vector2(0, o.y), Vector2(size.x, o.y), COLOR_AXIS_X, 1.0)
	if o.x >= 0 and o.x <= size.x:
		draw_line(Vector2(o.x, 0), Vector2(o.x, size.y), COLOR_AXIS_Y, 1.0)
