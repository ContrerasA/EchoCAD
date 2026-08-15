# tvg_shapes.gd
#
# TVGShapes — pure-GDScript shape & path GENERATORS for TVGCanvas.
#
# Why this is GDScript and not C++: TVGCanvas is a thin, faithful binding over
# ThorVG's renderer. Everything here is geometry *authoring* — point math that
# emits the same {command, point} stream TVGCanvas.add_path() already consumes.
# Keeping it in script means no recompile to tweak a star's inner radius, and
# contributors can extend it without the (nix-only) native toolchain.
#
# All coordinates are in DOCUMENT space — the same space as add_path() and
# TVGCanvas.set_view_box(). The default view box is the unit square (0,0,1,1),
# so authoring in 0..1 maps to the full output; set a view box to use pixels.
#
# Two tiers:
#   * `*_path(...)`  -> returns [PackedInt32Array commands, PackedVector2Array points].
#                      Pure geometry, no canvas. Compose / concatenate freely,
#                      then push once with add_path() (see `concat`).
#   * `add_*(canvas, ...)` -> emits onto a TVGCanvas and returns the int64 handle
#                      (0 on failure), so you can immediately set fill/stroke.
#
# Usage:
#   var h := TVGShapes.add_star(canvas, Vector2(0.5, 0.5), 0.4, 0.18, 5)
#   canvas.set_fill_solid(h, Color.GOLD)
#
#   # compose: a path array you can transform / reuse
#   var p := TVGShapes.circle_path(Vector2(0.5, 0.5), 0.3)
#   var h2 := canvas.add_path(p[0], p[1])

class_name TVGShapes
extends RefCounted

# Magic constant for approximating a 90° circular arc with a cubic Bézier:
# control points sit (4/3)*tan(pi/8) = 0.5522847498 of the radius along the
# tangent. Used for circles, ellipses, arcs, donuts and round caps.
const KAPPA := 0.5522847498307936

# ---------------------------------------------------------------------------
# Path builders — return [PackedInt32Array commands, PackedVector2Array points]
# ---------------------------------------------------------------------------

## Open or closed polyline through `pts`. `closed` appends CMD_CLOSE.
static func polyline_path(pts: PackedVector2Array, closed: bool = false) -> Array:
	var cmds := PackedInt32Array()
	var out := PackedVector2Array()
	if pts.size() < 2:
		return [cmds, out]
	cmds.append(TVGCanvas.CMD_MOVE_TO); out.append(pts[0])
	for i in range(1, pts.size()):
		cmds.append(TVGCanvas.CMD_LINE_TO); out.append(pts[i])
	if closed:
		cmds.append(TVGCanvas.CMD_CLOSE)
	return [cmds, out]

## A single straight segment from `a` to `b`.
static func line_path(a: Vector2, b: Vector2) -> Array:
	return polyline_path(PackedVector2Array([a, b]))

## Axis-aligned rectangle. `corner_radius` > 0 rounds all four corners (clamped
## to half the shorter side). `square` is just a rect with equal sides.
static func rect_path(rect: Rect2, corner_radius: float = 0.0) -> Array:
	var cmds := PackedInt32Array()
	var pts := PackedVector2Array()
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	var h := rect.size.y
	var x2 := x + w
	var y2 := y + h
	var r: float = clampf(corner_radius, 0.0, minf(absf(w), absf(h)) * 0.5)
	if r <= 0.0:
		cmds.append(TVGCanvas.CMD_MOVE_TO); pts.append(Vector2(x, y))
		cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x2, y))
		cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x2, y2))
		cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x, y2))
		cmds.append(TVGCanvas.CMD_CLOSE)
		return [cmds, pts]
	var c := r * KAPPA # tangent handle length for the rounded corners
	cmds.append(TVGCanvas.CMD_MOVE_TO); pts.append(Vector2(x + r, y))
	cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x2 - r, y))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(x2 - r + c, y)); pts.append(Vector2(x2, y + r - c)); pts.append(Vector2(x2, y + r))
	cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x2, y2 - r))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(x2, y2 - r + c)); pts.append(Vector2(x2 - r + c, y2)); pts.append(Vector2(x2 - r, y2))
	cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x + r, y2))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(x + r - c, y2)); pts.append(Vector2(x, y2 - r + c)); pts.append(Vector2(x, y2 - r))
	cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(Vector2(x, y + r))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(x, y + r - c)); pts.append(Vector2(x + r - c, y)); pts.append(Vector2(x + r, y))
	cmds.append(TVGCanvas.CMD_CLOSE)
	return [cmds, pts]

