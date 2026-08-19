class_name PatternLib
extends RefCounted
## M29: shared copy machinery for the sketch pattern tools (and anything
## else that stamps transformed duplicates). Duplicates a set of entities
## under a Transform2D, remapping point references, and clones the source's
## INTERNAL constraints (operands fully inside the copied set) so each
## instance keeps its shape. Fusion-lite, like the M19 offset: dimensional
## constraints and FIX are not cloned — the copy borrows its proportions
## from its own geometric constraints and keeps some freedom.


## ids: entity ids to copy (points are pulled in via point_refs anyway).
## Returns {"entities": [...], "cons": [...]} with fresh ids, positioned by
## `xf`. Splines carry their handle overrides through the linear part.
static func duplicate_transformed(sk: Sketch, ids: Array,
		xf: Transform2D) -> Dictionary:
	var picked := {}
	for id in ids:
		var e := sk.entity(String(id))
		if e == null or sk.is_origin(String(id)):
			continue
		picked[e.id] = e
		for pid in e.point_refs():
			var p := sk.point(pid)
			if p != null and not sk.is_origin(pid):
				picked[pid] = p

	var out_entities: Array = []
	var map := {}       # old id -> new id
	# Points first so curves can reference the new ids.
	for id in picked:
		var e: SketchEntity = picked[id]
		if e.kind() != "point":
			continue
		var np := SketchPoint.make(xf * (e as SketchPoint).pos)
		np.id = sk.next_id()
		np.construction = e.construction
		map[id] = np.id
		out_entities.append(np)
	for id in picked:
		var e: SketchEntity = picked[id]
		var ne: SketchEntity = null
		match e.kind():
			"line":
				var l := e as SketchLine
				ne = SketchLine.make(map[l.p0], map[l.p1])
			"circle":
				var ci := e as SketchCircle
				ne = SketchCircle.make(map[ci.center], ci.radius)
			"arc":
				var arc := e as SketchArc
				# A pure rotation/translation preserves winding; a mirroring
				# transform (negative determinant) flips it.
				var flips := xf.determinant() < 0.0
				ne = SketchArc.make(map[arc.center], map[arc.start],
					map[arc.end], arc.ccw != flips)
			"spline":
				var sp := e as SketchSpline
				var nids: Array = []
				for spid in sp.points:
					nids.append(map[spid])
				var nsp := SketchSpline.make(nids, sp.closed)
				for hi in sp.handles.size():
					if sp.handles[hi] is Vector2:
						nsp.handles[hi] = xf.basis_xform(sp.handles[hi])
					elif sp.handles[hi] is Dictionary:
						nsp.handles[hi] = {
							"out": xf.basis_xform(sp.handles[hi]["out"]),
							"in": xf.basis_xform(sp.handles[hi]["in"])}
				ne = nsp
		if ne == null:
			continue
		ne.id = sk.next_id()
		ne.construction = e.construction
		map[id] = ne.id
		out_entities.append(ne)

	# Internal geometric constraints: every operand inside the copied set.
	var cons: Array = []
	for c in sk.constraints:
		if c.is_dimensional() or c.type == SketchConstraint.Type.FIX:
			continue
		# H/V flip under rotation — only clone them for translations.
		if (c.type == SketchConstraint.Type.HORIZONTAL
				or c.type == SketchConstraint.Type.VERTICAL) \
				and absf(xf.get_rotation()) > 1e-9:
			continue
		var inside := true
		var ops: Array[String] = []
		for op in c.operands:
			if not map.has(op):
				inside = false
				break
			ops.append(String(map[op]))
		if inside and not ops.is_empty():
			cons.append(SketchConstraint.make(c.type, ops))
	return {"entities": out_entities, "cons": cons}
