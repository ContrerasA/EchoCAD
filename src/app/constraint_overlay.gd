class_name ConstraintOverlay
extends RefCounted
## Draws constraint badges (glyph chips near their geometry) and provides
## their hit rects. Static + pure drawing; selection state and deletion live
## in AppRoot/SelectTool. Colors follow Fusion/echo_vector conventions:
## green satisfied, grey unsolved, amber redundant, red conflicting.

const COLOR_OK := Color(0.34, 0.69, 0.55)
const COLOR_UNSOLVED := Color(0.76, 0.78, 0.82)
const COLOR_REDUNDANT := Color(0.85, 0.63, 0.25)
const COLOR_CONFLICT := Color(0.87, 0.39, 0.38)
const COLOR_SELECTED := Color(1.0, 0.85, 0.3)
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


## Representative world position of a constraint (mean of operand reps).
static func anchor_of(sk: Sketch, c: SketchConstraint) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for op in c.operands:
		var e := sk.entity(op)
		if e == null:
			continue
		var p := Vector2.ZERO
		match e.kind():
			"point":
				p = (e as SketchPoint).pos
			"line":
				var m := SketchGeometry.line_midpoint(sk, e as SketchLine)
				if not m.get("ok", false):
					continue
				p = m["pos"]
			"circle", "arc":
				var cp := sk.point((e as SketchArc).center if e is SketchArc
					else (e as SketchCircle).center)
				if cp == null:
					continue
				p = cp.pos
		sum += p
		n += 1
	return sum / maxf(1.0, float(n))


## Draw all badges. Returns hit list: [{index, rect (screen)}] for click
## handling. `analysis` — DofAnalyzer.analyze result (or empty), `selected`
## — selected constraint index or -1.
static func draw(overlay: Control, view: SketchView, sk: Sketch,
		analysis: Dictionary, selected: int) -> Array:
	var hits: Array = []
	var font := ThemeDB.fallback_font
	var used_slots := {}      # screen cell -> count, to fan out stacked badges
	for i in sk.constraints.size():
		var c := sk.constraints[i]
		if c.is_dimensional():
			continue   # DimensionOverlay draws those as real annotations
		var world := anchor_of(sk, c)
		var screen := view.world_to_screen(world) + Vector2(10, -10)
		var cell := Vector2i(screen / 24.0)
		var slot := int(used_slots.get(cell, 0))
		used_slots[cell] = slot + 1
		screen += Vector2(slot * 20.0, 0)
		var color := COLOR_OK
		if (analysis.get("conflicts", []) as Array).has(i):
			color = COLOR_CONFLICT
		elif (analysis.get("redundant", []) as Array).has(i):
			color = COLOR_REDUNDANT
		elif ConstraintSolver.error_of(sk, c) > SATISFIED_TOL:
			color = COLOR_UNSOLVED
		var label: String = GLYPH.get(c.type, "?")
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		var rect := Rect2(screen - Vector2(3, 10), sz + Vector2(7, 6))
		overlay.draw_rect(rect, Color(0.10, 0.11, 0.13, 0.85))
		overlay.draw_rect(rect, COLOR_SELECTED if i == selected else color,
			false, 2.0 if i == selected else 1.0)
		overlay.draw_string(font, screen, label, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11, color)
		hits.append({"index": i, "rect": rect})
	return hits
