class_name DimensionOverlay
extends RefCounted
## Draws dimensional constraints as real annotations — extension lines,
## dimension line with arrowheads, radial leaders, angle arcs — with the
## value text parked at `label_offset` (sketch mm, serialized). Returns
## label hit rects for selection/drag/edit. Non-dimensional constraints are
## ConstraintOverlay's job.

const COLOR := Color(0.85, 0.87, 0.92)
const COLOR_SELECTED := Color(1.0, 0.85, 0.3)
const COLOR_DRIVEN := Color(0.65, 0.68, 0.75)
const COLOR_CONFLICT := Color(0.87, 0.39, 0.38)
const ARROW_PX := 7.0
const EXT_GAP_PX := 3.0


static func is_dimension(c: SketchConstraint) -> bool:
	return c.is_dimensional()


## Value text in the display unit ("2.500 in", "45.0°", "R0.500 in").
static func label_text(c: SketchConstraint, unit: UnitConverter.Unit) -> String:
	var T := SketchConstraint.Type
	var txt := ""
	match c.type:
		T.ANGLE:
			txt = "%.1f°" % c.value
		T.RADIUS:
			txt = "R" + UnitConverter.format(c.value, unit)
		T.DIAMETER:
			txt = "⌀" + UnitConverter.format(c.value, unit)
		_:
			txt = UnitConverter.format(c.value, unit)
	if c.expr != "":
		txt += "  (=%s)" % c.expr
	if c.driven:
		txt = "(" + txt + ")"
	return txt


## Draw every dimensional constraint; -> [{index, rect}].
static func draw(overlay: Control, view: SketchView, sk: Sketch,
		analysis: Dictionary, selected: int,
		unit: UnitConverter.Unit) -> Array:
	var hits: Array = []
	for i in sk.constraints.size():
		var c := sk.constraints[i]
		if not c.is_dimensional():
			continue
		var color := COLOR
		if (analysis.get("conflicts", []) as Array).has(i):
			color = COLOR_CONFLICT
		elif c.driven:
			color = COLOR_DRIVEN
		if i == selected:
			color = COLOR_SELECTED
		var rect := _draw_one(overlay, view, sk, c, color, unit)
		if rect != Rect2():
			hits.append({"index": i, "rect": rect})
	return hits


static func _draw_one(overlay: Control, view: SketchView, sk: Sketch,
		c: SketchConstraint, color: Color, unit: UnitConverter.Unit) -> Rect2:
	var T := SketchConstraint.Type
	match c.type:
		T.DISTANCE, T.DIST_X, T.DIST_Y:
			var a := sk.point(c.operands[0])
			var b := sk.point(c.operands[1])
			if a == null or b == null:
				return Rect2()
			return _linear(overlay, view, sk, c, a.pos, b.pos, color, unit)
		T.LINE_DIST:
			var l1 := sk.entity(c.operands[0]) as SketchLine
			var l2 := sk.entity(c.operands[1]) as SketchLine
			if l1 == null or l2 == null:
				return Rect2()
			var m2 := SketchGeometry.line_midpoint(sk, l2)
			var a1 := sk.point(l1.p0)
			var b1 := sk.point(l1.p1)
			if not m2.get("ok", false) or a1 == null or b1 == null:
				return Rect2()
			var d: Vector2 = (b1.pos - a1.pos).normalized()
			var foot: Vector2 = a1.pos + d * ((m2["pos"] as Vector2) - a1.pos).dot(d)
			return _linear(overlay, view, sk, c, foot, m2["pos"], color, unit)
		T.POINT_LINE_DIST:
			var p := sk.point(c.operands[0])
			var l := sk.entity(c.operands[1]) as SketchLine
			if p == null or l == null:
				return Rect2()
			var a1 := sk.point(l.p0)
			var b1 := sk.point(l.p1)
			var d: Vector2 = (b1.pos - a1.pos).normalized()
			var foot: Vector2 = a1.pos + d * (p.pos - a1.pos).dot(d)
			return _linear(overlay, view, sk, c, p.pos, foot, color, unit)
		T.ANGLE:
			return _angle(overlay, view, sk, c, color)
		T.RADIUS, T.DIAMETER:
			return _radial(overlay, view, sk, c, color, unit)
	return Rect2()


