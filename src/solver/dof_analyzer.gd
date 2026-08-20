class_name DofAnalyzer
extends RefCounted
## Degrees-of-freedom analysis (echo_vector's approach): build a Jacobian of
## every constraint residual by CENTRAL DIFFERENCES over the solver
## variables (no hand-derived gradients to get wrong), unit-normalize rows,
## Gaussian-eliminate in document order. rank = independent constraint rows;
## dof = variables - rank. A row eliminated to ~zero is REDUNDANT; a
## redundant row whose residual is also violated is a CONFLICT
## (unsatisfiable). FIX pins variables directly (removes them).
##
## Static + pure; used by the status readout, constraint UI, and RPC
## query.dof.

## Differentiation step: RELATIVE to the coordinate's magnitude (floored at
## EPS_MIN mm). Positions are float32 Vector2s, so a fixed 1e-4 mm step on a
## 30 mm coordinate left ~1e-3 of pure rounding noise in every non-linear
## row — dependent rows then passed a 1e-7 rank test as "independent", and
## redundancy got blamed on whichever row happened to be exactly linear (a
## dimension to a pinned origin axis) instead of the real duplicate.
const EPS_REL := 1e-3
const EPS_MIN := 1e-3
## Rows are unit vectors; a truly dependent row leaves only differentiation
## noise (~1e-5..1e-4 with the relative step). Near-singular but independent
## configurations land below this too — the jitter pass below un-flags them.
const RANK_TOL := 1e-3
const VIOLATION_TOL := 0.001   # mm
const MAX_CONSTRAINTS := 400   # bail-out for pathological documents


## -> { vars: int, rank: int, dof: int, fully_constrained: bool,
##      redundant: Array[int]  (indices into sketch.constraints),
##      conflicts: Array[int], analyzed: bool }
## Which constraint a residual row is blamed on: its own index, or -1 for an
## IMPLICIT coupling that must never be reported as a user redundancy. A gap
## dimension (LINE_DIST) carries a second "stay parallel" residual so the
## distance is well-defined; dimensioning between lines the user already made
## parallel (two VERTICALs, or a line and a pinned origin axis) is the normal
## case, not an over-constraint — it still counts toward rank, like an arc's
## implicit radius coupling, but is not a source of redundancy/conflict.
static func _row_source(c: SketchConstraint, ri: int, ci: int) -> int:
	if c.type == SketchConstraint.Type.LINE_DIST and ri == 1:
		return -1
	return ci


