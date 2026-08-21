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
## Shared with model mode so the background does not shift when switching.
## Theme-sourced since M26 — must be looked up per draw, not cached.
static func bg_color() -> Color:
	return ThemeService.col("bg3d")
## Opacity of the veil drawn over the 3D viewport while sketching. High enough
## that the sketch reads as the foreground, low enough that solids behind it
## stay legible so you can place geometry against the part you are drawing on.
const MODEL_VEIL_ALPHA := 0.82
## Grid colours for the 2D canvas. Deliberately NOT shared with the 3D grid.
##
## They were aliased to `CadWorld`'s for a while, on the reasoning that the two
## surfaces should not drift apart — but they are not solving the same problem.
## The 3D grid is a shaded quad seen at a raking angle, where its own fade and
## coverage maths do the work and low alphas suffice. This one is drawn flat and
## face-on, one screen pixel wide, over the model veil, with nothing attenuating
## it: at the 3D grid's 0.085 the minor lines are invisible here, which is
## exactly how "only the majors are drawn" looked in the sketch view. The STEP
## ladder stays shared (that is a units question, the same in both places); the
## colours answer a rendering question and each surface answers it for itself.
## (Theme-sourced since M26: sk_grid_minor / sk_grid_major.)
## Closed regions get a translucent face under the geometry, Fusion-style —
## the "this sketch closes, it can be extruded" affordance (QA §M18.1).

var bridge: RenderBridge = null
## M30: supplies reference images for the ACTIVE sketch plane —
## [{tex, center, width_mm, height_mm, rotation, opacity}] — drawn under
## the grid so geometry and chrome always win.
var canvases_provider: Callable = Callable()
## The unit whose steps the grid follows (document display unit).
var grid_unit: UnitConverter.Unit = UnitConverter.Unit.IN
## Tool input hook: Callable(world: Vector2, screen: Vector2, event) -> bool.
## LMB buttons and non-pan motion are offered here first (AppRoot routes to
## the ToolManager); camera input (wheel, MMB) never reaches it.
var tool_input: Callable = Callable()

var _zoom := 4.0
var _pan := Vector2.ZERO
## Off-axis sketching (M14 QA): while the camera is orbited off the plane the
## canvas is hidden, but this class stays the ONE world<->screen mapping —
## it delegates to the 3D camera, so every tool, overlay and hit test keeps
## working and geometry lands on the ORIGINAL sketch plane (Fusion's
## workflow). Set via `set_projection_3d` / `clear_projection_3d`.
var _project_3d := false
var _cam_3d: Camera3D = null
var _plane_xf := Transform3D.IDENTITY
var _raster: TextureRect = null
var _texture: ImageTexture = null
var _sketch: Sketch = null
## Other sketches on the same plane, drawn dimmed underneath the active one so
## you can place geometry relative to what the model already has.
var _references: Array = []
## Let the 3D model show through behind the sketch (see `_draw`). A plain
## opaque canvas is still available for tests and screenshots that want the
## sketch on its own.
var show_model_behind := true
var _dirty := false
## Cached closed-region triangles (mm, flat triples) for the fill in _draw;
## rebuilt lazily when the model changes, only transformed per redraw.
var _region_tris := PackedVector2Array()
var _regions_dirty := true


## Key hook: Callable(event: InputEventKey) -> bool. Focused keys (Tab,
## Enter, digits) route here BEFORE viewport focus traversal can eat them.
var key_handler: Callable = Callable()

## Shift+MMB hook: Callable(screen: Vector2). Fusion's in-sketch orbit — the
## owner swaps this canvas out for the 3D view and starts an orbit gesture.
var orbit_request: Callable = Callable()


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	_raster = TextureRect.new()
	_raster.name = "Raster"
	_raster.set_anchors_preset(Control.PRESET_FULL_RECT)
	_raster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_raster.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_raster)
	resized.connect(_on_view_changed)


## --- camera ------------------------------------------------------------------

## Route the mapping through the 3D camera: sketch (u,v) projects along the
## plane transform and the camera; clicks ray-cast back onto the plane.
## Takes the FULL plane transform — offset/custom planes (M22) carry an
## origin as well as a basis.
func set_projection_3d(cam: Camera3D, plane_xf: Transform3D) -> void:
	_project_3d = true
	_cam_3d = cam
	_plane_xf = plane_xf


func clear_projection_3d() -> void:
	_project_3d = false
	_cam_3d = null


func is_projection_3d() -> bool:
	return _project_3d


func zoom() -> float:
	if _project_3d and _cam_3d != null:
		# Effective px-per-mm at the pan point, so snap/hit tolerances stay
		# meaningful off-axis. Measured, not derived: correct under both
		# projections without caring which one the camera is in.
		var s := world_to_screen(_pan + Vector2(1, 0)) \
			.distance_to(world_to_screen(_pan))
		return maxf(s, 0.01)
	return _zoom


