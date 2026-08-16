class_name ConstraintSolver
extends RefCounted
## 2D sketch constraint solver — iterative constraint projection
## (Gauss-Seidel style), the approach proven in echo_vector, retargeted to
## typed entities. Static + pure: reads a Sketch, returns proposed moves;
## commands apply them, so undo stays universal.
##
## Variables: every SketchPoint position (2 DOF) and every SketchCircle
## radius (1 DOF). Arcs carry an IMPLICIT equal-radius coupling
## (|start-center| == |end-center|) added as a residual/projection row.
##
## Each round projects every constraint: compute the minimal correction that
## satisfies it and distribute over its non-pinned operands. Rounds cap at
## MAX_ROUNDS; over-constrained systems don't explode — iteration returns
## the best compromise. Driven dimensions measure and never project.

const MAX_ROUNDS := 200
const CONVERGED := 0.0005      # mm — max correction magnitude to stop
## Under-relaxation on every point move. Stiff loops (a slot's shared rim
## points feed four tangencies + equal radii + arc couplings) overshoot and
## explode at full step; damped Gauss-Seidel trades round count for
## stability.
const RELAX := 0.6
## Most a SINGLE solve may grow an arc's radius, as a multiple of the radius it
## had on entry.
##
## A RATE limit, not a hard cap. A drag is one solve per frame, each re-anchored
## to the previous result, so this bound compounds and cannot by itself stop
## sustained growth — nor should it, since a legitimate tangency re-solve
## genuinely needs to resize an arc substantially in one step (2.0 is the
## smallest factor that leaves `tests/m06_arc_tools.gd`'s tangent-arc drag
## satisfiable). What it does buy is that a diverging tangency can no longer
## jump by orders of magnitude between two frames. The hard stop for an actual
## blow-up is the sanity check at the end of `solve`.
const MAX_RADIUS_GROWTH := 2.0
## Absolute slack added to that ceiling (mm), so an arc that starts tiny or
## degenerate still has room to move. Kept small for the same compounding
## reason as MAX_RADIUS_GROWTH: it is granted afresh on every solve.
const RADIUS_SLACK_MM := 1.0
## Smallest radius any projection may drive an arc to (mm). A collapsed arc is
## unrecoverable — with centre and rim coincident there is no radius direction
## left for a later projection to push along — so this is a floor, not a hint.
const MIN_ARC_RADIUS_MM := 0.01
## A solved point further than this many times the sketch's own reach is taken
## as a numerical blow-up, not a result, and the whole solve is discarded.
## Deliberately loose: a solve legitimately moves geometry a long way when a
## dimension is driven, so this must only ever catch divergence.
const SANITY_FACTOR := 100.0
## Floor for that budget (mm), so an empty or tiny sketch still has room.
const SANITY_FLOOR_MM := 10000.0