static func analyze(sk: Sketch) -> Dictionary:
	if sk.constraints.size() > MAX_CONSTRAINTS:
		return {"analyzed": false, "vars": 0, "rank": 0, "dof": 0,
			"fully_constrained": false, "redundant": [], "conflicts": []}

	# Variable layout: fixed point ids removed entirely.
	var fixed := {}
	# The origin is a datum, not a free variable — the solver pins it, so it
	# must not contribute 2 DOF here either, or a fully-dimensioned sketch
	# would never report "fully constrained".
	if sk.origin_id() != "":
		fixed[sk.origin_id()] = true
	# Projected geometry is determined by its SOURCE sketch — its points (and
	# a projected circle's radius) contribute no free variables here.
	for e in sk.entities():
		if e.is_projected() and (e.kind() == "point" or e.kind() == "circle"):
			fixed[e.id] = true
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.FIX:
			for op in c.operands:
				var e := sk.entity(op)
				if e == null:
					continue
				if e.kind() == "point":
					fixed[e.id] = true
				for pid in e.point_refs():
					fixed[pid] = true

	var var_index := {}        # "p:<id>:x" etc -> column
	var columns: Array = []    # [{kind: "px"/"py"/"r", id}]
	for e in sk.entities():
		if e.kind() == "point" and not fixed.has(e.id):
			var_index["px:" + e.id] = columns.size()
			columns.append({"kind": "px", "id": e.id})
			var_index["py:" + e.id] = columns.size()
			columns.append({"kind": "py", "id": e.id})
		elif e.kind() == "circle" and not fixed.has(e.id):
			var_index["r:" + e.id] = columns.size()
			columns.append({"kind": "r", "id": e.id})
	var nvars := columns.size()

	# Rows: per-constraint residuals + arc implicit couplings.
	var rows: Array = []            # each: {vec: PackedFloat64Array, src: int}
	var live := _state(sk)
	var row_sources: Array = []     # constraint index or -1 (arc implicit)
	var violations := {}            # constraint index -> violated?
	var ci := 0
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.FIX or c.driven:
			ci += 1
			continue
		var base := ConstraintSolver.residuals(sk, c, live["pos"], live["rad"])
		var violated := false
		for r in base:
			if absf(float(r)) > VIOLATION_TOL:
				violated = true
		violations[ci] = violated
		for ri in base.size():
			rows.append(_jacobian_row(sk, c, ri, columns, live))
			row_sources.append(_row_source(c, ri, ci))
		ci += 1
	for e in sk.entities():
		if e.kind() == "arc":
			var arc := e as SketchArc
			rows.append(_arc_row(sk, arc, columns, live))
			row_sources.append(-1)

	# Gaussian elimination in document order.
	var rank := 0
	var pivots: Array = []          # surviving row vectors
	var redundant: Array = []
	var conflicts: Array = []
	for i in rows.size():
		var v: PackedFloat64Array = rows[i]
		for p: PackedFloat64Array in pivots:
			v = _eliminate(v, p)
		if _norm(v) > RANK_TOL:
			pivots.append(_normalize(v))
			rank += 1
		elif row_sources[i] >= 0:
			var src: int = row_sources[i]
			if not redundant.has(src):
				redundant.append(src)

	# A redundancy read at a SINGULAR configuration is a false alarm: at an
	# exact tangency the tangent and point-on gradients align, and the rank
	# test cannot tell "dependent everywhere" from "degenerate right here" —
	# which painted amber badges on perfectly sound constraints (QA §M19.6).
	# Confirm each flagged constraint at a jittered state: a real duplicate
	# stays dependent under any state, a configuration accident does not.
	if not redundant.is_empty():
		var jit := _state(sk)
		var jpos: Dictionary = jit["pos"]
		# Golden-angle per-point directions: every point jitters a DIFFERENT
		# way. A shared direction is a rigid translation, which every
		# constraint is invariant under — it would leave the degeneracy
		# perfectly intact and confirm the false alarm.
		var ji := 0
		for id: String in jpos:
			ji += 1
			if fixed.has(id):
				continue
			var h := float(ji) * 2.39996
			jpos[id] = (jpos[id] as Vector2) \
				+ Vector2(cos(h), sin(h)) * (0.31 + 0.11 * float(ji % 3))
		var jrad: Dictionary = jit["rad"]
		for id: String in jrad:
			ji += 1
			if not fixed.has(id):
				jrad[id] = float(jrad[id]) + 0.17 + 0.09 * float(ji % 3)
		var jrows: Array = []
		var jsources: Array = []
		var cj := 0
		for c in sk.constraints:
			if c.type == SketchConstraint.Type.FIX or c.driven:
				cj += 1
				continue
			var jbase := ConstraintSolver.residuals(sk, c, jpos, jrad)
			for ri in jbase.size():
				jrows.append(_jacobian_row(sk, c, ri, columns, jit))
				jsources.append(_row_source(c, ri, cj))
			cj += 1
		for e in sk.entities():
			if e.kind() == "arc":
				jrows.append(_arc_row(sk, e as SketchArc, columns, jit))
				jsources.append(-1)
		var jpivots: Array = []
		var jredundant := {}
		for i in jrows.size():
			var jv: PackedFloat64Array = jrows[i]
			for jp: PackedFloat64Array in jpivots:
				jv = _eliminate(jv, jp)
			if _norm(jv) > RANK_TOL:
				jpivots.append(_normalize(jv))
			elif jsources[i] >= 0:
				jredundant[jsources[i]] = true
		var confirmed: Array = []
		for src: int in redundant:
			if jredundant.has(src):
				confirmed.append(src)
		redundant = confirmed

	# Conflicts: an over-determined system (some row redundant) where any
	# constraint is left violated is unsatisfiable. The solver satisfies
	# whichever duplicate it visited last, so the VIOLATED one may not be
	# the redundant one — flag every violated constraint in that case.
	if not redundant.is_empty():
		for src: int in violations:
			if violations[src] and not conflicts.has(src):
				conflicts.append(src)

	# Per-variable constrained-ness: a variable is determined when its basis
	# vector lies in the row space (pivots are orthonormal — residual test).
	var determined := {}
	for col in nvars:
		var e_col := PackedFloat64Array()
		e_col.resize(nvars)
		e_col[col] = 1.0
		for p: PackedFloat64Array in pivots:
			e_col = _eliminate(e_col, p)
		if _norm(e_col) < 1e-6:
			determined[col] = true
	var constrained_points: Array = []
	var constrained_circles: Array = []
	var seen := {}
	for col in nvars:
		var spec: Dictionary = columns[col]
		var id: String = spec["id"]
		if seen.has(id):
			continue
		match String(spec["kind"]):
			"px":
				seen[id] = true
				if determined.has(col) and determined.has(col + 1):
					constrained_points.append(id)
			"r":
				seen[id] = true
				if determined.has(col):
					constrained_circles.append(id)
	# FIXed entities are constrained by definition (their vars were removed).
	for id: String in fixed:
		var fe := sk.entity(id)
		if fe != null and fe.kind() == "circle":
			if not constrained_circles.has(id):
				constrained_circles.append(id)
		elif not constrained_points.has(id):
			constrained_points.append(id)

	var dof := nvars - rank
	return {"analyzed": true, "vars": nvars, "rank": rank, "dof": dof,
		"fully_constrained": dof == 0 and (nvars > 0 or not fixed.is_empty()),
		"redundant": redundant, "conflicts": conflicts,
		"constrained_points": constrained_points,
		"constrained_circles": constrained_circles}