## Square centered at `center` with the given full `side` length.
static func square_path(center: Vector2, side: float, corner_radius: float = 0.0) -> Array:
	var half := side * 0.5
	return rect_path(Rect2(center - Vector2(half, half), Vector2(side, side)), corner_radius)

## Ellipse centered at `center` with radii (rx, ry). Built from four cubic
## Bézier quadrants — the same approximation ThorVG uses internally.
static func ellipse_path(center: Vector2, rx: float, ry: float) -> Array:
	var cmds := PackedInt32Array()
	var pts := PackedVector2Array()
	var ox := rx * KAPPA
	var oy := ry * KAPPA
	var cx := center.x
	var cy := center.y
	cmds.append(TVGCanvas.CMD_MOVE_TO); pts.append(Vector2(cx + rx, cy))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(cx + rx, cy + oy)); pts.append(Vector2(cx + ox, cy + ry)); pts.append(Vector2(cx, cy + ry))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(cx - ox, cy + ry)); pts.append(Vector2(cx - rx, cy + oy)); pts.append(Vector2(cx - rx, cy))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(cx - rx, cy - oy)); pts.append(Vector2(cx - ox, cy - ry)); pts.append(Vector2(cx, cy - ry))
	cmds.append(TVGCanvas.CMD_CUBIC_TO)
	pts.append(Vector2(cx + ox, cy - ry)); pts.append(Vector2(cx + rx, cy - oy)); pts.append(Vector2(cx + rx, cy))
	cmds.append(TVGCanvas.CMD_CLOSE)
	return [cmds, pts]

## Circle centered at `center` with `radius`.
static func circle_path(center: Vector2, radius: float) -> Array:
	return ellipse_path(center, radius, radius)

## Arc as a sequence of cubic Béziers, swept from `start_angle` over
## `sweep_angle` radians (CCW positive). Returns ONLY the curve commands (no
## moveto), so it can be stitched into larger paths; `move` prepends a moveto
## to the arc's first point when you want it standalone.
static func arc_path(center: Vector2, radius: float, start_angle: float,
		sweep_angle: float, move: bool = true) -> Array:
	var cmds := PackedInt32Array()
	var pts := PackedVector2Array()
	# Split into <= 90deg segments so each Bézier stays accurate.
	var segments: int = maxi(1, int(ceil(absf(sweep_angle) / (PI * 0.5))))
	var seg := sweep_angle / float(segments)
	var a := start_angle
	if move:
		cmds.append(TVGCanvas.CMD_MOVE_TO)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	# Per-segment cubic handle length for the unit circle, scaled by radius.
	var k := (4.0 / 3.0) * tan(seg * 0.25) * radius
	for i in segments:
		var a2 := a + seg
		var p0 := center + Vector2(cos(a), sin(a)) * radius
		var p3 := center + Vector2(cos(a2), sin(a2)) * radius
		var t0 := Vector2(-sin(a), cos(a))   # unit tangent at a (CCW)
		var t1 := Vector2(-sin(a2), cos(a2)) # unit tangent at a2
		cmds.append(TVGCanvas.CMD_CUBIC_TO)
		pts.append(p0 + t0 * k)
		pts.append(p3 - t1 * k)
		pts.append(p3)
		a = a2
	return [cmds, pts]

## Donut / annulus / ring: outer circle minus inner circle. The inner ring is
## wound opposite the outer so the even-odd fill rule punches the hole. Set the
## shape's fill rule to RULE_EVEN_ODD after adding it.
static func donut_path(center: Vector2, outer_radius: float, inner_radius: float) -> Array:
	var outer := circle_path(center, outer_radius)
	# Inner ellipse traversed clockwise (negate to reverse winding): build via a
	# reversed-sweep arc so even-odd carves the hole regardless of fill rule.
	var inner := arc_path(center, inner_radius, 0.0, -TAU, true)
	inner[0].append(TVGCanvas.CMD_CLOSE)
	return concat([outer, inner])