func pan() -> Vector2:
	return _pan


func set_view(p_pan: Vector2, p_zoom: float) -> void:
	_pan = p_pan
	_zoom = clampf(p_zoom, ZOOM_MIN, ZOOM_MAX)
	_on_view_changed()


func world_to_screen(p: Vector2) -> Vector2:
	if _project_3d and _cam_3d != null:
		return _cam_3d.unproject_position(
			_plane_xf * Vector3(p.x, p.y, 0.0))
	var c := size * 0.5
	var d := p - _pan
	return c + Vector2(d.x, -d.y) * _zoom


func screen_to_world(s: Vector2) -> Vector2:
	if _project_3d and _cam_3d != null:
		var o := _cam_3d.project_ray_origin(s)
		var dir := _cam_3d.project_ray_normal(s)
		var n := _plane_xf.basis.z
		var denom := dir.dot(n)
		if absf(denom) < 1e-9:
			return _pan   # grazing ray: no meaningful plane point
		var hit := o + dir * ((_plane_xf.origin - o).dot(n) / denom)
		var local := _plane_xf.affine_inverse() * hit
		return Vector2(local.x, local.y)
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
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and key_handler.is_valid() and key_handler.call(k):
			accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE \
				and mb.shift_pressed and orbit_request.is_valid():
			# Shift+MMB leaves the locked 2D view: hand the gesture to the 3D
			# camera. The owner hides this canvas, so the rest of the drag's
			# events route to the viewport underneath.
			orbit_request.call(mb.position)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_at(1.1, mb.position)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_at(1.0 / 1.1, mb.position)
			accept_event()
		elif (mb.button_index == MOUSE_BUTTON_LEFT
				or mb.button_index == MOUSE_BUTTON_RIGHT) and tool_input.is_valid():
			# Right-click reaches tools too: it confirms a gather stage
			# (CHANGES #6). Tools that do not use it return false.
			# Clicking the canvas takes keyboard focus back. Focus was grabbed
			# only once, when the sketch opened, so anything that moved it
			# afterwards — clicking a toolbar button, for instance — left the
			# canvas deaf: you could select a dimension label and type at it
			# with nothing whatsoever happening, because the keys were going
			# somewhere else entirely.
			if mb.pressed and not has_focus():
				grab_focus()
			if tool_input.call(screen_to_world(mb.position), mb.position, mb):
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan += Vector2(-mm.relative.x, mm.relative.y) / _zoom
			_on_view_changed()
			accept_event()
		elif tool_input.is_valid():
			if tool_input.call(screen_to_world(mm.position), mm.position, mm):
				accept_event()


## --- rendering ---------------------------------------------------------------

## Point the view at a sketch and (re)build the raster. `references` are other
## sketches to draw dimmed underneath it as context.
func show_sketch(sketch: Sketch, references: Array = []) -> void:
	_sketch = sketch
	_references = references
	mark_dirty()


## Model changed: rebuild canvas + re-render.
func mark_dirty() -> void:
	_dirty = true
	_regions_dirty = true
	queue_redraw()
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
		bridge.full_sync(_sketch, _zoom, _references)
		_dirty = false
	if _texture == null:
		_texture = ImageTexture.new()
	if bridge.render(view_rect(), w, h, _texture):
		_raster.texture = _texture


## --- grid --------------------------------------------------------------------

## Minor grid spacing in mm: 1/10/100... of the grid unit, times 1, 2, or 5,
## chosen so lines land ~GRID_TARGET_PX apart on screen.
func grid_step_mm() -> float:
	return step_for(grid_unit, GRID_TARGET_PX / _zoom)


## The ladder rung at or just above `target_mm`, the rung BELOW it, and how far
## between them the target sits — everything needed to cross-fade two levels.
##
## -> {"step": float, "finer": float, "ratio": float, "blend": float}
##
## `blend` runs 0 at the moment this rung is chosen to 1 as the target reaches
## the next rung down. A grid that only ever asks for `step` snaps between rungs
## and every intermediate line pops in on one frame; drawing `finer` at `blend`
## opacity alongside it is what makes the transition continuous, Blender-style.
static func step_levels(unit: UnitConverter.Unit, target_mm: float) -> Dictionary:
	var step := step_for(unit, target_mm)
	# The fine level MUST divide the coarse one EXACTLY, or the two families
	# interleave instead of overlaying and the grid draws visible close pairs.
	# Walking the 1/2/5 ladder does not give that: the 5 -> 2 rung has a ratio
	# of 2.5, so a 127 mm coarse level against a 50.8 mm fine level puts lines
	# at 127/254/381 and 50.8/101.6/152.4 — 101.6 and 127 sit 25.4 mm apart,
	# which is exactly the doubling seen on screen. Subdividing the coarse level
	# by a whole number instead keeps every fine line either ON a coarse line or
	# evenly spaced between them, whichever rung is active.
	var ratio := 5.0 if _is_five_rung(unit, step) else 2.0
	var finer := step / ratio
	# Where the target sits within the range this RUNG is active for, on a LOG
	# scale (spacing is multiplicative, so a linear position fades unevenly).
	#
	# The interval is the gap to the rung BELOW — which is 2 or 2.5 — and NOT
	# the subdivision ratio above, which is 2 or 5. Conflating the two is a real
	# bug: measuring a 2.5-wide interval against a base of 5 leaves the fade
	# only ~56% done when the rung hands over, so the remaining 44% still pops.
	var span := step / maxf(step_below(unit, step), 1e-9)
	var blend := 0.0
	if target_mm > 0.0 and span > 1.0001:
		blend = clampf(log(step / target_mm) / log(span), 0.0, 1.0)
	return {"step": step, "finer": finer, "ratio": ratio, "blend": blend}


