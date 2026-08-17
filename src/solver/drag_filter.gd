class_name DragFilter
extends RefCounted
## Per-DOF drag projection (M17). A drag may only change the degrees of
## freedom that remain at the dragged geometry: the requested motion is
## PROJECTED onto the directions the constraints leave open, so constrained
## geometry slides on rails instead of yanking geometry the user never
## touched (M6's whole-point refusal could not express "this point may
## translate but its line's rotation is fixed").
##
## Semantics: the dragged points (plus their COINCIDENT welds) move; every
## OTHER point is held. The feasible motions are the nullspace of the
## constraint Jacobian restricted to the dragged columns — computed with the
## same central-difference rows DofAnalyzer uses. When that leaves NO point
## motion at all (a rect corner: H and V lock both axes against held
## neighbours), the column set grows outward ring by ring through shared
## entities, which is exactly Fusion's corner drag: the corner moves and its
## edge partners slide along their own free axes. If growth exhausts the
## sketch without freeing anything, the drag is refused with a reason.

const RANK_TOL := 1e-7
const FREE_TOL := 1e-6
## Differentiation step for the drag Jacobian (mm). DELIBERATELY much larger
## than DofAnalyzer.EPS: residuals are computed in float32 Vector2 math, so a
## 1e-4 step leaves ~1% noise on the derivative — harmless for rank tests,
## but here the row DIRECTIONS are the rails the drag slides on, and 1% of
## direction noise per substep reads as visible drift. 0.01 mm keeps the
## noise below ~0.02% while staying far under geometry scale.
const EPS := 0.01
## Rings of neighbour expansion before giving up (each ring is one entity hop).
const EXPAND_MAX := 12


## Plan a drag. `drag_pids` are the gesture's points; `desired` maps each of
## them to the motion the cursor asks for (mm). Held points are everything
## outside the (possibly expanded) column set.
## -> {"allowed": bool, "restricted": bool, "moves": {pid: Vector2}}
##    allowed    — false: nothing may move (fully held); show why.
##    restricted — true: the applied motion differs from the request
##                 (sliding on rails); worth a status hint.
##    moves      — per-point motion to apply THIS update (may include
##                 neighbour points that must slide along).
static func plan(sk: Sketch, drag_pids: Array, desired: Dictionary) -> Dictionary:
	var held_always := _immovable_points(sk)
	var group := _coincident_closure(sk, drag_pids)
	for pid: String in group:
		if held_always.has(pid):
			return {"allowed": false, "restricted": true, "moves": {}}
	var desired_len := 0.0
	for pid: String in desired:
		desired_len += (desired[pid] as Vector2).length_squared()
	desired_len = sqrt(desired_len)
	if desired_len < 1e-12:
		return {"allowed": true, "restricted": false, "moves": {}}

	var cols := {}
	for pid: String in group:
		cols[pid] = true
	var live := DofAnalyzer._state(sk)
	for ring in EXPAND_MAX:
		var out := _project(sk, cols, desired, live)
		if bool(out["point_freedom"]):
			var moves := _polish(sk, cols, _substepped(sk, cols, desired, live))
			var moved_len := 0.0
			for pid: String in moves:
				moved_len += (moves[pid] as Vector2).length_squared()
			moved_len = sqrt(moved_len)
			return {"allowed": true,
				"restricted": moved_len < desired_len * 0.999,
				"moves": moves}
		if not _expand(sk, cols, held_always):
			break
	return {"allowed": false, "restricted": true, "moves": {}}


## Maximum sub-step length (mm). One linearized projection is only tangent to
## curved rails; walking the request in short re-linearized steps keeps the
## motion ON the rail (a point sliding on a circle stays on the circle, a
## parallel pair accumulates no angle drift over a long drag).
const SUBSTEP_MM := 1.0
const SUBSTEP_MAX := 40


## Walk `desired` in short projected steps, re-linearizing the Jacobian on a
## PRIVATE copy of the state each time. Returns net per-point moves.
static func _substepped(sk: Sketch, cols: Dictionary, desired: Dictionary,
		live: Dictionary) -> Dictionary:
	var pos0: Dictionary = (live["pos"] as Dictionary)
	var state := {"pos": pos0.duplicate(), "rad": (live["rad"] as Dictionary).duplicate()}
	# Absolute targets for the dragged points; "remaining" is recomputed from
	# the walked state each step, so nothing decays away in float dust.
	var tgt := {}
	for pid: String in desired:
		tgt[pid] = (pos0[pid] as Vector2) + (desired[pid] as Vector2)
	for step in SUBSTEP_MAX:
		var spos: Dictionary = state["pos"]
		var rem_len := 0.0
		var remaining := {}
		for pid: String in tgt:
			var r := (tgt[pid] as Vector2) - (spos[pid] as Vector2)
			remaining[pid] = r
			rem_len = maxf(rem_len, r.length())
		if rem_len < 1e-6:
			break
		var scale := minf(1.0, SUBSTEP_MM / rem_len)
		var want := {}
		for pid: String in remaining:
			want[pid] = (remaining[pid] as Vector2) * scale
		var out := _project(sk, cols, want, state)
		var moves: Dictionary = out["moves"]
		var advanced := 0.0
		for pid: String in moves:
			spos[pid] = (spos[pid] as Vector2) + (moves[pid] as Vector2)
			advanced = maxf(advanced, (moves[pid] as Vector2).length())
		if advanced < rem_len * scale * 1e-3:
			break   # rail is perpendicular to the request — sticking
	var net := {}
	var spos_final: Dictionary = state["pos"]
	for pid: String in cols:
		if not pos0.has(pid):
			continue
		var v := (spos_final[pid] as Vector2) - (pos0[pid] as Vector2)
		if v.length() > 1e-9:
			net[pid] = v
	return net