## Solve the sketch. `pinned` — Dictionary set OR Array of point entity ids
## that must not move (dragged points, FIX operands are added internally).
## Returns {"points": {id: Vector2}, "radii": {id: float}, "rounds": int}
## containing ONLY handles that moved.
static func solve(sk: Sketch, pinned = []) -> Dictionary:
	var pin := {}
	if pinned is Dictionary:
		pin = (pinned as Dictionary).duplicate()
	else:
		for id in pinned:
			pin[String(id)] = true
	# The sketch origin is immovable by definition — it is the datum everything
	# else is measured from, so it is pinned exactly as a FIX operand is.
	if sk.origin_id() != "":
		pin[sk.origin_id()] = true
	# FIX constraints pin every point of their operand.
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.FIX:
			for op in c.operands:
				var e := sk.entity(op)
				if e == null:
					continue
				if e.kind() == "point":
					pin[e.id] = true
				for pid in e.point_refs():
					pin[pid] = true

	# Working state.
	var pos := {}
	var rad := {}
	for e in sk.entities():
		if e.kind() == "point":
			pos[e.id] = (e as SketchPoint).pos
		elif e.kind() == "circle":
			rad[e.id] = (e as SketchCircle).radius

	var arcs: Array = []
	for e in sk.entities():
		if e.kind() == "arc":
			arcs.append(e)

	# Per-arc radius ceiling, from EACH ARC's OWN radius on entry. Anchoring to
	# the arc rather than to the sketch's overall extent matters: a bound taken
	# from the whole point cloud ratchets, because an inflated rim widens the
	# cloud and so grants a larger bound on the next solve.
	var arc_ceiling := {}
	for a: SketchArc in arcs:
		var r0 := 0.0
		if pos.has(a.center) and pos.has(a.start):
			r0 = (pos[a.start] as Vector2).distance_to(pos[a.center] as Vector2)
		arc_ceiling[a.id] = r0 * MAX_RADIUS_GROWTH + RADIUS_SLACK_MM

	# Rim points that other geometry holds in place. They are still solver
	# variables — projections move them freely — but they are not free to be
	# translated as a SIDE EFFECT of an arc's centre moving. See the rigid
	# ride-along in the round loop for why that distinction matters.
	#
	# Two ways a rim gets held, and both must count:
	#  - a COINCIDENT ties it to another point, or
	#  - it is SHARED outright with another entity (the tangent arc tool welds
	#    its start onto the line's endpoint, so one point serves both). Keying
	#    only on Coincident silently missed every welded rim, which is the more
	#    common case now that the tools weld rather than duplicate.
	var anchored := {}
	for c in sk.constraints:
		if c.driven or c.type != SketchConstraint.Type.COINCIDENT:
			continue
		for op in c.operands:
			anchored[op] = true
	var shared := {}
	var rim_of := {}
	for a: SketchArc in arcs:
		for pid: String in [a.start, a.end]:
			rim_of[pid] = true
	for e in sk.entities():
		if e.kind() == "arc":
			continue
		for pid in e.point_refs():
			if rim_of.has(pid):
				shared[pid] = true
	# Only anchor a shared rim when the arc's OTHER rim is free. An arc with
	# BOTH rims shared — a slot's end cap, whose two rim points are also the
	# ends of its side lines — is meant to ride rigidly with its centre; that
	# is exactly how driving a slot's length keeps its width. Freezing both
	# rims there would stop the slot deforming as a slot at all. It is the
	# one-end-held case (a tangent arc welded to a line at a single point)
	# where riding along is self-defeating.
	for a: SketchArc in arcs:
		var s_held := shared.has(a.start) or anchored.has(a.start)
		var e_held := shared.has(a.end) or anchored.has(a.end)
		if s_held != e_held:
			anchored[a.start if s_held else a.end] = true

	var rounds := 0
	for round_i in MAX_ROUNDS:
		rounds = round_i + 1
		# Rigid propagation: when a projection translates an arc's CENTER,
		# its rim points ride along (minimal-motion behavior — driving a
		# slot's length must not shrink its width). Snapshot centers, then
		# apply the round's center deltas to unpinned rims afterwards.
		var centers_before := {}
		for a: SketchArc in arcs:
			centers_before[a.id] = pos.get(a.center, Vector2.ZERO)
		var worst := 0.0
		for c in sk.constraints:
			if c.driven:
				continue
			worst = maxf(worst, _project(sk, c, pos, rad, pin))
		for a: SketchArc in arcs:
			var delta: Vector2 = (pos.get(a.center, Vector2.ZERO) as Vector2) \
				- (centers_before[a.id] as Vector2)
			if delta.length() > 1e-12:
				for pid: String in [a.start, a.end]:
					# ANCHORED rims do not ride along. A rim that a Coincident
					# ties to other geometry is not free to translate, and
					# moving it here is self-defeating in the exact case that
					# broke: the tangency projection shifts the CENTRE to close
					# its gap, this loop then carries the rim the same way, and
					# the gap reopens by precisely the amount just corrected.
					# The constraint can never be satisfied, so it pushes harder
					# every round — a perfectly tangent arc's centre travelling
					# 1.7 m and tangency ending up WORSE than it started, off a
					# 5 mm drag. Rigid ride-along is a minimal-motion nicety
					# (driving a slot's length must not shrink its width); it
					# has to yield to an actual constraint.
					if pin.has(pid) or anchored.has(pid) or not pos.has(pid):
						continue
					pos[pid] = (pos[pid] as Vector2) + delta
					worst = maxf(worst, delta.length())
		for a: SketchArc in arcs:
			worst = maxf(worst, _project_arc_radius(sk, a, pos, pin, anchored))
		# Divergence guard. An arc's radius is implied by CENTER-TO-RIM distance,
		# so it grows without any radius projection running at all: a tangency
		# the solver cannot satisfy pushes the CENTER away each round while a
		# coincidence holds a rim point on the geometry being dragged. Over
		# MAX_ROUNDS that inflates without limit — the tangent-arc explosion,
		# which also dragged the frame rate down with it.
		#
		# Both ends of the pair have to be considered. Clamping only the rim
		# does nothing in exactly the case that matters, because the rim is the
		# PINNED end there; the center is what ran away. So pull whichever end
		# is free back to the ceiling, preferring the center (moving the rim
		# would fight the coincidence that is holding it).
		_clamp_arc_radii(arcs, arc_ceiling, pos, pin)
		if worst < CONVERGED:
			break

	# ...and once more after the loop. Running it only inside is not enough:
	# the guard sits before the convergence break, so on the final round the
	# projections that ran after the previous clamp would escape unchecked —
	# and a diverging arc does most of its damage in exactly those rounds.
	_clamp_arc_radii(arcs, arc_ceiling, pos, pin)

	var out_p := {}
	# Last line of defence: REJECT a solve that blew up rather than applying it.
	#
	# The per-constraint guards keep individual projections sane, but a stiff,
	# unsatisfiable system (the classic being a tangency fighting a coincidence
	# on a dragged endpoint) can still go numerically unstable as a whole — one
	# round where several projections reinforce, and every coordinate lands in
	# the hundreds of millions or at NaN. Applying that is what destroyed the
	# drawing and left the app crawling afterwards, since every later frame then
	# had to render geometry at that scale. Refusing it costs only that frame's
	# re-solve: the geometry simply stays where it was, which is the honest
	# outcome for constraints that cannot all be met.
	var budget := _sanity_budget(sk)
	for id: String in pos:
		var p: Vector2 = pos[id]
		if not (is_finite(p.x) and is_finite(p.y)) or p.length() > budget:
			return {"points": {}, "radii": {}, "rounds": rounds, "diverged": true}
	for id: String in rad:
		var rv := float(rad[id])
		if not is_finite(rv) or rv > budget:
			return {"points": {}, "radii": {}, "rounds": rounds, "diverged": true}

	for id: String in pos:
		var orig: Vector2 = (sk.point(id) as SketchPoint).pos
		if (pos[id] as Vector2).distance_to(orig) > 1e-9:
			out_p[id] = pos[id]
	var out_r := {}
	for id: String in rad:
		if absf(float(rad[id]) - (sk.entity(id) as SketchCircle).radius) > 1e-9:
			out_r[id] = rad[id]
	return {"points": out_p, "radii": out_r, "rounds": rounds, "diverged": false}


## How far from the origin a solved point may plausibly land, from the sketch's
## own size. Generous — this catches blow-ups (1e8 mm is 100 km), not designs.
static func _sanity_budget(sk: Sketch) -> float:
	var far := 0.0
	for e in sk.entities():
		if e.kind() == "point":
			far = maxf(far, (e as SketchPoint).pos.length())
	return maxf(far * SANITY_FACTOR, SANITY_FLOOR_MM)


## Hold every arc's center-to-rim distance at or under its ceiling.
##
## Pulls whichever end of the pair is free, preferring the CENTER: in the case
## that actually diverges the rim is pinned (a coincidence holds it on the
## geometry being dragged) and the center is what ran away, so clamping only
## the rim would do nothing at all.
static func _clamp_arc_radii(arcs: Array, ceilings: Dictionary,
		pos: Dictionary, pin: Dictionary) -> void:
	for a: SketchArc in arcs:
		if not pos.has(a.center):
			continue
		var ceiling: float = ceilings.get(a.id, RADIUS_SLACK_MM)
		for pid: String in [a.start, a.end]:
			if not pos.has(pid):
				continue
			var cc: Vector2 = pos[a.center]
			var dv: Vector2 = (pos[pid] as Vector2) - cc
			var dist := dv.length()
			if dist <= ceiling or dist < 1e-9:
				continue
			var dir := dv / dist
			if not pin.has(a.center):
				pos[a.center] = (pos[pid] as Vector2) - dir * ceiling
			elif not pin.has(pid):
				pos[pid] = cc + dir * ceiling