## Is `step_mm` the "5" rung of its decade? That one subdivides by 5 (5 -> 1),
## every other rung by 2 (1 -> 0.5, 2 -> 1). Both land on real ladder values, so
## the fading level is always a spacing a user would recognise.
static func _is_five_rung(unit: UnitConverter.Unit, step_mm: float) -> bool:
	var unit_mm := UnitConverter.to_mm(1.0, unit)
	if unit_mm <= 0.0 or step_mm <= 0.0:
		return false
	var units := step_mm / unit_mm
	var decade := pow(10.0, floorf(log(units) / log(10.0) + 1e-9))
	return units / decade > 4.99


## The ladder rung immediately BELOW `step_mm` (1 -> 5 -> 2 -> 1 of the decade
## under it). Exact by construction rather than by dividing, so repeated calls
## cannot drift off the ladder.
static func step_below(unit: UnitConverter.Unit, step_mm: float) -> float:
	var unit_mm := UnitConverter.to_mm(1.0, unit)
	if unit_mm <= 0.0 or step_mm <= 0.0:
		return step_mm
	var units := step_mm / unit_mm
	var decade := pow(10.0, floorf(log(units) / log(10.0) + 1e-9))
	var mult := units / decade
	if mult > 4.99:                       # 5 -> 2
		return decade * 2.0 * unit_mm
	if mult > 1.99:                       # 2 -> 1
		return decade * unit_mm
	return decade * 0.5 * unit_mm         # 1 -> 5 of the decade below


## The 1/2/5-times-a-power-of-ten step at or just above `target_mm`, in the
## given unit's terms. Shared with the 3D ground grid so both surfaces step
## through the same ladder of spacings.
static func step_for(unit: UnitConverter.Unit, target_mm: float) -> float:
	var unit_mm := UnitConverter.to_mm(1.0, unit)
	if target_mm <= 0.0 or unit_mm <= 0.0:
		return unit_mm
	# Work in UNITS, not mm. The decade has to be found below the target and
	# then stepped up through the 1/2/5 ladder; the previous version scaled a
	# running value up until it EXCEEDED the target and only then consulted the
	# ladder, so `mult = 1.0` always won, 2 and 5 were unreachable dead code,
	# and the result overshot by as much as 8.5x. With an inch unit and a 48 mm
	# target that produced a 254 mm (10 inch) step — minor lines spaced wider
	# than the whole viewport, so only the majors were ever visible near the
	# origin and the grid looked like it was dropping lines.
	var target_units := target_mm / unit_mm
	# Largest power of ten at or below the target, so the ladder starts under it.
	var decade := pow(10.0, floorf(log(target_units) / log(10.0)))
	for mult in [1.0, 2.0, 5.0, 10.0]:
		if decade * mult >= target_units:
			return decade * mult * unit_mm
	return decade * 10.0 * unit_mm


func _rebuild_region_tris() -> void:
	_region_tris.clear()
	_regions_dirty = false
	if _sketch == null:
		return
	for prof: Dictionary in ProfileFinder.profiles(_sketch):
		var tri := ProfileFinder.triangulate_with_holes(
			prof["polygon"] as PackedVector2Array, prof.get("holes", []) as Array)
		var pts: PackedVector2Array = tri["points"]
		for i: int in (tri["indices"] as PackedInt32Array):
			_region_tris.append(pts[i])


