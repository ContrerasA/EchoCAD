class_name Projector
extends RefCounted
## Fusion's "Project / Include" (M15): copy geometry from another sketch into
## the active one as REAL entities that stay linked to their source. The link
## is model-level (`SketchEntity.link_feature`/`link_entity`), so projected
## geometry re-solves when its source moves and survives save/load.
##
## Projection is along the TARGET plane's normal: a source point's world
## position keeps only its in-plane components. Lines and points project
## between any plane pair; arcs and circles only between PARALLEL planes
## (anywhere else they would become ellipses, which the entity model does not
## have — refused with a message instead).
##
## `refresh` is the derived-data pass: it recomputes every projected entity
## from its source and BREAKS the link (clears the fields, keeps the
## geometry) when the source is gone. It mutates positions directly — like an
## extrude mesh, a projection is replayed state, not history of its own — so
## undoing the SOURCE edit and refreshing again lands back where it was.


## Map a point from `src`'s plane onto `tgt`'s plane (both sketch mm).
## Projection is along the target normal: express the world point in the
## target plane's local frame and drop the normal component. Uses the full
## plane transforms, so offset/custom planes (M22) map correctly.
static func map_point(src: SketchFeature, tgt: SketchFeature, p: Vector2) -> Vector2:
	var local := tgt.plane_transform().affine_inverse() * src.to_world(p)
	return Vector2(local.x, local.y)


## Does projecting from `src` onto `tgt` preserve circles? True when the
## planes are parallel (normals aligned up to sign).
static func planes_parallel(src: SketchFeature, tgt: SketchFeature) -> bool:
	var ns := src.plane_transform().basis.z
	var nt := tgt.plane_transform().basis.z
	return absf(ns.dot(nt)) > 0.999999


## Does the src->tgt mapping flip orientation (mirror)? Decides arc winding.
static func _flips_orientation(src: SketchFeature, tgt: SketchFeature) -> bool:
	var o := map_point(src, tgt, Vector2.ZERO)
	var u := map_point(src, tgt, Vector2(1, 0)) - o
	var v := map_point(src, tgt, Vector2(0, 1)) - o
	return u.cross(v) < 0.0


## Build the projected copies of `src_id` (a point/line/arc/circle in
## `src_feat`) for `tgt_feat`'s sketch. Ids are minted; nothing is added —
## the caller pushes a CmdAddEntities so the projection is one undo step.
## -> {"entities": Array[SketchEntity], "error": String}
static func build(tgt_feat: SketchFeature, src_feat: SketchFeature,
		src_id: String) -> Dictionary:
	var src := src_feat.sketch
	var tgt := tgt_feat.sketch
	var e := src.entity(src_id)
	if e == null:
		return {"entities": [], "error": "no such source entity"}
	# One projection per source: a second copy of the same edge would sit
	# exactly on the first and double every snap.
	for t in tgt.entities():
		if t.link_feature == src_feat.id and t.link_entity == src_id:
			return {"entities": [], "error": "already projected"}
	if (e.kind() == "arc" or e.kind() == "circle") \
			and not planes_parallel(src_feat, tgt_feat):
		return {"entities": [],
			"error": "arcs/circles only project between parallel planes"}
	var out: Array = []
	match e.kind():
		"point":
			out.append(_projected_point(tgt, src_feat, tgt_feat, src_id))
		"line":
			var l := e as SketchLine
			var a := _reuse_or_point(out, tgt, src_feat, tgt_feat, l.p0)
			var b := _reuse_or_point(out, tgt, src_feat, tgt_feat, l.p1)
			var ln := SketchLine.make(a, b)
			ln.id = tgt.next_id()
			_link(ln, src_feat.id, src_id)
			out.append(ln)
		"circle":
			var ci := e as SketchCircle
			var cp := _reuse_or_point(out, tgt, src_feat, tgt_feat, ci.center)
			var nc := SketchCircle.make(cp, ci.radius)
			nc.id = tgt.next_id()
			_link(nc, src_feat.id, src_id)
			out.append(nc)
		"arc":
			var arc := e as SketchArc
			var c := _reuse_or_point(out, tgt, src_feat, tgt_feat, arc.center)
			var s := _reuse_or_point(out, tgt, src_feat, tgt_feat, arc.start)
			var t := _reuse_or_point(out, tgt, src_feat, tgt_feat, arc.end)
			var ccw := arc.ccw
			if _flips_orientation(src_feat, tgt_feat):
				ccw = not ccw
			var na := SketchArc.make(c, s, t, ccw)
			na.id = tgt.next_id()
			_link(na, src_feat.id, src_id)
			out.append(na)
		_:
			return {"entities": [], "error": "cannot project a %s" % e.kind()}
	return {"entities": out, "error": ""}


