class_name ConstraintOverlay
extends RefCounted
## Draws constraint badges (glyph chips near their geometry) and provides
## their hit rects. Static + pure drawing; selection state and deletion live
## in AppRoot/SelectTool. Colors follow Fusion/echo_vector conventions:
## green satisfied, grey unsolved, amber redundant, red conflicting.

## Badge colors come from the theme (M36).
static func COLOR_OK() -> Color:
	return ThemeService.col("constraint_ok")
static func COLOR_UNSOLVED() -> Color:
	return ThemeService.col("constraint_unsolved")
static func COLOR_REDUNDANT() -> Color:
	return ThemeService.col("constraint_redundant")
static func COLOR_CONFLICT() -> Color:
	return ThemeService.col("constraint_conflict")
static func COLOR_SELECTED() -> Color:
	return ThemeService.col("constraint_selected")
const SATISFIED_TOL := 0.01     # mm

const GLYPH := {
	SketchConstraint.Type.COINCIDENT: "●",     # ●
	SketchConstraint.Type.HORIZONTAL: "H",
	SketchConstraint.Type.VERTICAL: "V",
	SketchConstraint.Type.PARALLEL: "∥",       # ∥
	SketchConstraint.Type.PERPENDICULAR: "⊥",  # ⊥
	SketchConstraint.Type.COLLINEAR: "≡",      # ≡
	SketchConstraint.Type.EQUAL: "=",
	SketchConstraint.Type.MIDPOINT: "◆",       # ◆
	SketchConstraint.Type.CONCENTRIC: "◎",     # ◎
	SketchConstraint.Type.TANGENT: "⌓",        # ⌓
	SketchConstraint.Type.POINT_ON: "○",       # ○
	SketchConstraint.Type.FIX: "⚓",            # ⚓
	SketchConstraint.Type.SYMMETRY: "↔",       # ↔
	SketchConstraint.Type.DISTANCE: "d",
	SketchConstraint.Type.DIST_X: "dx",
	SketchConstraint.Type.DIST_Y: "dy",
	SketchConstraint.Type.ANGLE: "∠",          # ∠
	SketchConstraint.Type.RADIUS: "R",
	SketchConstraint.Type.DIAMETER: "⌀",       # ⌀
	SketchConstraint.Type.LINE_DIST: "↦",      # ↦
	SketchConstraint.Type.POINT_LINE_DIST: "↤",
}


## Where one operand's badge sits, or null-ish (Vector2.INF) if it has none.
static func _operand_anchor(sk: Sketch, op: String) -> Vector2:
	var e := sk.entity(op)
	if e == null:
		return Vector2.INF
	match e.kind():
		"point":
			return (e as SketchPoint).pos
		"line":
			var m := SketchGeometry.line_midpoint(sk, e as SketchLine)
			return m["pos"] if m.get("ok", false) else Vector2.INF
		"circle", "arc":
			var cp := sk.point((e as SketchArc).center if e is SketchArc
				else (e as SketchCircle).center)
			return cp.pos if cp != null else Vector2.INF
	return Vector2.INF


## One anchor PER OPERAND — a Parallel between two lines gets a badge on each,
## as Fusion does. Averaging them into a single point (the old behaviour) put
## one badge floating in the space between the two lines, belonging visibly to
## neither, which is useless for seeing what is constrained to what.
static func anchors_of(sk: Sketch, c: SketchConstraint) -> Array:
	var out: Array = []
	for op in c.operands:
		var p := _operand_anchor(sk, op)
		if p != Vector2.INF:
			out.append(p)
	return out


## Representative world position of a constraint (mean of operand reps). Used
## where a SINGLE point is needed — dimension label anchoring — rather than for
## badge placement, which wants one per operand (`anchors_of`).
static func anchor_of(sk: Sketch, c: SketchConstraint) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for p: Vector2 in anchors_of(sk, c):
		sum += p
		n += 1
	return sum / maxf(1.0, float(n))


## Which constraints are currently violated past SATISFIED_TOL (index -> true).
## Computed separately from `draw` so the caller can evaluate it only at REST:
## mid-gesture the sub-solves leave transient sub-tolerance residuals on a
## heavy sketch, and reading them live made badges flash "unsolved" during a
## perfectly healthy drag (QA §M17-5 note). Dimensional constraints are skipped
## exactly as `draw` skips them.
static func unsolved_set(sk: Sketch) -> Dictionary:
	var out := {}
	for i in sk.constraints.size():
		var c := sk.constraints[i]
		if c.is_dimensional():
			continue
		if ConstraintSolver.error_of(sk, c) > SATISFIED_TOL:
			out[i] = true
	return out


## Draw all badges. Returns hit list: [{index, rect (screen)}] for click
## handling. `analysis` — DofAnalyzer.analyze result (or empty), `selected`
## — selected constraint index or -1, `unsolved` — the `unsolved_set` the
## caller last computed at rest (frozen during live gestures, like `analysis`).
static func draw(overlay: Control, view: SketchView, sk: Sketch,
		analysis: Dictionary, selected: int, unsolved: Dictionary = {}) -> Array:
	var hits: Array = []
	var font := ThemeDB.fallback_font
	var used_slots := {}      # screen cell -> count, to fan out stacked badges
	for i in sk.constraints.size():
		var c := sk.constraints[i]
		if c.is_dimensional():
			continue   # DimensionOverlay draws those as real annotations
		var color := COLOR_OK()
		if (analysis.get("conflicts", []) as Array).has(i):
			color = COLOR_CONFLICT()
		elif (analysis.get("redundant", []) as Array).has(i):
			color = COLOR_REDUNDANT()
		elif unsolved.has(i):
			color = COLOR_UNSOLVED()
		var label: String = GLYPH.get(c.type, "?")
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		# ONE BADGE PER OPERAND: a Parallel marks both lines, an Equal marks
		# both entities. Each is independently clickable and all of them map
		# back to the same constraint index, so clicking any one selects it.
		for world: Vector2 in anchors_of(sk, c):
			var screen := view.world_to_screen(world) + Vector2(10, -10)
			var cell := Vector2i(screen / 24.0)
			var slot := int(used_slots.get(cell, 0))
			used_slots[cell] = slot + 1
			screen += Vector2(slot * 20.0, 0)
			var rect := Rect2(screen - Vector2(3, 10), sz + Vector2(7, 6))
			overlay.draw_rect(rect, ThemeService.col("hud"))
			overlay.draw_rect(rect, COLOR_SELECTED() if i == selected else color,
				false, 2.0 if i == selected else 1.0)
			overlay.draw_string(font, screen, label, HORIZONTAL_ALIGNMENT_LEFT,
				-1, 11, color)
			hits.append({"index": i, "rect": rect})
	return hits
