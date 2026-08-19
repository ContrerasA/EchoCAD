class_name RenderBridge
extends RefCounted
## The ONLY code that touches TVGCanvas. Converts typed sketch entities to
## ThorVG stroke paths and rasterizes the visible plane rect to a texture.
## Sketch coordinates are Y-UP (CAD); ThorVG raster space is Y-DOWN — every
## position crossing this seam is flipped here (`_doc(p)`), and arc winding
## flips with it. Nothing outside this file may compensate for Y.
##
## M2 keeps sync simple: full rebuild per change (`full_sync`). Per-entity
## diff handles come with the tool milestones when interaction makes rebuild
## cost visible.

const COLOR_FREE := Color(0.30, 0.62, 0.96)          # under-constrained (Fusion blue)
const COLOR_CONSTRAINED := Color(0.42, 0.82, 0.55)   # fully constrained: green
const COLOR_CONSTRUCTION := Color(0.72, 0.55, 0.95)  # construction: violet dashed
## Projected (linked) geometry — Fusion's magenta. Solid stroke: it is real,
## snappable, profile-forming geometry, just owned by its source.
const COLOR_PROJECTED := Color(0.85, 0.45, 0.85)
## Geometry from OTHER sketches, drawn dim so it reads as context rather than
## as something the active sketch owns.
const COLOR_REFERENCE := Color(0.45, 0.50, 0.58, 0.55)
const STROKE_PX := 2.0                               # on-screen stroke width

var _canvas: TVGCanvas = null
## Stroke width in document mm for the CURRENT render (screen px / zoom).
var _stroke_mm := 0.5
## DOF result consumed by full_sync: {points: {id: true}, circles: {id: true}}.
var constrained := {"points": {}, "circles": {}}


func _init() -> void:
	if ClassDB.class_exists("TVGCanvas"):
		_canvas = TVGCanvas.new()


func available() -> bool:
	return _canvas != null


## Rebuild the whole canvas from a sketch. `zoom` = screen px per mm, used to
## keep stroke width constant on screen.
##
## `references` are OTHER sketches on the same plane, drawn first and dimmed:
## working on a sketch with the rest of the drawing invisible makes it
## impossible to place geometry in relation to what is already there. They are
## context only — not snappable, not hit-testable (that is M15).
func full_sync(sketch: Sketch, zoom: float, references: Array = []) -> void:
	if _canvas == null:
		return
	_canvas.clear()
	_stroke_mm = STROKE_PX / maxf(zoom, 0.001)
	for ref in references:
		var rs := ref as Sketch
		if rs == null or rs == sketch:
			continue
		for e in rs.entities():
			_add_entity(rs, e, true)
	for e in sketch.entities():
		_add_entity(sketch, e)


func _add_entity(sketch: Sketch, e: SketchEntity, reference := false) -> void:
	var path: Array = []
	match e.kind():
		"line":
			var l := e as SketchLine
			var a := sketch.point(l.p0)
			var b := sketch.point(l.p1)
			if a == null or b == null:
				return
			path = TVGShapes.line_path(_doc(a.pos), _doc(b.pos))
		"arc":
			var arc := e as SketchArc
			var c := sketch.point(arc.center)
			var s := sketch.point(arc.start)
			var t := sketch.point(arc.end)
			if c == null or s == null or t == null:
				return
			var cd := _doc(c.pos)
			var sd := _doc(s.pos)
			var td := _doc(t.pos)
			var r := cd.distance_to(sd)
			# Y-flip reverses winding: sketch ccw renders as doc cw.
			path = TVGShapes.arc_path_between(cd, r,
				(sd - cd).angle(), (td - cd).angle(), not arc.ccw)
		"circle":
			var ci := e as SketchCircle
			var cc := sketch.point(ci.center)
			if cc == null:
				return
			path = TVGShapes.circle_path(_doc(cc.pos), ci.radius)
		"spline":
			# Exact cubics — the raster draws the true curve; only profile
			# building and hit testing use the tessellation.
			var sp := e as SketchSpline
			var spans := sp.span_count()
			if spans == 0:
				return
			var cmds := PackedInt32Array()
			var pts := PackedVector2Array()
			var p_first := sketch.point(sp.points[0])
			if p_first == null:
				return
			cmds.append(TVGCanvas.CMD_MOVE_TO)
			pts.append(_doc(p_first.pos))
			for i in spans:
				var cp := sp.span(sketch, i)
				if cp.is_empty():
					return
				cmds.append(TVGCanvas.CMD_CUBIC_TO)
				pts.append(_doc(cp[1]))
				pts.append(_doc(cp[2]))
				pts.append(_doc(cp[3]))
			path = [cmds, pts]
		_:
			return   # points are editor chrome, drawn by the overlay
	var handle := _canvas.add_path(path[0], path[1])
	if reference:
		# One flat dim stroke: reference geometry must not advertise its own
		# construction/constrained state and compete with the active sketch.
		_canvas.set_stroke(handle, _stroke_mm * 0.75, COLOR_REFERENCE,
			TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)
		return
	if e.is_projected():
		_canvas.set_stroke(handle, _stroke_mm, COLOR_PROJECTED,
			TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)
	elif e.construction:
		_canvas.set_stroke(handle, _stroke_mm * 0.75, COLOR_CONSTRUCTION,
			TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)
		_canvas.set_stroke_dash(handle, PackedFloat32Array(
			[_stroke_mm * 4.0, _stroke_mm * 3.0]), 0.0)
	else:
		var color := COLOR_CONSTRAINED if _is_constrained(e) else COLOR_FREE
		_canvas.set_stroke(handle, _stroke_mm, color,
			TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)


## Fully constrained = every point the entity depends on is determined
## (plus the radius variable for circles).
func _is_constrained(e: SketchEntity) -> bool:
	var pts: Dictionary = constrained["points"]
	for pid in e.point_refs():
		if not pts.has(pid):
			return false
	if e.kind() == "circle" and not (constrained["circles"] as Dictionary).has(e.id):
		return false
	return not e.point_refs().is_empty()


## Render the sketch rect `view_mm` (sketch coords, Y-up) to an Image at
## w x h pixels — the source of truth for tests and screenshots. (Texture
## readback via ImageTexture.get_image() is unreliable under --headless: the
## dummy renderer ignores texture_2d_update, so both update() and
## same-size set_image() serve stale pixels. Assert on THIS image, never on
## a texture.)
func render_image(view_mm: Rect2, w: int, h: int) -> Image:
	if _canvas == null or w <= 0 or h <= 0:
		return null
	# Y-up rect -> Y-down doc rect: top edge (max y) maps to doc min y.
	var doc_box := Rect2(view_mm.position.x, -view_mm.end.y,
		view_mm.size.x, view_mm.size.y)
	_canvas.set_view_box(doc_box)
	return _canvas.render_to_image(w, h, false)


## Render into `tex` for display (windowed runs).
func render(view_mm: Rect2, w: int, h: int, tex: ImageTexture) -> bool:
	var img := render_image(view_mm, w, h)
	if img == null:
		return false
	tex.set_image(img)
	return true


func _doc(p: Vector2) -> Vector2:
	return Vector2(p.x, -p.y)