## Regular N-gon (triangle=3, pentagon=5, ...) inscribed in `radius`.
## `rotation` (radians) spins it; default points the first vertex up.
## `corner_radius` > 0 rounds every vertex with a fillet arc (in document
## units, clamped so adjacent fillets never overlap).
static func polygon_path(center: Vector2, radius: float, sides: int,
		rotation: float = -PI * 0.5, corner_radius: float = 0.0) -> Array:
	var pts := PackedVector2Array()
	var n: int = maxi(3, sides)
	for i in n:
		var a := rotation + TAU * float(i) / float(n)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	if corner_radius <= 0.0:
		return polyline_path(pts, true)
	return rounded_polygon_path(pts, corner_radius)

## Star with `points` spikes alternating between `outer_radius` and
## `inner_radius`. `rotation` spins it; default points the first spike up.
## `corner_radius` > 0 rounds every vertex (both the spikes and the inner
## notches) with a fillet arc.
static func star_path(center: Vector2, outer_radius: float, inner_radius: float,
		points: int, rotation: float = -PI * 0.5, corner_radius: float = 0.0) -> Array:
	var pts := PackedVector2Array()
	var n: int = maxi(2, points)
	for i in (n * 2):
		var r := outer_radius if (i % 2) == 0 else inner_radius
		var a := rotation + PI * float(i) / float(n)
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	if corner_radius <= 0.0:
		return polyline_path(pts, true)
	return rounded_polygon_path(pts, corner_radius)

## Closed polygon through `verts` with every corner filleted by `radius`.
## Each sharp vertex is replaced by: a line up to where the fillet starts, then
## a cubic-Bézier arc rounding into the next edge. `radius` is clamped per-corner
## to half the shorter adjacent edge so fillets can't overshoot or overlap.
static func rounded_polygon_path(verts: PackedVector2Array, radius: float) -> Array:
	var n := verts.size()
	if n < 3 or radius <= 0.0:
		return polyline_path(verts, true)
	var cmds := PackedInt32Array()
	var pts := PackedVector2Array()
	var first_entry := Vector2.ZERO
	for i in n:
		var prev := verts[(i - 1 + n) % n]
		var cur := verts[i]
		var nxt := verts[(i + 1) % n]
		var v_in := cur - prev      # edge arriving at `cur`
		var v_out := nxt - cur      # edge leaving `cur`
		var len_in := v_in.length()
		var len_out := v_out.length()
		if len_in < 1e-6 or len_out < 1e-6:
			continue
		var dir_in := v_in / len_in
		var dir_out := v_out / len_out
		# Trim so the fillet fits both adjacent edges (share each edge between its
		# two corners -> cap at half the edge length).
		var trim: float = minf(radius, minf(len_in, len_out) * 0.5)
		var entry := cur - dir_in * trim   # where the rounding begins
		var exit := cur + dir_out * trim   # where it rejoins the next edge
		# Cubic handles pulled toward the corner approximate the circular fillet
		# (KAPPA-style; exact enough for a single corner bend).
		var h := trim * KAPPA
		if i == 0:
			cmds.append(TVGCanvas.CMD_MOVE_TO); pts.append(entry)
			first_entry = entry
		else:
			cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(entry)
		cmds.append(TVGCanvas.CMD_CUBIC_TO)
		pts.append(entry + dir_in * h)     # handle out of the entry, toward corner
		pts.append(exit - dir_out * h)     # handle into the exit, from corner
		pts.append(exit)
	# Close the loop back to the first corner's entry point.
	cmds.append(TVGCanvas.CMD_LINE_TO); pts.append(first_entry)
	cmds.append(TVGCanvas.CMD_CLOSE)
	return [cmds, pts]

## Arc specified by START and END angle (radians) instead of start + sweep.
## `ccw` chooses the winding direction between them. Thin wrapper over arc_path.
static func arc_path_between(center: Vector2, radius: float, start_angle: float,
		end_angle: float, ccw: bool = true, move: bool = true) -> Array:
	var sweep := end_angle - start_angle
	# Normalize into the requested direction so e.g. 350deg->10deg goes the short
	# way when ccw matches, rather than nearly all the way around.
	if ccw and sweep < 0.0:
		sweep += TAU
	elif not ccw and sweep > 0.0:
		sweep -= TAU
	return arc_path(center, radius, start_angle, sweep, move)