## Current signed error of a constraint against live values (for DOF /
## conflict checks and driven readouts). Returns 0.0 for satisfied.
static func error_of(sk: Sketch, c: SketchConstraint) -> float:
	var pos := {}
	var rad := {}
	for e in sk.entities():
		if e.kind() == "point":
			pos[e.id] = (e as SketchPoint).pos
		elif e.kind() == "circle":
			rad[e.id] = (e as SketchCircle).radius
	var res := residuals(sk, c, pos, rad)
	var worst := 0.0
	for r in res:
		worst = maxf(worst, absf(float(r)))
	return worst


## --- residuals (shared with DOF analysis) ------------------------------------

## Residual list for a constraint under a candidate state. Zero == satisfied.
static func residuals(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary) -> Array:
	var T := SketchConstraint.Type
	match c.type:
		T.COINCIDENT:
			var a := _pt(sk, c.operands[0], pos)
			var b := _pt(sk, c.operands[1], pos)
			return [a.x - b.x, a.y - b.y]
		T.HORIZONTAL:
			var ends := _line_ends(sk, c.operands[0], pos) if c.operands.size() == 1 \
				else [_pt(sk, c.operands[0], pos), _pt(sk, c.operands[1], pos)]
			return [ends[1].y - ends[0].y]
		T.VERTICAL:
			var ends := _line_ends(sk, c.operands[0], pos) if c.operands.size() == 1 \
				else [_pt(sk, c.operands[0], pos), _pt(sk, c.operands[1], pos)]
			return [ends[1].x - ends[0].x]
		T.PARALLEL:
			var d1 := _line_dir(sk, c.operands[0], pos)
			var d2 := _line_dir(sk, c.operands[1], pos)
			return [d1.cross(d2)]
		T.PERPENDICULAR:
			var d1 := _line_dir(sk, c.operands[0], pos)
			var d2 := _line_dir(sk, c.operands[1], pos)
			return [d1.dot(d2)]
		T.COLLINEAR:
			var e1 := _line_ends(sk, c.operands[0], pos)
			var e2 := _line_ends(sk, c.operands[1], pos)
			var d: Vector2 = ((e1[1] as Vector2) - (e1[0] as Vector2)).normalized()
			return [d.cross((e2[0] as Vector2) - (e1[0] as Vector2)),
				d.cross((e2[1] as Vector2) - (e1[0] as Vector2))]
		T.EQUAL:
			return [_size_of(sk, c.operands[0], pos, rad)
				- _size_of(sk, c.operands[1], pos, rad)]
		T.MIDPOINT:
			var p := _pt(sk, c.operands[0], pos)
			var ends := _line_ends(sk, c.operands[1], pos)
			var m: Vector2 = ((ends[0] as Vector2) + (ends[1] as Vector2)) * 0.5
			return [p.x - m.x, p.y - m.y]
		T.CONCENTRIC:
			var c1 := _center_of(sk, c.operands[0], pos)
			var c2 := _center_of(sk, c.operands[1], pos)
			return [c1.x - c2.x, c1.y - c2.y]
		T.TANGENT:
			return [_tangent_error(sk, c, pos, rad)]
		T.POINT_ON:
			var p := _pt(sk, c.operands[0], pos)
			var target := sk.entity(c.operands[1])
			if target == null:
				return []
			match target.kind():
				"line":
					var ends := _line_ends(sk, c.operands[1], pos)
					var d: Vector2 = ((ends[1] as Vector2) - (ends[0] as Vector2)).normalized()
					return [d.cross(p - (ends[0] as Vector2))]
				"circle", "arc":
					var cc := _center_of(sk, c.operands[1], pos)
					return [p.distance_to(cc) - _radius_of(sk, c.operands[1], pos, rad)]
			return []
		T.FIX:
			return []   # enforced via pinning
		T.SYMMETRY:
			var p := _pt(sk, c.operands[0], pos)
			var q := _pt(sk, c.operands[1], pos)
			var axis := _line_ends(sk, c.operands[2], pos)
			var m := _reflect(p, axis[0], axis[1])
			return [m.x - q.x, m.y - q.y]
		T.DISTANCE:
			var a := _pt(sk, c.operands[0], pos)
			var b := _pt(sk, c.operands[1], pos)
			return [a.distance_to(b) - c.value]
		T.DIST_X:
			var a := _pt(sk, c.operands[0], pos)
			var b := _pt(sk, c.operands[1], pos)
			return [absf(b.x - a.x) - c.value]
		T.DIST_Y:
			var a := _pt(sk, c.operands[0], pos)
			var b := _pt(sk, c.operands[1], pos)
			return [absf(b.y - a.y) - c.value]
		T.ANGLE:
			var d1 := _line_dir(sk, c.operands[0], pos)
			var d2 := _line_dir(sk, c.operands[1], pos)
			var ang := absf(wrapf(d2.angle() - d1.angle(), -PI, PI))
			return [ang - deg_to_rad(c.value)]
		T.RADIUS:
			return [_radius_of(sk, c.operands[0], pos, rad) - c.value]
		T.DIAMETER:
			return [_radius_of(sk, c.operands[0], pos, rad) - c.value * 0.5]
		T.LINE_DIST:
			var e1 := _line_ends(sk, c.operands[0], pos)
			var e2 := _line_ends(sk, c.operands[1], pos)
			var d: Vector2 = ((e1[1] as Vector2) - (e1[0] as Vector2)).normalized()
			var g1 := d.cross((e2[0] as Vector2) - (e1[0] as Vector2))
			var g2 := d.cross((e2[1] as Vector2) - (e1[0] as Vector2))
			return [absf(g1) - c.value, g1 - g2]
		T.POINT_LINE_DIST:
			var p := _pt(sk, c.operands[0], pos)
			var ends := _line_ends(sk, c.operands[1], pos)
			var d: Vector2 = ((ends[1] as Vector2) - (ends[0] as Vector2)).normalized()
			return [absf(d.cross(p - (ends[0] as Vector2))) - c.value]
	return []


