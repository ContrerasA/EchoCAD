class_name ConstraintRules
extends RefCounted
## Which entity selections can take which constraint — the one validation
## table shared by the toolbar, RPC action.add_constraint, and (later) the
## context menu. Operand order normalization also lives here (e.g. SYMMETRY
## wants the axis LAST, POINT_ON wants the point first).


## Signature: sorted list of selected entity kinds -> allowed?
## `sel` — Array of SketchEntity. Returns "" when valid, else the reason.
static func validate(sk: Sketch, type: SketchConstraint.Type, sel: Array) -> String:
	var kinds: Array = []
	for e: SketchEntity in sel:
		kinds.append(e.kind())
	var T := SketchConstraint.Type
	match type:
		T.COINCIDENT, T.DISTANCE, T.DIST_X, T.DIST_Y:
			if kinds == ["point", "point"]:
				return ""
			return "needs two points"
		T.HORIZONTAL, T.VERTICAL:
			if kinds == ["line"] or kinds == ["point", "point"]:
				return ""
			return "needs a line or two points"
		T.PARALLEL, T.PERPENDICULAR, T.COLLINEAR, T.ANGLE, T.LINE_DIST:
			if kinds == ["line", "line"]:
				return ""
			return "needs two lines"
		T.EQUAL:
			if kinds.size() == 2 and not kinds.has("point"):
				if (kinds[0] == "line") == (kinds[1] == "line"):
					return ""
				return "cannot equate a length with a radius"
			return "needs two curves"
		T.MIDPOINT:
			if kinds == ["line", "point"] or kinds == ["point", "line"]:
				return ""
			return "needs a point and a line"
		T.CONCENTRIC:
			if kinds.size() == 2 and not kinds.has("point") and not kinds.has("line"):
				return ""
			return "needs two circles/arcs"
		T.TANGENT:
			if kinds.size() != 2:
				return "needs two curves"
			var circles := 0
			for k in kinds:
				if k == "circle" or k == "arc":
					circles += 1
			if circles == 2 or (circles == 1 and kinds.has("line")):
				return ""
			return "needs a line and a circle/arc, or two circles/arcs"
		T.POINT_ON:
			if kinds.size() == 2 and kinds.has("point") and not (kinds[0] == "point" and kinds[1] == "point"):
				return ""
			return "needs a point and a curve"
		T.FIX:
			if sel.size() == 1:
				return ""
			return "needs one entity"
		T.SYMMETRY:
			if kinds.size() == 3 and kinds.count("point") >= 2 and kinds.count("line") == 1:
				return ""
			return "needs two points and an axis line"
		T.RADIUS, T.DIAMETER:
			if kinds.size() == 1 and (kinds[0] == "circle" or kinds[0] == "arc"):
				return ""
			return "needs a circle or arc"
		T.POINT_LINE_DIST:
			if kinds.size() == 2 and kinds.has("point") and kinds.has("line"):
				return ""
			return "needs a point and a line"
	return "unsupported"


## Normalized operand id list for a validated selection.
static func operands(type: SketchConstraint.Type, sel: Array) -> Array[String]:
	var out: Array[String] = []
	var T := SketchConstraint.Type
	match type:
		T.MIDPOINT, T.POINT_ON, T.POINT_LINE_DIST:
			# Point first.
			for e: SketchEntity in sel:
				if e.kind() == "point":
					out.append(e.id)
			for e: SketchEntity in sel:
				if e.kind() != "point":
					out.append(e.id)
		T.SYMMETRY:
			# Axis line last.
			for e: SketchEntity in sel:
				if e.kind() == "point":
					out.append(e.id)
			for e: SketchEntity in sel:
				if e.kind() == "line":
					out.append(e.id)
		T.TANGENT:
			# Line first when present (solver convention is flexible, but
			# keep it deterministic).
			for e: SketchEntity in sel:
				if e.kind() == "line":
					out.append(e.id)
			for e: SketchEntity in sel:
				if e.kind() != "line":
					out.append(e.id)
		_:
			for e: SketchEntity in sel:
				out.append(e.id)
	return out


## Default value for a dimensional constraint = its current measurement.
static func measured_value(sk: Sketch, type: SketchConstraint.Type,
		ops: Array[String]) -> float:
	var c := SketchConstraint.make(type, ops, 0.0)
	var pos := {}
	var rad := {}
	for e in sk.entities():
		if e.kind() == "point":
			pos[e.id] = (e as SketchPoint).pos
		elif e.kind() == "circle":
			rad[e.id] = (e as SketchCircle).radius
	var res := ConstraintSolver.residuals(sk, c, pos, rad)
	# residual = measured - value, and value was 0 -> residual IS measured.
	if res.is_empty():
		return 0.0
	var v := float(res[0])
	if type == SketchConstraint.Type.ANGLE:
		return rad_to_deg(v)
	if type == SketchConstraint.Type.DIAMETER:
		return v * 2.0
	return v