static func _label_rect(overlay: Control, at: Vector2, text: String,
		color: Color) -> Rect2:
	var font := ThemeDB.fallback_font
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	var rect := Rect2(at - sz * 0.5 - Vector2(3, 3), sz + Vector2(6, 6))
	overlay.draw_rect(rect, Color(0.10, 0.11, 0.13, 0.9))
	overlay.draw_string(ThemeDB.fallback_font,
		Vector2(rect.position.x + 3, rect.end.y - 5), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	return rect


static func _arrow(overlay: Control, tip: Vector2, dir: Vector2, color: Color) -> void:
	var n := Vector2(-dir.y, dir.x)
	overlay.draw_line(tip, tip - dir * ARROW_PX + n * ARROW_PX * 0.35, color, 1.0)
	overlay.draw_line(tip, tip - dir * ARROW_PX - n * ARROW_PX * 0.35, color, 1.0)


static func _linear(overlay: Control, view: SketchView, sk: Sketch,
		c: SketchConstraint, wa: Vector2, wb: Vector2, color: Color,
		unit: UnitConverter.Unit) -> Rect2:
	var T := SketchConstraint.Type
	# Measurement axis (DIST_X/Y project onto an axis).
	var axis := (wb - wa).normalized()
	if c.type == T.DIST_X:
		axis = Vector2.RIGHT
	elif c.type == T.DIST_Y:
		axis = Vector2.UP
	if axis == Vector2.ZERO:
		return Rect2()
	var wn := Vector2(-axis.y, axis.x)
	var label_world := (wa + wb) * 0.5 + c.label_offset
	# Dimension line passes through the label, parallel to axis.
	var offset := wn.dot(label_world - wa)
	var da := wa + wn * offset
	var db := wa + wn * offset + axis * axis.dot(wb - wa)
	var sa := view.world_to_screen(da)
	var sb := view.world_to_screen(db)
	var pa := view.world_to_screen(wa)
	var pb := view.world_to_screen(wb)
	# Extension lines (small gap at the geometry end).
	var ext_dir_a := (sa - pa).normalized()
	var ext_dir_b := (sb - pb).normalized()
	if ext_dir_a != Vector2.ZERO:
		overlay.draw_line(pa + ext_dir_a * EXT_GAP_PX, sa + ext_dir_a * EXT_GAP_PX, color, 1.0)
	if ext_dir_b != Vector2.ZERO:
		overlay.draw_line(pb + ext_dir_b * EXT_GAP_PX, sb + ext_dir_b * EXT_GAP_PX, color, 1.0)
	overlay.draw_line(sa, sb, color, 1.0)
	var line_dir := (sb - sa).normalized()
	if line_dir != Vector2.ZERO:
		_arrow(overlay, sa, -line_dir, color)
		_arrow(overlay, sb, line_dir, color)
	return _label_rect(overlay, view.world_to_screen(label_world),
		label_text(c, unit), color)


static func _radial(overlay: Control, view: SketchView, sk: Sketch,
		c: SketchConstraint, color: Color, unit: UnitConverter.Unit) -> Rect2:
	var e := sk.entity(c.operands[0])
	var center_id := ""
	var radius := 0.0
	if e is SketchCircle:
		center_id = (e as SketchCircle).center
		radius = (e as SketchCircle).radius
	elif e is SketchArc:
		var arc := e as SketchArc
		center_id = arc.center
		var sp := sk.point(arc.start)
		var cp0 := sk.point(arc.center)
		if sp != null and cp0 != null:
			radius = cp0.pos.distance_to(sp.pos)
	var cp := sk.point(center_id)
	if cp == null:
		return Rect2()
	var label_world := cp.pos + (c.label_offset if c.label_offset != Vector2.ZERO
		else Vector2(radius * 1.2, radius * 0.6))
	var dir := (label_world - cp.pos).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var rim := cp.pos + dir * radius
	overlay.draw_line(view.world_to_screen(label_world),
		view.world_to_screen(rim), color, 1.0)
	var sdir := (view.world_to_screen(rim)
		- view.world_to_screen(label_world)).normalized()
	_arrow(overlay, view.world_to_screen(rim), sdir, color)
	return _label_rect(overlay, view.world_to_screen(label_world),
		label_text(c, unit), color)


static func _angle(overlay: Control, view: SketchView, sk: Sketch,
		c: SketchConstraint, color: Color) -> Rect2:
	var l1 := sk.entity(c.operands[0]) as SketchLine
	var l2 := sk.entity(c.operands[1]) as SketchLine
	if l1 == null or l2 == null:
		return Rect2()
	var a1 := sk.point(l1.p0).pos
	var b1 := sk.point(l1.p1).pos
	var a2 := sk.point(l2.p0).pos
	var b2 := sk.point(l2.p1).pos
	# Live intersection of the infinite lines (fallback: midpoint mean).
	var apex := (a1 + b1 + a2 + b2) * 0.25
	var d1 := b1 - a1
	var d2 := b2 - a2
	var denom := d1.cross(d2)
	if absf(denom) > 1e-9:
		var t := (a2 - a1).cross(d2) / denom
		apex = a1 + d1 * t
	# Arms measured OUTWARD FROM THE APEX, not from the lines' stored
	# directions. A line's p0->p1 direction is an authoring detail: it may well
	# point back through the apex, and using it drew the arc on the opposite
	# side from the angle the user was actually dimensioning. The arm is the
	# direction of whichever endpoint is further from the apex — that is the
	# side the line visibly occupies.
	var arm1 := (b1 - apex) if apex.distance_to(b1) >= apex.distance_to(a1) \
		else (a1 - apex)
	var arm2 := (b2 - apex) if apex.distance_to(b2) >= apex.distance_to(a2) \
		else (a2 - apex)
	if arm1.length() < 1e-9 or arm2.length() < 1e-9:
		return Rect2()
	arm1 = arm1.normalized()
	arm2 = arm2.normalized()
	var label_world := apex + (c.label_offset if c.label_offset != Vector2.ZERO
		else (arm1 + arm2) * 8.0)
	var r_screen := view.world_to_screen(label_world).distance_to(
		view.world_to_screen(apex))
	var ang1 := -(arm1.angle())    # screen angles are Y-down
	var ang2 := -(arm2.angle())
	# Sweep the SHORT way, so the arc spans the angle being measured rather
	# than its reflex counterpart.
	var sweep := wrapf(ang2 - ang1, -PI, PI)
	overlay.draw_arc(view.world_to_screen(apex), maxf(r_screen, 12.0),
		ang1, ang1 + sweep, 32, color, 1.0)
	return _label_rect(overlay, view.world_to_screen(label_world),
		label_text(c, UnitConverter.Unit.MM), color)