## --- projection --------------------------------------------------------------

## Project one constraint; returns the applied correction magnitude (mm).
static func _project(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var T := SketchConstraint.Type
	match c.type:
		T.COINCIDENT:
			return _merge_points(c.operands[0], c.operands[1], pos, pin)
		T.HORIZONTAL:
			return _axis_align(sk, c, pos, pin, true)
		T.VERTICAL:
			return _axis_align(sk, c, pos, pin, false)
		T.PARALLEL:
			return _angle_between(sk, c.operands[0], c.operands[1], pos, pin, 0.0, true)
		T.PERPENDICULAR:
			return _angle_between(sk, c.operands[0], c.operands[1], pos, pin, PI / 2.0, true)
		T.ANGLE:
			return _angle_between(sk, c.operands[0], c.operands[1], pos, pin,
				deg_to_rad(c.value), false)
		T.COLLINEAR:
			return _collinear(sk, c, pos, pin)
		T.EQUAL:
			return _equalize(sk, c, pos, rad, pin)
		T.MIDPOINT:
			return _midpoint(sk, c, pos, pin)
		T.CONCENTRIC:
			return _merge_points(_center_id(sk, c.operands[0]),
				_center_id(sk, c.operands[1]), pos, pin)
		T.TANGENT:
			return _tangent(sk, c, pos, rad, pin)
		T.POINT_ON:
			return _point_on(sk, c, pos, rad, pin)
		T.SYMMETRY:
			return _symmetry(sk, c, pos, pin)
		T.DISTANCE:
			return _distance(sk, c, pos, pin)
		T.DIST_X:
			return _dist_axis(sk, c, pos, pin, true)
		T.DIST_Y:
			return _dist_axis(sk, c, pos, pin, false)
		T.RADIUS:
			return _set_radius(sk, c.operands[0], c.value, pos, rad, pin)
		T.DIAMETER:
			return _set_radius(sk, c.operands[0], c.value * 0.5, pos, rad, pin)
		T.LINE_DIST:
			return _line_dist(sk, c, pos, pin)
		T.POINT_LINE_DIST:
			return _point_line_dist(sk, c, pos, pin)
	return 0.0


static func _move(id: String, to: Vector2, pos: Dictionary, pin: Dictionary) -> float:
	if id == "" or pin.has(id) or not pos.has(id):
		return 0.0
	var cur: Vector2 = pos[id]
	var step := (to - cur) * RELAX
	pos[id] = cur + step
	return step.length()


## Split a correction between two points honoring pins. `delta` moves a
## toward b-satisfaction positively.
static func _pair_weights(a: String, b: String, pin: Dictionary) -> Vector2:
	var pa := pin.has(a)
	var pb := pin.has(b)
	if pa and pb:
		return Vector2.ZERO
	if pa:
		return Vector2(0.0, 1.0)
	if pb:
		return Vector2(1.0, 0.0)
	return Vector2(0.5, 0.5)


static func _merge_points(a: String, b: String, pos: Dictionary,
		pin: Dictionary) -> float:
	if a == "" or b == "" or not pos.has(a) or not pos.has(b):
		return 0.0
	var pa: Vector2 = pos[a]
	var pb: Vector2 = pos[b]
	var w := _pair_weights(a, b, pin)
	if w == Vector2.ZERO:
		return 0.0
	# Meeting point: a travels w.x of the gap; with one side pinned that is
	# the pinned position, with both free it is the midpoint.
	var t := pa.lerp(pb, w.x)
	var moved := _move(a, t, pos, pin)
	moved = maxf(moved, _move(b, t, pos, pin))
	return moved


static func _axis_align(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary, horizontal: bool) -> float:
	var ids := _operand_point_ids(sk, c)
	if ids.size() != 2:
		return 0.0
	var a: Vector2 = pos[ids[0]]
	var b: Vector2 = pos[ids[1]]
	var w := _pair_weights(ids[0], ids[1], pin)
	if w == Vector2.ZERO:
		return 0.0
	var moved := 0.0
	if horizontal:
		var target_y := lerpf(a.y, b.y, w.x)   # a moves w.x of the way
		moved = maxf(_move(ids[0], Vector2(a.x, target_y), pos, pin),
			_move(ids[1], Vector2(b.x, target_y), pos, pin))
	else:
		var target_x := lerpf(a.x, b.x, w.x)
		moved = maxf(_move(ids[0], Vector2(target_x, a.y), pos, pin),
			_move(ids[1], Vector2(target_x, b.y), pos, pin))
	return moved


## Rotate two segments toward a target relative angle. `either_dir` treats
## opposite directions as equal (parallel/perpendicular).
static func _angle_between(sk: Sketch, l1: String, l2: String, pos: Dictionary,
		pin: Dictionary, target: float, either_dir: bool) -> float:
	var i1 := _line_ids(sk, l1)
	var i2 := _line_ids(sk, l2)
	if i1.is_empty() or i2.is_empty():
		return 0.0
	var d1: Vector2 = (pos[i1[1]] as Vector2) - (pos[i1[0]] as Vector2)
	var d2: Vector2 = (pos[i2[1]] as Vector2) - (pos[i2[0]] as Vector2)
	var cur := wrapf(d2.angle() - d1.angle(), -PI, PI)
	var err := 0.0
	if either_dir:
		# Wrap into [-PI/2, PI/2] so anti-parallel counts as parallel.
		var rel := wrapf(cur - target, -PI, PI)
		if rel > PI / 2.0:
			rel -= PI
		elif rel < -PI / 2.0:
			rel += PI
		err = rel
	else:
		err = wrapf(absf(cur) - target, -PI, PI) * signf(cur if cur != 0.0 else 1.0)
	if absf(err) < 1e-9:
		return 0.0
	# Rotate each segment about its midpoint, splitting by mobility.
	var m1 := not (pin.has(i1[0]) and pin.has(i1[1]))
	var m2 := not (pin.has(i2[0]) and pin.has(i2[1]))
	if not (m1 or m2):
		return 0.0
	var s1 := (0.5 if m2 else 1.0) if m1 else 0.0
	var s2 := (0.5 if m1 else 1.0) if m2 else 0.0
	var moved := 0.0
	moved = maxf(moved, _rotate_segment(i1, err * s1, pos, pin))
	moved = maxf(moved, _rotate_segment(i2, -err * s2, pos, pin))
	return moved


static func _rotate_segment(ids: Array, by: float, pos: Dictionary,
		pin: Dictionary) -> float:
	if absf(by) < 1e-12:
		return 0.0
	var a: Vector2 = pos[ids[0]]
	var b: Vector2 = pos[ids[1]]
	# Pivot: pinned end if any, else midpoint.
	var pivot := (a + b) * 0.5
	if pin.has(ids[0]):
		pivot = a
	elif pin.has(ids[1]):
		pivot = b
	var moved := 0.0
	moved = maxf(moved, _move(ids[0], pivot + (a - pivot).rotated(by), pos, pin))
	moved = maxf(moved, _move(ids[1], pivot + (b - pivot).rotated(by), pos, pin))
	return moved


static func _collinear(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	var i1 := _line_ids(sk, c.operands[0])
	var i2 := _line_ids(sk, c.operands[1])
	if i1.is_empty() or i2.is_empty():
		return 0.0
	var a: Vector2 = pos[i1[0]]
	var d: Vector2 = ((pos[i1[1]] as Vector2) - a).normalized()
	if d == Vector2.ZERO:
		return 0.0
	var moved := 0.0
	for id in i2:
		var p: Vector2 = pos[id]
		var proj := a + d * (p - a).dot(d)
		moved = maxf(moved, _move(id, p.lerp(proj, 0.7), pos, pin))
	return moved


static func _equalize(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var s1 := _size_of(sk, c.operands[0], pos, rad)
	var s2 := _size_of(sk, c.operands[1], pos, rad)
	var target := (s1 + s2) * 0.5
	var moved := _set_size(sk, c.operands[0], target, pos, rad, pin)
	return maxf(moved, _set_size(sk, c.operands[1], target, pos, rad, pin))


static func _midpoint(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	var pid := c.operands[0]
	var ids := _line_ids(sk, c.operands[1])
	if ids.is_empty() or not pos.has(pid):
		return 0.0
	var m: Vector2 = ((pos[ids[0]] as Vector2) + (pos[ids[1]] as Vector2)) * 0.5
	var p: Vector2 = pos[pid]
	var err := m - p
	if err.length() < 1e-12:
		return 0.0
	var moved := 0.0
	if not pin.has(pid):
		moved = maxf(moved, _move(pid, p + err * 0.5, pos, pin))
		err *= 0.5
	# Translate the line to bring its midpoint the rest of the way.
	moved = maxf(moved, _move(ids[0], (pos[ids[0]] as Vector2) - err, pos, pin))
	moved = maxf(moved, _move(ids[1], (pos[ids[1]] as Vector2) - err, pos, pin))
	return moved


static func _tangent(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var a := sk.entity(c.operands[0])
	var b := sk.entity(c.operands[1])
	if a == null or b == null:
		return 0.0
	if a.kind() == "line":
		return _tangent_line_circle(sk, c.operands[0], c.operands[1], pos, rad, pin)
	if b.kind() == "line":
		return _tangent_line_circle(sk, c.operands[1], c.operands[0], pos, rad, pin)
	# circle/arc - circle/arc: external or internal, whichever is closer now.
	var c1 := _center_id(sk, c.operands[0])
	var c2 := _center_id(sk, c.operands[1])
	var r1 := _radius_of(sk, c.operands[0], pos, rad)
	var r2 := _radius_of(sk, c.operands[1], pos, rad)
	var p1: Vector2 = pos[c1]
	var p2: Vector2 = pos[c2]
	var dist := p1.distance_to(p2)
	var ext := absf(dist - (r1 + r2))
	var inte := absf(dist - absf(r1 - r2))
	var target := (r1 + r2) if ext <= inte else absf(r1 - r2)
	var err := dist - target
	if absf(err) < 1e-9 or dist < 1e-9:
		return 0.0
	var dirv := (p2 - p1) / dist
	var w := _pair_weights(c1, c2, pin)
	var moved := 0.0
	moved = maxf(moved, _move(c1, p1 + dirv * err * w.x, pos, pin))
	moved = maxf(moved, _move(c2, p2 - dirv * err * w.y, pos, pin))
	return moved


static func _tangent_line_circle(sk: Sketch, line_id: String, circ_id: String,
		pos: Dictionary, rad: Dictionary, pin: Dictionary) -> float:
	var ids := _line_ids(sk, line_id)
	var cid := _center_id(sk, circ_id)
	if ids.is_empty() or cid == "":
		return 0.0
	var a: Vector2 = pos[ids[0]]
	var b: Vector2 = pos[ids[1]]
	var cc: Vector2 = pos[cid]
	var d := (b - a).normalized()
	if d == Vector2.ZERO:
		return 0.0
	var n := Vector2(-d.y, d.x)
	var signed := n.dot(cc - a)
	var r := _radius_of(sk, circ_id, pos, rad)
	var err := absf(signed) - r
	if absf(err) < 1e-9:
		return 0.0
	var sgn := signf(signed if signed != 0.0 else 1.0)
	var moved := 0.0
	# ARC radius is defined by its own rim points — self-referential, so the
	# projection must give it a radius pathway (pull rims toward the gap) or
	# stiff loops like a slot never converge. Circles keep their radius here.
	# Resizing the arc is a LAST RESORT, used only when the centre is held and
	# so cannot absorb the error itself. Resizing is always available and always
	# "works", which is the trap: shrinking an arc towards a point satisfies
	# tangency trivially, so a solver free to reach for it will happily collapse
	# a 59 mm arc to 0.001 mm and report success. Preferring to move the centre
	# keeps the arc's size an expression of what the user drew.
	var is_arc := sk.entity(circ_id) is SketchArc
	if is_arc and pin.has(cid):
		# Damped with the same RELAX every other projection uses. Undamped,
		# this pathway overshoots whenever another constraint contests the same
		# rim points — the classic case being a tangent arc whose start is
		# coincident with the line endpoint being dragged. The hard ceiling on
		# runaway radii lives at the end of the solve round (see the divergence
		# guard there), because the radius can also grow with no radius
		# projection running at all.
		# Never below a floor: an arc collapsed to a point cannot be recovered
		# by any later projection, because its radius direction is gone.
		var want := maxf(r + err * 0.5 * RELAX, MIN_ARC_RADIUS_MM)
		moved = maxf(moved, _set_radius(sk, circ_id, want, pos, rad, pin))
		err *= 0.5
	# Close the gap by moving the ARC's centre in preference to the line.
	#
	# Translating the line sideways is almost always the wrong answer, and was
	# the cause of the tangent-arc blow-up. A tangent arc's start is COINCIDENT
	# with a line endpoint, so sliding the line perpendicular to itself drags
	# that shared point, which moves the arc, which changes the tangency error —
	# a feedback loop that never converges (200 rounds) and amplifies a 3 mm
	# drag into 30 mm of motion in unrelated-looking places. Worse, one of those
	# endpoints is usually the point the user is physically dragging, so the
	# correction fights the gesture directly.
	#
	# The centre is the free variable here: moving it satisfies tangency exactly
	# without disturbing anything else, because nothing else references it. Only
	# when the centre is genuinely pinned does the line move, and then only its
	# endpoints that are themselves unpinned.
	var center_mobile := not pin.has(cid)
	if center_mobile:
		# When a rim point is WELDED to the line (a tangent arc shares the
		# line's endpoint outright), sliding the centre straight along the
		# normal is wrong: the radius IS the centre-to-rim distance, so
		# translating the centre changes the radius, which changes the tangency
		# error, which asks for another translation — the centre marches off
		# forever and the error converges to the radius rather than to zero.
		#
		# Rotate the arc about that shared rim point instead. The radius is
		# preserved exactly (it is a rotation), and the centre lands where the
		# tangency wants it, which is what "the arc pivots to stay tangent"
		# means geometrically.
		var hub := ""
		for lid in ids:
			if lid == _center_id(sk, circ_id):
				continue
			if _arc_has_rim(sk, circ_id, lid):
				hub = lid
				break
		if hub != "":
			var h: Vector2 = pos[hub]
			var radius := (cc - h).length()
			if radius > 1e-9:
				# Target centre: on the line's NORMAL through the hub, at the
				# arc's own radius. That IS the tangency condition for an arc
				# touching the line at the hub, so it is solved outright rather
				# than iterated towards.
				#
				# Both normal directions satisfy it, and the choice must be made
				# by NEARNESS to where the centre already is. Choosing by the
				# sign of the current offset looks equivalent but is not: when
				# the line rotates past the centre that sign flips, the arc is
				# thrown to the far side, and the next round throws it back —
				# the centre ends up hundreds of mm away while tangency still
				# reports ~0, because every position it visits IS tangent.
				# Nearness has no such discontinuity.
				var plus := h + n * radius
				var minus := h - n * radius
				var target := plus if cc.distance_squared_to(plus) \
					<= cc.distance_squared_to(minus) else minus
				moved = maxf(moved, _move(cid, cc.lerp(target, RELAX), pos, pin))
				return moved
		moved = maxf(moved, _move(cid, cc - n * sgn * err, pos, pin))
	else:
		var free_ends: Array[String] = []
		for lid in ids:
			if not pin.has(lid):
				free_ends.append(lid)
		# Spread the correction over whichever ends may actually move, so a line
		# with one end held rotates about that end instead of translating.
		if not free_ends.is_empty():
			var share := err / float(free_ends.size())
			for lid in free_ends:
				moved = maxf(moved,
					_move(lid, (pos[lid] as Vector2) + n * sgn * share, pos, pin))
	return moved


## Is `pid` one of this arc's rim points (its start or end)? False for circles,
## which have no rim entities.
static func _arc_has_rim(sk: Sketch, circ_id: String, pid: String) -> bool:
	var arc := sk.entity(circ_id) as SketchArc
	return arc != null and (arc.start == pid or arc.end == pid)


static func _point_on(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var pid := c.operands[0]
	var target := sk.entity(c.operands[1])
	if target == null or not pos.has(pid):
		return 0.0
	var p: Vector2 = pos[pid]
	match target.kind():
		"line":
			var ids := _line_ids(sk, c.operands[1])
			var a: Vector2 = pos[ids[0]]
			var d: Vector2 = ((pos[ids[1]] as Vector2) - a).normalized()
			if d == Vector2.ZERO:
				return 0.0
			var proj := a + d * (p - a).dot(d)
			var err := proj - p
			var moved := 0.0
			if not pin.has(pid):
				moved = _move(pid, p + err * 0.5, pos, pin)
				err *= 0.5
			moved = maxf(moved, _move(ids[0], a - err * 0.5, pos, pin))
			moved = maxf(moved, _move(ids[1], (pos[ids[1]] as Vector2) - err * 0.5, pos, pin))
			return moved
		"circle", "arc":
			var cid := _center_id(sk, c.operands[1])
			var cc: Vector2 = pos[cid]
			var r := _radius_of(sk, c.operands[1], pos, rad)
			var dv := p - cc
			if dv.length() < 1e-9:
				dv = Vector2.RIGHT * 1e-6
			var err := dv.length() - r
			if absf(err) < 1e-9:
				return 0.0
			var dirv := dv.normalized()
			var moved := 0.0
			if not pin.has(pid):
				moved = _move(pid, p - dirv * err * 0.5, pos, pin)
				err *= 0.5
			if target.kind() == "circle" and not pin.has(c.operands[1]):
				rad[c.operands[1]] = r + err   # let the circle grow to meet it
				moved = maxf(moved, absf(err))
			else:
				moved = maxf(moved, _move(cid, cc + dirv * err, pos, pin))
			return moved
	return 0.0


static func _symmetry(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	var ids := _line_ids(sk, c.operands[2])
	if ids.is_empty():
		return 0.0
	var p: Vector2 = pos[c.operands[0]]
	var q: Vector2 = pos[c.operands[1]]
	var m := _reflect(p, pos[ids[0]], pos[ids[1]])
	var err := m - q
	if err.length() < 1e-12:
		return 0.0
	var w := _pair_weights(c.operands[0], c.operands[1], pin)
	var moved := 0.0
	# Move q toward the mirror of p, and p toward the mirror of q.
	moved = maxf(moved, _move(c.operands[1], q + err * w.y, pos, pin))
	var m2 := _reflect(q, pos[ids[0]], pos[ids[1]])
	moved = maxf(moved, _move(c.operands[0], p.lerp(m2, w.x), pos, pin))
	return moved


static func _distance(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	var a: Vector2 = pos[c.operands[0]]
	var b: Vector2 = pos[c.operands[1]]
	var dv := b - a
	var len := dv.length()
	if len < 1e-9:
		dv = Vector2.RIGHT * 1e-6
		len = dv.length()
	var err := len - c.value
	if absf(err) < 1e-12:
		return 0.0
	var dirv := dv / len
	var w := _pair_weights(c.operands[0], c.operands[1], pin)
	var moved := 0.0
	moved = maxf(moved, _move(c.operands[0], a + dirv * err * w.x, pos, pin))
	moved = maxf(moved, _move(c.operands[1], b - dirv * err * w.y, pos, pin))
	return moved


static func _dist_axis(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary, x_axis: bool) -> float:
	var a: Vector2 = pos[c.operands[0]]
	var b: Vector2 = pos[c.operands[1]]
	var cur := (b.x - a.x) if x_axis else (b.y - a.y)
	var target := c.value * signf(cur if cur != 0.0 else 1.0)
	var err := cur - target
	if absf(err) < 1e-12:
		return 0.0
	var w := _pair_weights(c.operands[0], c.operands[1], pin)
	var moved := 0.0
	if x_axis:
		moved = maxf(moved, _move(c.operands[0], a + Vector2(err * w.x, 0), pos, pin))
		moved = maxf(moved, _move(c.operands[1], b - Vector2(err * w.y, 0), pos, pin))
	else:
		moved = maxf(moved, _move(c.operands[0], a + Vector2(0, err * w.x), pos, pin))
		moved = maxf(moved, _move(c.operands[1], b - Vector2(0, err * w.y), pos, pin))
	return moved


static func _line_dist(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	# First make them parallel, then set the gap.
	var moved := _angle_between(sk, c.operands[0], c.operands[1], pos, pin, 0.0, true)
	var i1 := _line_ids(sk, c.operands[0])
	var i2 := _line_ids(sk, c.operands[1])
	var a: Vector2 = pos[i1[0]]
	var d: Vector2 = ((pos[i1[1]] as Vector2) - a).normalized()
	if d == Vector2.ZERO:
		return moved
	var n := Vector2(-d.y, d.x)
	var g := n.dot((pos[i2[0]] as Vector2) - a)
	var target := c.value * signf(g if g != 0.0 else 1.0)
	var err := g - target
	if absf(err) < 1e-12:
		return moved
	var m1 := not (pin.has(i1[0]) and pin.has(i1[1]))
	var m2 := not (pin.has(i2[0]) and pin.has(i2[1]))
	var s2 := (0.5 if m1 else 1.0) if m2 else 0.0
	var s1 := (0.5 if m2 else 1.0) if m1 else 0.0
	for id in i2:
		moved = maxf(moved, _move(id, (pos[id] as Vector2) - n * err * s2, pos, pin))
	for id in i1:
		moved = maxf(moved, _move(id, (pos[id] as Vector2) + n * err * s1, pos, pin))
	return moved


static func _point_line_dist(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		pin: Dictionary) -> float:
	var pid := c.operands[0]
	var ids := _line_ids(sk, c.operands[1])
	if ids.is_empty() or not pos.has(pid):
		return 0.0
	var a: Vector2 = pos[ids[0]]
	var d: Vector2 = ((pos[ids[1]] as Vector2) - a).normalized()
	if d == Vector2.ZERO:
		return 0.0
	var n := Vector2(-d.y, d.x)
	var p: Vector2 = pos[pid]
	var g := n.dot(p - a)
	var target := c.value * signf(g if g != 0.0 else 1.0)
	var err := g - target
	if absf(err) < 1e-12:
		return 0.0
	var moved := 0.0
	var p_mobile := not pin.has(pid)
	var l_mobile := not (pin.has(ids[0]) and pin.has(ids[1]))
	var sp := (0.5 if l_mobile else 1.0) if p_mobile else 0.0
	var sl := (0.5 if p_mobile else 1.0) if l_mobile else 0.0
	moved = maxf(moved, _move(pid, p - n * err * sp, pos, pin))
	for id in ids:
		moved = maxf(moved, _move(id, (pos[id] as Vector2) + n * err * sl, pos, pin))
	return moved


static func _set_radius(sk: Sketch, id: String, r: float, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var e := sk.entity(id)
	if e == null:
		return 0.0
	if e.kind() == "circle":
		if pin.has(id):
			return 0.0
		var err := absf(float(rad[id]) - r)
		rad[id] = r
		return err
	if e.kind() == "arc":
		var arc := e as SketchArc
		var cc: Vector2 = pos[arc.center]
		var moved := 0.0
		for pid: String in [arc.start, arc.end]:
			var p: Vector2 = pos[pid]
			var dv := p - cc
			if dv.length() < 1e-9:
				continue
			moved = maxf(moved, _move(pid, cc + dv.normalized() * r, pos, pin))
		return moved
	return 0.0


## Arc implicit coupling: |start-c| == |end-c| (project to the mean).
static func _project_arc_radius(sk: Sketch, arc: SketchArc, pos: Dictionary,
		pin: Dictionary, anchored := {}) -> float:
	if not (pos.has(arc.center) and pos.has(arc.start) and pos.has(arc.end)):
		return 0.0
	var cc: Vector2 = pos[arc.center]
	var rs := (pos[arc.start] as Vector2).distance_to(cc)
	var re := (pos[arc.end] as Vector2).distance_to(cc)
	if absf(rs - re) < 1e-9:
		return 0.0
	# A rim held by a COINCIDENT counts as authoritative just as a pinned one
	# does. Treating it as free lets this coupling drag it off the point it is
	# coincident with — which the Coincident projection then undoes, so the two
	# fight forever and the solve never converges.
	var sp := pin.has(arc.start) or anchored.has(arc.start)
	var ep := pin.has(arc.end) or anchored.has(arc.end)
	# The held rim point's radius is authoritative; both free (or both held ->
	# nothing to choose between them) -> meet in the middle.
	var target := rs if sp and not ep else (re if ep and not sp else (rs + re) * 0.5)
	var moved := 0.0
	for pid: String in [arc.start, arc.end]:
		# Never move a held rim to satisfy the coupling — move the other one.
		if (pid == arc.start and sp and not ep) or (pid == arc.end and ep and not sp):
			continue
		var dv := (pos[pid] as Vector2) - cc
		if dv.length() < 1e-9:
			continue
		moved = maxf(moved, _move(pid, cc + dv.normalized() * target, pos, pin))
	return moved


## --- helpers -----------------------------------------------------------------

static func _pt(sk: Sketch, id: String, pos: Dictionary) -> Vector2:
	return pos.get(id, Vector2.ZERO)


static func _line_ids(sk: Sketch, id: String) -> Array:
	var l := sk.entity(id) as SketchLine
	return [l.p0, l.p1] if l != null else []


static func _line_ends(sk: Sketch, id: String, pos: Dictionary) -> Array:
	var ids := _line_ids(sk, id)
	if ids.is_empty():
		return [Vector2.ZERO, Vector2.ZERO]
	return [pos.get(ids[0], Vector2.ZERO), pos.get(ids[1], Vector2.ZERO)]


static func _line_dir(sk: Sketch, id: String, pos: Dictionary) -> Vector2:
	var ends := _line_ends(sk, id, pos)
	return ((ends[1] as Vector2) - (ends[0] as Vector2)).normalized()


static func _center_id(sk: Sketch, id: String) -> String:
	var e := sk.entity(id)
	if e is SketchCircle:
		return (e as SketchCircle).center
	if e is SketchArc:
		return (e as SketchArc).center
	if e is SketchPoint:
		return e.id
	return ""


static func _center_of(sk: Sketch, id: String, pos: Dictionary) -> Vector2:
	return pos.get(_center_id(sk, id), Vector2.ZERO)


static func _radius_of(sk: Sketch, id: String, pos: Dictionary,
		rad: Dictionary) -> float:
	var e := sk.entity(id)
	if e is SketchCircle:
		return float(rad.get(id, (e as SketchCircle).radius))
	if e is SketchArc:
		var arc := e as SketchArc
		return (pos.get(arc.start, Vector2.ZERO) as Vector2) \
			.distance_to(pos.get(arc.center, Vector2.ZERO))
	return 0.0


## Length for lines, radius for circles/arcs (EQUAL semantics).
static func _size_of(sk: Sketch, id: String, pos: Dictionary,
		rad: Dictionary) -> float:
	var e := sk.entity(id)
	if e is SketchLine:
		var ends := _line_ends(sk, id, pos)
		return (ends[0] as Vector2).distance_to(ends[1])
	return _radius_of(sk, id, pos, rad)


static func _set_size(sk: Sketch, id: String, size: float, pos: Dictionary,
		rad: Dictionary, pin: Dictionary) -> float:
	var e := sk.entity(id)
	if e is SketchLine:
		var ids := _line_ids(sk, id)
		var a: Vector2 = pos[ids[0]]
		var b: Vector2 = pos[ids[1]]
		var dv := b - a
		if dv.length() < 1e-9:
			return 0.0
		var err := dv.length() - size
		if absf(err) < 1e-12:
			return 0.0
		var dirv := dv.normalized()
		var w := _pair_weights(ids[0], ids[1], pin)
		var moved := 0.0
		moved = maxf(moved, _move(ids[0], a + dirv * err * w.x, pos, pin))
		moved = maxf(moved, _move(ids[1], b - dirv * err * w.y, pos, pin))
		return moved
	return _set_radius(sk, id, size, pos, rad, pin)


static func _tangent_error(sk: Sketch, c: SketchConstraint, pos: Dictionary,
		rad: Dictionary) -> float:
	var a := sk.entity(c.operands[0])
	var b := sk.entity(c.operands[1])
	if a == null or b == null:
		return 0.0
	var line_id := ""
	var circ_id := ""
	if a.kind() == "line":
		line_id = c.operands[0]
		circ_id = c.operands[1]
	elif b.kind() == "line":
		line_id = c.operands[1]
		circ_id = c.operands[0]
	if line_id != "":
		var ends := _line_ends(sk, line_id, pos)
		var d := ((ends[1] as Vector2) - (ends[0] as Vector2)).normalized()
		var n := Vector2(-d.y, d.x)
		var cc := _center_of(sk, circ_id, pos)
		return absf(n.dot(cc - (ends[0] as Vector2))) \
			- _radius_of(sk, circ_id, pos, rad)
	var c1 := _center_of(sk, c.operands[0], pos)
	var c2 := _center_of(sk, c.operands[1], pos)
	var r1 := _radius_of(sk, c.operands[0], pos, rad)
	var r2 := _radius_of(sk, c.operands[1], pos, rad)
	var dist := c1.distance_to(c2)
	return minf(absf(dist - (r1 + r2)), absf(dist - absf(r1 - r2)))


static func _reflect(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var d := (b - a).normalized()
	if d == Vector2.ZERO:
		return p
	var v := p - a
	return a + d * v.dot(d) * 2.0 - v


## Point ids for a 1-operand (line) or 2-operand (point, point) H/V.
static func _operand_point_ids(sk: Sketch, c: SketchConstraint) -> Array:
	if c.operands.size() == 1:
		return _line_ids(sk, c.operands[0])
	return [c.operands[0], c.operands[1]]
