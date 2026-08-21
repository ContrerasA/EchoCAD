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
## Hidden tools get no ribbon button / shortcut slot: they are armed by
## other chrome (the constraint buttons arm ConstraintTool).
var hidden := false

## --- arm-then-pick (CHANGES #6) ---------------------------------------------
## HARD REQUIREMENT for every tool that operates on existing geometry: the
## user may pick the operands AFTER arming the tool, not only before. A tool
## whose operands are missing on activate enters the GATHER stage: clicks
## toggle entities into app.selection (hover pre-highlighted), Enter or a
## right-click confirms and the tool carries on exactly as if the selection
## had been made first. Esc clears the gathered picks, then leaves the tool.
var gathering := false
var _gather_hint := ""
const GATHER_HIT_PX := 6.0


## Enter the gather stage. `hint` names what to pick; the confirm keys are
## appended so every tool says it the same way.
func gather_begin(hint: String) -> void:
	gathering = true
	_gather_hint = hint
	if app != null:
		app.set_status_hint(hint + " — Enter or right-click when done")


## Pointer-down while gathering. Left-click toggles the entity under the
## cursor (nothing under it: no change); right-click confirms. Returns true
## when the stage has been CONFIRMED (the caller then proceeds).
func gather_pointer_down(world: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index == MOUSE_BUTTON_RIGHT:
		return gather_confirm()
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	var hit := SketchGeometry.entity_at(sk, world, GATHER_HIT_PX / view().zoom())
	if hit == "" or not gather_accepts(hit):
		return false
	var sel := app.selection.duplicate()
	if sel.has(hit):
		sel.erase(hit)
	else:
		sel.append(hit)
	app.set_selection(sel)
	return false


## Override to refuse entity kinds the tool cannot use (e.g. bare points
## for a pattern). Default: anything.
func gather_accepts(_id: String) -> bool:
	return true


## Confirm the gather stage if something was picked. Returns true when the
## tool may proceed; an empty pick just restates the hint.
func gather_confirm() -> bool:
	if app == null or app.selection.is_empty():
		if app != null:
			app.set_status_hint(_gather_hint + " — nothing picked yet")
		return false
	gathering = false
	return true


## Esc while gathering: clear the picks (true = consumed), or report false
## when there was nothing to clear so the app can leave the tool.
func gather_cancel() -> bool:
	if not gathering:
		return false
	if not app.selection.is_empty():
		app.set_selection([])
		app.set_status_hint(_gather_hint)
		return true
	gathering = false
	return false

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


## Stamp the app's construction mode onto freshly DRAWN curves (M21 QA:
## X while drawing). Drawing tools pass their new entities through this
## right before pushing; copy/derive tools (offset, mirror, trim, project)
## do NOT — they preserve their source's flags. Points are left alone and
## already-construction scaffolding (a center-rect diagonal) stays as-is.
func stamp_construction(ents: Array) -> Array:
	if app != null and app.construction_mode:
		for e in ents:
			var se := e as SketchEntity
			if se != null and se.kind() != "point":
				se.construction = true
	return ents


## --- construction-aware preview strokes (M21 QA) --------------------------
## While construction mode is on, the GHOST a drawing tool shows must read
## as construction too: these helpers draw the geometry preview dashed and
## violet-tinted so what you see is what will commit. Guides and markers
## (radius lines, pick dots) keep the tools' normal chrome.

func _preview_is_construction() -> bool:
	return app != null and app.construction_mode


## Ghost/marker ink at `alpha`: white on the dark theme, dark on the light
## theme. Tools used to hardcode white, which vanished on the light canvas —
## the ghost was invisible until the geometry committed (QA §M26.5).
static func ghost(alpha: float) -> Color:
	var ink := ThemeService.col("dim_line")
	return Color(ink.r, ink.g, ink.b, alpha)


static func _construction_tint(c: Color) -> Color:
	var t := RenderBridge.color_construction()
	return Color(t.r, t.g, t.b, c.a)


func preview_line(overlay: Control, a: Vector2, b: Vector2, c: Color,
		w := 1.0) -> void:
	if _preview_is_construction():
		overlay.draw_dashed_line(a, b, _construction_tint(c), w, 8.0)
	else:
		overlay.draw_line(a, b, c, w)


func preview_arc(overlay: Control, center: Vector2, radius: float,
		from: float, to: float, segs: int, c: Color, w := 1.0) -> void:
	if not _preview_is_construction() or radius < 1.0:
		overlay.draw_arc(center, radius, from, to, segs, c, w)
		return
	var tint := _construction_tint(c)
	var dash_ang := 8.0 / radius
	var gap_ang := 6.0 / radius
	var dir := signf(to - from)
	if dir == 0.0:
		return
	var a := from
	var guard := int(ceil(absf(to - from) * radius / 8.0)) + 4
	while dir * (to - a) > 0.0 and guard > 0:
		guard -= 1
		var a2 := a + dir * dash_ang
		if dir * (to - a2) < 0.0:
			a2 = to
		overlay.draw_arc(center, radius, a, a2, 6, tint, w)
		a = a2 + dir * gap_ang


func preview_rect(overlay: Control, r: Rect2, c: Color, w := 1.0) -> void:
	if not _preview_is_construction():
		overlay.draw_rect(r, c, false, w)
		return
	var p00 := r.position
	var p10 := r.position + Vector2(r.size.x, 0)
	var p11 := r.position + r.size
	var p01 := r.position + Vector2(0, r.size.y)
	for pair: Array in [[p00, p10], [p10, p11], [p11, p01], [p01, p00]]:
		preview_line(overlay, pair[0], pair[1], c, w)


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