## Points that may never move: the origin, FIX operands, projected geometry.
static func _immovable_points(sk: Sketch) -> Dictionary:
	var held := {}
	if sk.origin_id() != "":
		held[sk.origin_id()] = true
	for e in sk.entities():
		if e.is_projected() and e.kind() == "point":
			held[e.id] = true
	for c in sk.constraints:
		if c.type != SketchConstraint.Type.FIX:
			continue
		for op in c.operands:
			var e := sk.entity(op)
			if e == null:
				continue
			if e.kind() == "point":
				held[e.id] = true
			for pid in e.point_refs():
				held[pid] = true
	return held


## The drag group: the picked points plus everything welded to them through
## chains of COINCIDENT constraints — a welded pair is one point in spirit.
static func _coincident_closure(sk: Sketch, pids: Array) -> Dictionary:
	var group := {}
	var queue: Array = []
	for pid in pids:
		group[String(pid)] = true
		queue.append(String(pid))
	while not queue.is_empty():
		var pid: String = queue.pop_back()
		for c in sk.constraints:
			if c.type != SketchConstraint.Type.COINCIDENT:
				continue
			if not c.references(pid):
				continue
			for op in c.operands:
				var e := sk.entity(op)
				if e != null and e.kind() == "point" and not group.has(op):
					group[op] = true
					queue.append(op)
	return group


## Grow `cols` by one entity hop: every point sharing an entity with a column
## point joins (plus its own coincident welds). Returns false when nothing new.
static func _expand(sk: Sketch, cols: Dictionary, held: Dictionary) -> bool:
	var add := {}
	for e in sk.entities():
		if e.kind() == "point":
			continue
		var touches := false
		for pid in e.point_refs():
			if cols.has(pid):
				touches = true
		if not touches:
			continue
		for pid in e.point_refs():
			if not cols.has(pid) and not held.has(pid):
				add[pid] = true
	if add.is_empty():
		return false
	var welded := _coincident_closure(sk, add.keys())
	var grew := false
	for pid: String in welded:
		if not cols.has(pid) and not held.has(pid):
			cols[pid] = true
			grew = true
	return grew


## Project `desired` onto the nullspace of the Jacobian restricted to `cols`.
## -> {"moves": {pid: Vector2}, "point_freedom": bool}
static func _project(sk: Sketch, cols: Dictionary, desired: Dictionary,
		live: Dictionary) -> Dictionary:
	# Column layout: px/py per column point, then a free radius column for
	# every circle whose center is in the set (its radius may absorb motion).
	var columns: Array = []
	var order: Array = []
	for e in sk.entities():
		if e.kind() == "point" and cols.has(e.id):
			columns.append({"kind": "px", "id": e.id})
			columns.append({"kind": "py", "id": e.id})
			order.append(e.id)
	# Radius columns AFTER all point columns — `moves` reads point pairs by
	# index below, so the layout must keep points contiguous.
	for e in sk.entities():
		if e.kind() == "circle" and cols.has((e as SketchCircle).center):
			columns.append({"kind": "r", "id": e.id})

	# Rows: every live constraint touching a column variable, plus the
	# implicit |c-s| == |c-e| coupling of arcs touching one.
	var pivots: Array = []
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.FIX or c.driven:
			continue
		if not _touches(sk, c, cols):
			continue
		var base := ConstraintSolver.residuals(sk, c, live["pos"], live["rad"])
		for ri in base.size():
			var row := _jacobian_row(sk, c, ri, columns, live)
			for p: PackedFloat64Array in pivots:
				row = DofAnalyzer._eliminate(row, p)
			if DofAnalyzer._norm(row) > RANK_TOL:
				pivots.append(DofAnalyzer._normalize(row))
	for e in sk.entities():
		if e.kind() != "arc":
			continue
		var arc := e as SketchArc
		if not (cols.has(arc.center) or cols.has(arc.start) or cols.has(arc.end)):
			continue
		var row := _arc_row(arc, columns, live)
		for p: PackedFloat64Array in pivots:
			row = DofAnalyzer._eliminate(row, p)
		if DofAnalyzer._norm(row) > RANK_TOL:
			pivots.append(DofAnalyzer._normalize(row))

	# Any point coordinate with freedom left? (Radius columns do not count —
	# a free radius alone cannot carry a drag.)
	var point_freedom := false
	for col in columns.size():
		var spec: Dictionary = columns[col]
		if String(spec["kind"]) == "r":
			continue
		var e_col := PackedFloat64Array()
		e_col.resize(columns.size())
		e_col[col] = 1.0
		for p: PackedFloat64Array in pivots:
			e_col = DofAnalyzer._eliminate(e_col, p)
		if DofAnalyzer._norm(e_col) > FREE_TOL:
			point_freedom = true
			break

	# Desired motion, projected into the nullspace: subtracting the row-space
	# component (the pivots are orthonormal) leaves the feasible part.
	var d := PackedFloat64Array()
	d.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var pid: String = spec["id"]
		if desired.has(pid):
			var want: Vector2 = desired[pid]
			d[col] = want.x if String(spec["kind"]) == "px" \
				else (want.y if String(spec["kind"]) == "py" else 0.0)
	for p: PackedFloat64Array in pivots:
		d = DofAnalyzer._eliminate(d, p)

	var moves := {}
	for i in order.size():
		var v := Vector2(d[i * 2], d[i * 2 + 1])
		if v.length() > 1e-9:
			moves[order[i]] = v
	return {"moves": moves, "point_freedom": point_freedom}