## Straight arrow from `start` to `tip` with a V / triangle head at the tip.
## Returns the SHAFT as an open polyline plus the head; intended to be STROKED
## (use add_arrow for a filled variant). `head_length`/`head_width` are in
## document units; `head_width` is the full span across the barbs.
static func arrow_path(start: Vector2, tip: Vector2, head_length: float,
		head_width: float) -> Array:
	var dir := (tip - start)
	if dir.length() < 1e-6:
		return [PackedInt32Array(), PackedVector2Array()]
	dir = dir.normalized()
	var normal := Vector2(-dir.y, dir.x)
	var base := tip - dir * head_length
	var left := base + normal * (head_width * 0.5)
	var right := base - normal * (head_width * 0.5)
	# shaft, then an open V for the head (left -> tip -> right)
	return polyline_path(PackedVector2Array([start, tip, left, tip, right]))

## Convert a Godot Curve2D (e.g. from a Path2D node) into a polyline path by
## tessellating it. `tolerance`/`max_stages` are passed to Curve2D.tessellate.
## Coordinates come straight from the curve, so set your view box to match
## (typically pixel space) or pre-scale the curve points.
static func curve_path(curve: Curve2D, closed: bool = false,
		max_stages: int = 5, tolerance: float = 4.0) -> Array:
	if curve == null or curve.point_count < 2:
		return [PackedInt32Array(), PackedVector2Array()]
	var baked := curve.tessellate(max_stages, tolerance)
	return polyline_path(baked, closed)

## Concatenate several [cmds, pts] path arrays into one. Lets you build compound
## shapes (donut, arrow head + shaft, multi-contour glyphs) and push them with a
## single add_path() call.
static func concat(paths: Array) -> Array:
	var cmds := PackedInt32Array()
	var pts := PackedVector2Array()
	for p in paths:
		cmds.append_array(p[0])
		pts.append_array(p[1])
	return [cmds, pts]

# ---------------------------------------------------------------------------
# Canvas convenience wrappers — emit onto a TVGCanvas, return the handle (0 on
# failure). Thin sugar over add_path(); use the *_path builders for composition.
# ---------------------------------------------------------------------------

static func _add(canvas: TVGCanvas, path: Array) -> int:
	if canvas == null:
		return 0
	return canvas.add_path(path[0], path[1])

static func add_line(canvas: TVGCanvas, a: Vector2, b: Vector2) -> int:
	return _add(canvas, line_path(a, b))

static func add_polyline(canvas: TVGCanvas, pts: PackedVector2Array, closed: bool = false) -> int:
	return _add(canvas, polyline_path(pts, closed))

static func add_rect(canvas: TVGCanvas, rect: Rect2, corner_radius: float = 0.0) -> int:
	return _add(canvas, rect_path(rect, corner_radius))

static func add_square(canvas: TVGCanvas, center: Vector2, side: float, corner_radius: float = 0.0) -> int:
	return _add(canvas, square_path(center, side, corner_radius))

static func add_circle(canvas: TVGCanvas, center: Vector2, radius: float) -> int:
	return _add(canvas, circle_path(center, radius))

static func add_ellipse(canvas: TVGCanvas, center: Vector2, rx: float, ry: float) -> int:
	return _add(canvas, ellipse_path(center, rx, ry))

static func add_arc(canvas: TVGCanvas, center: Vector2, radius: float,
		start_angle: float, sweep_angle: float) -> int:
	return _add(canvas, arc_path(center, radius, start_angle, sweep_angle, true))

## Arc by START and END angle (radians); `ccw` picks the direction.
static func add_arc_between(canvas: TVGCanvas, center: Vector2, radius: float,
		start_angle: float, end_angle: float, ccw: bool = true) -> int:
	return _add(canvas, arc_path_between(center, radius, start_angle, end_angle, ccw, true))