## A projected point for source point `pid` — reusing one the target sketch
## (or this build) already links to that source, so projecting two lines that
## share a corner shares the projected corner too.
static func _reuse_or_point(pending: Array, tgt: Sketch, src_feat: SketchFeature,
		tgt_feat: SketchFeature, pid: String) -> String:
	for t in tgt.entities():
		if t.kind() == "point" and t.link_feature == src_feat.id \
				and t.link_entity == pid:
			return t.id
	for t: SketchEntity in pending:
		if t.kind() == "point" and t.link_entity == pid:
			return t.id
	var np := _projected_point(tgt, src_feat, tgt_feat, pid)
	pending.append(np)
	return np.id


static func _projected_point(tgt: Sketch, src_feat: SketchFeature,
		tgt_feat: SketchFeature, pid: String) -> SketchPoint:
	var sp := src_feat.sketch.point(pid)
	var np := SketchPoint.make(map_point(src_feat, tgt_feat, sp.pos))
	np.id = tgt.next_id()
	_link(np, src_feat.id, pid)
	return np


static func _link(e: SketchEntity, fid: String, eid: String) -> void:
	e.link_feature = fid
	e.link_entity = eid


## Recompute every projected entity in every sketch of `doc` from its source;
## re-solve sketches whose projections moved so constrained dependents follow.
## Sources that no longer exist break their links. Returns user-facing
## messages (broken links, skipped updates) — empty when all is quiet.
static func refresh(doc: CadDocument) -> Array[String]:
	var messages: Array[String] = []
	for f in doc.features:
		var sf := f as SketchFeature
		if sf == null:
			continue
		var moved := false
		for e in sf.sketch.entities():
			if not e.is_projected():
				continue
			var src_feat := doc.sketch_feature(e.link_feature)
			var src_e: SketchEntity = null
			if src_feat != null:
				src_e = src_feat.sketch.entity(e.link_entity)
			if src_feat == null or src_e == null or src_e.kind() != e.kind():
				messages.append(
					"Projection source of %s in %s was deleted — link broken; "
					% [e.id, sf.name] + "the geometry is now ordinary sketch geometry")
				e.link_feature = ""
				e.link_entity = ""
				continue
			match e.kind():
				"point":
					var want := map_point(src_feat, sf, (src_e as SketchPoint).pos)
					var pt := e as SketchPoint
					if pt.pos.distance_to(want) > 1e-9:
						pt.pos = want
						moved = true
				"circle":
					var ci := e as SketchCircle
					var src_ci := src_e as SketchCircle
					if absf(ci.radius - src_ci.radius) > 1e-9:
						ci.radius = src_ci.radius
						moved = true
				"arc":
					var na := e as SketchArc
					var src_a := src_e as SketchArc
					var ccw := src_a.ccw
					if _flips_orientation(src_feat, sf):
						ccw = not ccw
					if na.ccw != ccw:
						na.ccw = ccw
						moved = true
				_:
					pass   # lines carry no geometry of their own
		if moved and not sf.sketch.constraints.is_empty():
			# Dependents follow the projection, exactly as they follow a drag.
			var res := ConstraintSolver.solve(sf.sketch)
			for pid: String in res["points"]:
				sf.sketch.point(pid).pos = res["points"][pid]
			for cid: String in res["radii"]:
				(sf.sketch.entity(cid) as SketchCircle).radius = res["radii"][cid]
	return messages