## Newton-polish of the walked motion. Each substep is first-order, so a
## long slide on a CURVED rail (a point riding a circle under POINT_ON)
## lands a hair off the constraint manifold — enough to trip the conflict
## badge's violation tolerance and read as "invalid constraint" mid-drag.
## Solving a CLONE with everything except the walkers pinned lets the damped
## solver pull exactly the walked points back onto their constraints; with
## the state already near-satisfied this converges in a round or two.
static func _polish(sk: Sketch, cols: Dictionary, moves: Dictionary) -> Dictionary:
	if moves.is_empty():
		return moves
	var clone := Sketch.from_dict(sk.to_dict())
	for pid: String in moves:
		clone.point(pid).pos += moves[pid] as Vector2
	var pinned: Array = []
	var pin_radii: Array = []
	for e in clone.entities():
		if e.kind() == "point" and not cols.has(e.id):
			pinned.append(e.id)
		elif e.kind() == "circle" and not cols.has((e as SketchCircle).center):
			# An untouched circle's radius is not the correction's to spend:
			# without this a POINT_ON polish "fixes" the rider by growing
			# the circle instead of projecting the rider onto it.
			pin_radii.append(e.id)
	var res := ConstraintSolver.solve(clone, pinned, pin_radii, 1e-5)
	if bool(res.get("diverged", false)):
		return moves
	var out := moves.duplicate()
	for pid: String in res["points"]:
		if cols.has(pid):
			out[pid] = (res["points"][pid] as Vector2) - sk.point(pid).pos
	return out


## Central-difference Jacobian row over `columns` — DofAnalyzer's shape with
## this class's larger EPS (see the constant for why).
static func _jacobian_row(sk: Sketch, c: SketchConstraint, ri: int,
		columns: Array, live: Dictionary) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var plus := DofAnalyzer._perturbed(live, spec, EPS)
		var minus := DofAnalyzer._perturbed(live, spec, -EPS)
		var rp := ConstraintSolver.residuals(sk, c, plus["pos"], plus["rad"])
		var rm := ConstraintSolver.residuals(sk, c, minus["pos"], minus["rad"])
		if ri < rp.size() and ri < rm.size():
			row[col] = (float(rp[ri]) - float(rm[ri])) / (2.0 * EPS)
	return DofAnalyzer._normalize(row)


static func _arc_row(arc: SketchArc, columns: Array,
		live: Dictionary) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(columns.size())
	for col in columns.size():
		var spec: Dictionary = columns[col]
		var plus := DofAnalyzer._perturbed(live, spec, EPS)
		var minus := DofAnalyzer._perturbed(live, spec, -EPS)
		row[col] = (DofAnalyzer._arc_residual(arc, plus["pos"])
			- DofAnalyzer._arc_residual(arc, minus["pos"])) / (2.0 * EPS)
	return DofAnalyzer._normalize(row)


## Does this constraint's residual depend on any column variable?
static func _touches(sk: Sketch, c: SketchConstraint, cols: Dictionary) -> bool:
	for op in c.operands:
		if cols.has(op):
			return true
		var e := sk.entity(op)
		if e == null:
			continue
		if e.kind() == "circle" and cols.has((e as SketchCircle).center):
			return true
		for pid in e.point_refs():
			if cols.has(pid):
				return true
	return false