## Donut — also sets the even-odd fill rule so the hole renders. Returns handle.
static func add_donut(canvas: TVGCanvas, center: Vector2, outer_radius: float, inner_radius: float) -> int:
	var h := _add(canvas, donut_path(center, outer_radius, inner_radius))
	if h != 0:
		canvas.set_fill_rule(h, TVGCanvas.RULE_EVEN_ODD)
	return h

static func add_polygon(canvas: TVGCanvas, center: Vector2, radius: float,
		sides: int, rotation: float = -PI * 0.5, corner_radius: float = 0.0) -> int:
	return _add(canvas, polygon_path(center, radius, sides, rotation, corner_radius))

static func add_star(canvas: TVGCanvas, center: Vector2, outer_radius: float,
		inner_radius: float, points: int, rotation: float = -PI * 0.5,
		corner_radius: float = 0.0) -> int:
	return _add(canvas, star_path(center, outer_radius, inner_radius, points, rotation, corner_radius))

static func add_arrow(canvas: TVGCanvas, start: Vector2, tip: Vector2,
		head_length: float, head_width: float) -> int:
	return _add(canvas, arrow_path(start, tip, head_length, head_width))

static func add_curve(canvas: TVGCanvas, curve: Curve2D, closed: bool = false,
		max_stages: int = 5, tolerance: float = 4.0) -> int:
	return _add(canvas, curve_path(curve, closed, max_stages, tolerance))

# ---------------------------------------------------------------------------
# Stroke styling helpers — "dotted line" and the various end caps are STROKE
# properties on the binding, not geometry. These wrap set_stroke/set_stroke_dash
# so the intent reads clearly at the call site. Apply to any shape handle.
# ---------------------------------------------------------------------------

## Dotted stroke: round caps + a tight dash so each dash renders as a dot. The
## dot DIAMETER equals the stroke `width` (round caps make the near-zero dash a
## circle of ~width). `gap` is the EDGE-TO-EDGE-ish space between dots and
## defaults to 2x the width. To make dots bigger/smaller independent of the line
## thickness you'd want, just raise/lower `width` — for a thin line with fat
## dots, see set_dotted_sized.
static func set_dotted(canvas: TVGCanvas, handle: int, width: float,
		color: Color, gap: float = -1.0) -> void:
	if canvas == null:
		return
	var g := gap if gap >= 0.0 else width * 2.0
	canvas.set_stroke(handle, width, color, TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)
	# A near-zero dash with round caps renders as a circular dot of ~width.
	canvas.set_stroke_dash(handle, PackedFloat32Array([0.0001, g]), 0.0)

## Dotted stroke with the dot diameter set EXPLICITLY (in document units) and
## independent manual `gap` spacing. The stroke width is set to the dot diameter
## (a round dot's size IS the stroke width with round caps), so this is the knob
## when you want to dial dot size and spacing directly.
static func set_dotted_sized(canvas: TVGCanvas, handle: int, dot_diameter: float,
		gap: float, color: Color) -> void:
	if canvas == null:
		return
	canvas.set_stroke(handle, dot_diameter, color, TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)
	canvas.set_stroke_dash(handle, PackedFloat32Array([0.0001, gap]), 0.0)

## Dashed stroke with explicit dash/gap lengths and a chosen cap.
static func set_dashed(canvas: TVGCanvas, handle: int, width: float, color: Color,
		dash: float, gap: float, cap: int = TVGCanvas.CAP_BUTT) -> void:
	if canvas == null:
		return
	canvas.set_stroke(handle, width, color, cap, TVGCanvas.JOIN_ROUND)
	canvas.set_stroke_dash(handle, PackedFloat32Array([dash, gap]), 0.0)

## Round-endcap stroke (e.g. for lines that should end in a half-circle).
static func set_round_caps(canvas: TVGCanvas, handle: int, width: float, color: Color) -> void:
	if canvas == null:
		return
	canvas.set_stroke(handle, width, color, TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)

## Sharp/flat-endcap stroke: butt caps + miter joins (the counterpart to
## set_round_caps for lines/outlines that should end square and crisp).
static func set_sharp_caps(canvas: TVGCanvas, handle: int, width: float, color: Color) -> void:
	if canvas == null:
		return
	canvas.set_stroke(handle, width, color, TVGCanvas.CAP_BUTT, TVGCanvas.JOIN_MITER)