static func summary(sk: Sketch) -> String:
	var a := analyze(sk)
	if not a["analyzed"]:
		return "Sketch too large to analyze"
	if not (a["conflicts"] as Array).is_empty():
		return "Conflicting constraints"
	if a["fully_constrained"]:
		return "Fully constrained"
	return "%d DOF remaining" % int(a["dof"])


static func _state(sk: Sketch) -> Dictionary:
	var pos := {}
	var rad := {}
	for e in sk.entities():
		if e.kind() == "point":
			pos[e.id] = (e as SketchPoint).pos
		elif e.kind() == "circle":
			rad[e.id] = (e as SketchCircle).radius
	return {"pos": pos, "rad": rad}


static func _jacobian_row(sk: Sketch, c: SketchConstraint, ri: int,
		columns: Array, live: Dictionary) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var eps := _step(live, spec)
		var plus := _perturbed(live, spec, eps)
		var minus := _perturbed(live, spec, -eps)
		var rp := ConstraintSolver.residuals(sk, c, plus["pos"], plus["rad"])
		var rm := ConstraintSolver.residuals(sk, c, minus["pos"], minus["rad"])
		if ri < rp.size() and ri < rm.size():
			row[col] = (float(rp[ri]) - float(rm[ri])) / (2.0 * eps)
	return _normalize(row)


static func _arc_row(sk: Sketch, arc: SketchArc, columns: Array,
		live: Dictionary) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var eps := _step(live, spec)
		var plus := _perturbed(live, spec, eps)
		var minus := _perturbed(live, spec, -eps)
		row[col] = (_arc_residual(arc, plus["pos"])
			- _arc_residual(arc, minus["pos"])) / (2.0 * eps)
	return _normalize(row)


static func _arc_residual(arc: SketchArc, pos: Dictionary) -> float:
	var cc: Vector2 = pos.get(arc.center, Vector2.ZERO)
	return (pos.get(arc.start, Vector2.ZERO) as Vector2).distance_to(cc) \
		- (pos.get(arc.end, Vector2.ZERO) as Vector2).distance_to(cc)


## Finite-difference step for one variable, scaled to its magnitude so float32
## rounding stays a fixed fraction of the step whatever the sketch's extent.
static func _step(live: Dictionary, spec: Dictionary) -> float:
	var id: String = spec["id"]
	var mag := 0.0
	match String(spec["kind"]):
		"px":
			mag = absf(((live["pos"] as Dictionary)[id] as Vector2).x)
		"py":
			mag = absf(((live["pos"] as Dictionary)[id] as Vector2).y)
		"r":
			mag = absf(float((live["rad"] as Dictionary)[id]))
	return maxf(EPS_MIN, mag * EPS_REL)


static func _perturbed(live: Dictionary, spec: Dictionary, by: float) -> Dictionary:
	var pos: Dictionary = (live["pos"] as Dictionary).duplicate()
	var rad: Dictionary = (live["rad"] as Dictionary).duplicate()
	var id: String = spec["id"]
	match String(spec["kind"]):
		"px":
			pos[id] = (pos[id] as Vector2) + Vector2(by, 0)
		"py":
			pos[id] = (pos[id] as Vector2) + Vector2(0, by)
		"r":
			rad[id] = float(rad[id]) + by
	return {"pos": pos, "rad": rad}


static func _norm(v: PackedFloat64Array) -> float:
	var s := 0.0
	for x in v:
		s += x * x
	return sqrt(s)


static func _normalize(v: PackedFloat64Array) -> PackedFloat64Array:
	var n := _norm(v)
	if n < 1e-12:
		return v
	var out := PackedFloat64Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = v[i] / n
	return out


static func _eliminate(v: PackedFloat64Array, unit_pivot: PackedFloat64Array) -> PackedFloat64Array:
	var dot := 0.0
	for i in v.size():
		dot += v[i] * unit_pivot[i]
	if absf(dot) < 1e-15:
		return v
	var out := PackedFloat64Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = v[i] - dot * unit_pivot[i]
	return out