func _draw() -> void:
	# A VEIL, not a solid fill. The 3D viewport sits directly behind this
	# canvas, so painting COLOR_BG opaquely hid every solid in the model the
	# moment a sketch was opened — you could not see the part you were drawing
	# on. Fusion keeps the model visible and knocked back behind the sketch;
	# this is the same idea, and because the veil colour IS the 3D background
	# an empty model still looks exactly as it did before.
	var bg := bg_color()
	var grid_minor := ThemeService.col("sk_grid_minor")
	var grid_major := ThemeService.col("sk_grid_major")
	if not show_model_behind:
		draw_rect(Rect2(Vector2.ZERO, size), bg)
	else:
		draw_rect(Rect2(Vector2.ZERO, size),
			Color(bg.r, bg.g, bg.b, MODEL_VEIL_ALPHA))
	# Reference images (M30) under everything else on the canvas.
	if canvases_provider.is_valid():
		for c: Dictionary in canvases_provider.call():
			var tex: Texture2D = c["tex"]
			if tex == null:
				continue
			var scr := world_to_screen(c["center"])
			var wpx: float = float(c["width_mm"]) * _zoom
			var hpx: float = float(c["height_mm"]) * _zoom
			# Screen space is Y-down: the plane rotation negates.
			draw_set_transform(scr, -float(c["rotation"]), Vector2.ONE)
			draw_texture_rect(tex, Rect2(-wpx * 0.5, -hpx * 0.5, wpx, hpx),
				false, Color(1, 1, 1, float(c["opacity"])))
			draw_set_transform_matrix(Transform2D.IDENTITY)
	# TWO LEVELS, cross-faded, exactly as the 3D grid does it — see
	# `step_levels`. The spacing snaps between rungs of the 1/2/5 ladder, so
	# drawing only the chosen rung makes every intermediate line appear or
	# vanish on a single frame as you zoom. Drawing the next FINER rung
	# underneath at `blend` opacity turns that pop into a fade: the
	# subdivisions arrive gradually and are at full strength precisely when the
	# ladder clicks over to them.
	var levels := step_levels(grid_unit, GRID_TARGET_PX / _zoom)
	var step: float = levels["step"]
	var blend: float = levels["blend"]
	var major_every := 5
	var view := view_rect()
	# The fading level first, so the settled lines draw over it.
	# Skipped once the fine level would be denser than roughly one line per two
	# pixels: past that it is a grey wash rather than a grid, and it costs a
	# draw call per line to say so.
	if blend > 0.002 and float(levels["finer"]) * _zoom >= 2.0:
		var fine: float = levels["finer"]
		var fc := Color(grid_minor.r, grid_minor.g,
			grid_minor.b, grid_minor.a * blend)
		var fx := floorf(view.position.x / fine) * fine
		while fx <= view.end.x:
			var sfx := world_to_screen(Vector2(fx, 0)).x
			draw_line(Vector2(sfx, 0), Vector2(sfx, size.y), fc, 1.0)
			fx += fine
		var fy := floorf(view.position.y / fine) * fine
		while fy <= view.end.y:
			var sfy := world_to_screen(Vector2(0, fy)).y
			draw_line(Vector2(0, sfy), Vector2(size.x, sfy), fc, 1.0)
			fy += fine
	var x0 := floorf(view.position.x / step) * step
	var y0 := floorf(view.position.y / step) * step
	var x := x0
	while x <= view.end.x:
		var sx := world_to_screen(Vector2(x, 0)).x
		var major := absf(fposmod(x / step, float(major_every))) < 0.01
		draw_line(Vector2(sx, 0), Vector2(sx, size.y),
			grid_major if major else grid_minor, 1.0)
		x += step
	var y := y0
	while y <= view.end.y:
		var sy := world_to_screen(Vector2(0, y)).y
		var major := absf(fposmod(y / step, float(major_every))) < 0.01
		draw_line(Vector2(0, sy), Vector2(size.x, sy),
			grid_major if major else grid_minor, 1.0)
		y += step
	# Closed-region fills over the grid, under the raster's geometry lines.
	if _regions_dirty:
		_rebuild_region_tris()
	var ti := 0
	while ti + 2 < _region_tris.size():
		var ta := world_to_screen(_region_tris[ti])
		var tb := world_to_screen(_region_tris[ti + 1])
		var tc := world_to_screen(_region_tris[ti + 2])
		# Sliver triangles (profiles through patterned splines produce some)
		# collapse to zero screen area and fail Godot's re-triangulation with
		# an "Invalid polygon data" error per frame; they paint nothing anyway.
		if absf((tb - ta).cross(tc - ta)) > 0.05:
			draw_colored_polygon(PackedVector2Array([ta, tb, tc]),
				ThemeService.col("region_fill"))
		ti += 3
	# Origin axes on top of the grid.
	var o := world_to_screen(Vector2.ZERO)
	if o.y >= 0 and o.y <= size.y:
		draw_line(Vector2(0, o.y), Vector2(size.x, o.y), ThemeService.col("axis_x"), 1.0)
	if o.x >= 0 and o.x <= size.x:
		draw_line(Vector2(o.x, 0), Vector2(o.x, size.y), ThemeService.col("axis_y"), 1.0)
