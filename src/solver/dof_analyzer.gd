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

const EPS := 1e-4              # differentiation step (mm)
const RANK_TOL := 1e-7
const VIOLATION_TOL := 0.001   # mm
const MAX_CONSTRAINTS := 400   # bail-out for pathological documents


## -> { vars: int, rank: int, dof: int, fully_constrained: bool,
##      redundant: Array[int]  (indices into sketch.constraints),
##      conflicts: Array[int], analyzed: bool }
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
			row_sources.append(ci)
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
		if not constrained_points.has(id):
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
		var plus := _perturbed(live, spec, EPS)
		var minus := _perturbed(live, spec, -EPS)
		var rp := ConstraintSolver.residuals(sk, c, plus["pos"], plus["rad"])
		var rm := ConstraintSolver.residuals(sk, c, minus["pos"], minus["rad"])
		if ri < rp.size() and ri < rm.size():
			row[col] = (float(rp[ri]) - float(rm[ri])) / (2.0 * EPS)
	return _normalize(row)


static func _arc_row(sk: Sketch, arc: SketchArc, columns: Array,
		live: Dictionary) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var plus := _perturbed(live, spec, EPS)
		var minus := _perturbed(live, spec, -EPS)
		row[col] = (_arc_residual(arc, plus["pos"])
			- _arc_residual(arc, minus["pos"])) / (2.0 * EPS)
	return _normalize(row)


static func _arc_residual(arc: SketchArc, pos: Dictionary) -> float:
	var cc: Vector2 = pos.get(arc.center, Vector2.ZERO)
	return (pos.get(arc.start, Vector2.ZERO) as Vector2).distance_to(cc) \
		- (pos.get(arc.end, Vector2.ZERO) as Vector2).distance_to(cc)


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
