class_name BodyBuilder
extends RefCounted
## Builds the document's BODIES from its live features in ONE ordered pass
## over the timeline (M39) — Fusion's operation dropdown semantics:
##   new_body  — starts a solid of its own,
##   join      — unions into its target bodies (none: new body),
##   cut       — carves its shape out of its target bodies,
##   intersect — keeps only the overlap with its target bodies.
## Targets are the feature's explicit list (M39 picker) or, when empty,
## every body whose bounds touch the tool (the M18 rule). Face planes
## re-resolve against the bodies built so far; moves/copies/mirrors/
## patterns happen at their timeline position; a pattern or mirror of a
## cut/join feature replays the tool per instance.
##
## Solids are computed by the Manifold kernel (SolidKernel -> MeshSolid in
## the vendored geometry addon): every part is a closed triangle mesh
## tagged with face ids, booleans are exact and synchronous, and each body
## carries its kernel solid + per-triangle face ids for pickers/exporters.
## When the addon binary is missing on a platform the legacy engine-CSG
## path runs instead (deferred brushes — one frame wait), which is why
## `build` stays a COROUTINE taking a host node. Callers await it.


## The CSG coplanarity margin lives on SolidFeature now; re-exported here
## because tests and older call sites read it off BodyBuilder.
const EPS_MM := SolidFeature.EPS_MM


## -> Array of {id: String (root feature id), name: String,
##              mesh: ArrayMesh, feature_ids: Array[String],
##              solid: MeshSolid|null, face_ids: PackedInt32Array, color}
static func build(doc: CadDocument, host: Node) -> Array:
	for f in doc.features:
		(f as Feature).rebuild_error = ""
		(f as Feature).rebuild_level = "error"
	if SolidKernel.available():
		return _build_kernel(doc, "")
	return await _build_csg(doc, host)


## M41: the bodies as they stand just BEFORE feature `stop_id` — what a
## feature that edits existing geometry (fillet, hole, …) must offer as
## its pick candidates when re-opened for editing. Does not touch the
## features' rebuild errors. Kernel only ([] on the legacy path).
static func build_before(doc: CadDocument, stop_id: String) -> Array:
	if not SolidKernel.available():
		return []
	var saved := {}
	for f in doc.features:
		saved[(f as Feature).id] = [(f as Feature).rebuild_error, (f as Feature).rebuild_level]
	var out := _build_kernel(doc, stop_id)
	for f in doc.features:
		var pair: Array = saved[(f as Feature).id]
		(f as Feature).rebuild_error = pair[0]
		(f as Feature).rebuild_level = pair[1]
	return out


## M39: ONE ordered pass over the timeline. Solid features fold into bodies
## as they come (new body / join / cut / intersect, with explicit targets
## or the AABB rule); face planes re-resolve against the bodies built so
## far, so a sketch on a face follows its face; moves, copies, mirrors and
## patterns happen at their own position, so a later cut targets a moved
## body where it now is; a pattern or mirror of a CUT/JOIN feature replays
## that feature's tool at every instance.
static func _build_kernel(doc: CadDocument, stop_id: String) -> Array:
	var bodies: Array = []        # [{id, name, feature_ids, solid, color}]
	var part_solids := {}         # feature id -> its own kernel solid
	var treated := {}
	for f in doc.live_features():
		if stop_id != "" and (f as Feature).id == stop_id:
			break
		if f is PlaneFeature:
			var pf := f as PlaneFeature
			if pf.plane_kind == PlaneFeature.KIND_FACE:
				if not pf.resolve_face(_entries(bodies)):
					if pf.ref != null and pf.ref.body != "":
						pf.rebuild_error = "face reference lost — the last position stands; re-pick the face"
						pf.rebuild_level = "warning"
		elif f is SolidFeature:
			var ef := f as SolidFeature
			if ef.needs_bodies():
				var perr := ef.prepare(doc, _entries(bodies))
				if perr != "":
					ef.rebuild_error = perr
					continue
			var part := ef.solid_part(doc)
			if part.is_empty():
				ef.rebuild_error = "profile no longer resolves"
				continue
			var ps := SolidKernel.from_mesh(ef.kernel_mesh(doc, part),
				SolidKernel.ordinal_of(ef.id))
			if ps == null:
				if ef is MeshBodyFeature:
					# M44: an open mesh still shows — reference only, no
					# booleans, amber chip.
					ef.rebuild_error = "mesh is not a closed solid — shown for reference, excluded from booleans"
					ef.rebuild_level = "warning"
					var ref_entry := _new_entry(ef.id, ef.name, null, ef.color)
					ref_entry["mesh"] = part["mesh"]
					ref_entry["dirty"] = false
					ref_entry["reference_only"] = true
					bodies.append(ref_entry)
					continue
				ef.rebuild_error = SolidKernel.last_error
				continue
			part_solids[ef.id] = ps
			_apply_tool(bodies, ef, ef, ps, ef.operation, ef.id, ef.name, ef.color)
		elif f is EdgeTreatFeature:
			# M35 treatments rebuild a plain single-extrude body's mesh with
			# every live treatment on it baked in, then the body continues
			# through the kernel (later cuts apply to the rounded body).
			var et := f as EdgeTreatFeature
			if treated.has(et.body):
				continue
			var bt := _entry_by_id(bodies, et.body)
			if bt.is_empty() or (bt["feature_ids"] as Array).size() != 1:
				if not bt.is_empty():
					et.rebuild_error = "only a plain single-extrude body can be treated"
				else:
					et.rebuild_error = "its body no longer exists"
				continue
			var root_ef := doc.feature_by_id(et.body) as ExtrudeFeature
			if root_ef == null:
				et.rebuild_error = "its body is not an extrude"
				continue
			var ets: Array = []
			for g in doc.live_features():
				if g is EdgeTreatFeature and (g as EdgeTreatFeature).body == et.body:
					ets.append(g)
			var tm := EdgeTreatFeature.build_combined(doc, root_ef, ets)
			if tm == null:
				et.rebuild_error = EdgeTreatFeature.build_error \
					if EdgeTreatFeature.build_error != "" else "treatment failed"
				continue
			var ts := SolidKernel.from_mesh(tm, SolidKernel.ordinal_of(et.body))
			if ts == null:
				et.rebuild_error = SolidKernel.last_error
				continue
			bt["solid"] = ts
			bt["dirty"] = true
			for g in ets:
				(bt["feature_ids"] as Array).append((g as Feature).id)
			treated[et.body] = true
		elif f is EdgeFilletFeature:
			# M41: rounds/chamfers any edge chain of its body, in order.
			var ff := f as EdgeFilletFeature
			var bf := _entry_by_id(bodies, ff.body)
			if bf.is_empty():
				ff.rebuild_error = "its body no longer exists"
				continue
			if ff.edges.is_empty():
				ff.rebuild_error = "no edges picked"
				continue
			bf["solid"] = ff.apply(bf)
			bf["dirty"] = true
			(bf["feature_ids"] as Array).append(ff.id)
		elif f is CombineFeature:
			var cbf := f as CombineFeature
			var tgt := _entry_by_id(bodies, cbf.target)
			if tgt.is_empty():
				cbf.rebuild_error = "its target body no longer exists"
				continue
			var any := false
			for tid in cbf.tools:
				var te := _entry_by_id(bodies, String(tid))
				if te.is_empty() or te == tgt:
					continue
				var before := SolidKernel.volume(tgt["solid"])
				var res := SolidKernel.boolean(tgt["solid"], te["solid"], cbf.operation)
				if not SolidKernel.is_valid(res):
					if cbf.operation == SolidFeature.OP_INTERSECT:
						cbf.rebuild_error = "no overlap with %s" % te["name"]
						continue
					if cbf.operation == SolidFeature.OP_CUT:
						bodies.erase(tgt)   # consumed
						any = true
						break
					continue
				if cbf.operation == SolidFeature.OP_CUT \
						and absf(SolidKernel.volume(res) - before) < 1e-9:
					cbf.rebuild_error = "%s does not touch the target" % te["name"]
				tgt["solid"] = res
				tgt["dirty"] = true
				any = true
				if not cbf.keep_tools:
					bodies.erase(te)
			if not any and cbf.rebuild_error == "":
				cbf.rebuild_error = "no tool bodies — pick at least one"
			elif bodies.has(tgt):
				(tgt["feature_ids"] as Array).append(cbf.id)
		elif f is SplitBodyFeature:
			var spf := f as SplitBodyFeature
			var sb := _entry_by_id(bodies, spf.body)
			if sb.is_empty():
				spf.rebuild_error = "its body no longer exists"
				continue
			var perr := spf.resolve_plane(doc, _entries(bodies))
			if perr != "":
				spf.rebuild_error = perr
				continue
			var halves: Array = (sb["solid"] as RefCounted).call("split_by_plane",
				spf.plane_normal, spf.plane_offset)
			var kept: RefCounted = halves[0]
			var other: RefCounted = halves[1]
			if not SolidKernel.is_valid(kept) or not SolidKernel.is_valid(other):
				spf.rebuild_error = "the plane does not pass through the body"
				continue
			sb["solid"] = kept
			sb["dirty"] = true
			(sb["feature_ids"] as Array).append(spf.id)
			var half := _new_entry(spf.id, spf.name, other, sb.get("color", Color(0, 0, 0, 0)))
			bodies.insert(bodies.find(sb) + 1, half)
		elif f is ShellFeature:
			var shf := f as ShellFeature
			var she := _entry_by_id(bodies, shf.body)
			if she.is_empty():
				shf.rebuild_error = "its body no longer exists"
				continue
			_entries([she])
			she["solid"] = shf.apply(she)
			she["dirty"] = true
			(she["feature_ids"] as Array).append(shf.id)
		elif f is FaceOffsetFeature:
			var fof := f as FaceOffsetFeature
			var fe := _entry_by_id(bodies, fof.body)
			if fe.is_empty():
				fof.rebuild_error = "its body no longer exists"
				continue
			_entries([fe])
			var r3 := fof.apply(fe)
			if not SolidKernel.is_valid(r3):
				bodies.erase(fe)
				continue
			fe["solid"] = r3
			fe["dirty"] = true
			(fe["feature_ids"] as Array).append(fof.id)
		elif f is TransformFeature:
			var tf := f as TransformFeature
			var b2 := _entry_by_id(bodies, tf.body)
			if b2.is_empty():
				tf.rebuild_error = "its body no longer exists"
				continue
			var center := SolidKernel.aabb(b2["solid"]).get_center()
			b2["solid"] = SolidKernel.transformed(b2["solid"], tf.transform3d(center))
			b2["dirty"] = true
			(b2["feature_ids"] as Array).append(tf.id)
		elif f is CopyBodyFeature:
			var cf := f as CopyBodyFeature
			var b3 := _entry_by_id(bodies, cf.source)
			if b3.is_empty():
				cf.rebuild_error = "its source body no longer exists"
				continue
			# Copies inherit the source color until given one (QA §M32.5).
			bodies.append(_derived_entry(b3, cf.id, cf.name,
				Transform3D(Basis.IDENTITY, cf.translation),
				cf.color if cf.color.a > 0.0 else b3.get("color", Color(0, 0, 0, 0))))
		elif f is MirrorBodyFeature:
			var mf := f as MirrorBodyFeature
			var b4 := _entry_by_id(bodies, mf.source)
			if not b4.is_empty():
				bodies.append(_derived_entry(b4, mf.id, mf.name,
					mf.mirror_transform(), b4.get("color", Color(0, 0, 0, 0))))
			else:
				_replay_feature(doc, bodies, part_solids, mf, mf.source,
					[mf.mirror_transform()])
		elif f is PatternBodyFeature:
			var pf2 := f as PatternBodyFeature
			var b5 := _entry_by_id(bodies, pf2.source)
			var xfs := pf2.instance_transforms()
			if not b5.is_empty():
				for k in xfs.size():
					bodies.append(_derived_entry(b5, "%s:%d" % [pf2.id, k + 1],
						"%s %d" % [pf2.name, k + 1], xfs[k],
						b5.get("color", Color(0, 0, 0, 0))))
			else:
				_replay_feature(doc, bodies, part_solids, pf2, pf2.source, xfs)
	var out: Array = []
	for e: Dictionary in _entries(bodies):
		if e.get("mesh") == null \
				or (e["mesh"] as ArrayMesh).get_surface_count() == 0:
			continue
		out.append(e)
	return out


## Apply a tool solid to the body list with Fusion's operation semantics.
## `owner` is the feature that takes the blame for errors; `tf` the solid
## feature whose targets apply (the same object, or the source of a
## replayed pattern instance).
static func _apply_tool(bodies: Array, owner: Feature, tf: SolidFeature, ps: RefCounted,
		op: String, new_id: String, new_name: String, color: Color) -> void:
	match op:
		SolidFeature.OP_JOIN:
			var targets := _targets(bodies, tf, ps, owner)
			if targets.is_empty():
				if owner.rebuild_error == "":
					bodies.append(_new_entry(new_id, new_name, ps, color))
				return
			var merged: Dictionary = targets[0]
			var solid: RefCounted = merged["solid"]
			for k in range(1, targets.size()):
				var other: Dictionary = targets[k]
				solid = SolidKernel.boolean(solid, other["solid"], SolidFeature.OP_JOIN)
				(merged["feature_ids"] as Array).append_array(other["feature_ids"])
				bodies.erase(other)
			var res := SolidKernel.boolean(solid, ps, SolidFeature.OP_JOIN)
			if not SolidKernel.is_valid(res):
				owner.rebuild_error = "join produced nothing"
				return
			merged["solid"] = res
			merged["dirty"] = true
			(merged["feature_ids"] as Array).append(owner.id)
		SolidFeature.OP_CUT, SolidFeature.OP_INTERSECT:
			var targets2 := _targets(bodies, tf, ps, owner)
			if targets2.is_empty():
				if owner.rebuild_error == "":
					owner.rebuild_error = "touches no body"
				return
			for b: Dictionary in targets2:
				var before := SolidKernel.volume(b["solid"])
				var res2 := SolidKernel.boolean(b["solid"], ps, op)
				if not SolidKernel.is_valid(res2):
					if op == SolidFeature.OP_INTERSECT:
						owner.rebuild_error = "no overlap with %s" % b["name"]
						continue
					# A cut that consumes the whole body: the body vanishes.
					bodies.erase(b)
					continue
				if op == SolidFeature.OP_CUT \
						and absf(SolidKernel.volume(res2) - before) < 1e-9:
					# Explicitly targeted, but it never reaches the body —
					# say so instead of silently doing nothing.
					owner.rebuild_error = "does not touch %s" % b["name"]
					continue
				b["solid"] = res2
				b["dirty"] = true
				(b["feature_ids"] as Array).append(owner.id)
		_:
			bodies.append(_new_entry(new_id, new_name, ps, color))


## Bodies a tool applies to: the feature's explicit targets (M39) or every
## body whose bounds touch the tool (M18). A missing explicit target is the
## feature's error.
static func _targets(bodies: Array, tf: SolidFeature, ps: RefCounted, owner: Feature) -> Array:
	var out: Array = []
	if not tf.targets.is_empty():
		for tid in tf.targets:
			var e := _entry_by_id(bodies, String(tid))
			if not e.is_empty():
				out.append(e)
		if out.is_empty():
			owner.rebuild_error = "target body no longer exists — re-pick"
		return out
	var box := SolidKernel.aabb(ps).grow(0.001)
	for b: Dictionary in bodies:
		if b.get("solid") == null:
			continue   # reference-only mesh bodies take no booleans
		if SolidKernel.aabb(b["solid"]).grow(0.001).intersects(box):
			out.append(b)
	return out


## Pattern/mirror of a FEATURE (M39): the source solid feature's tool is
## replayed at every instance transform with the source's operation and
## targets, as if the feature had been repeated by hand.
static func _replay_feature(doc: CadDocument, bodies: Array, part_solids: Dictionary,
		owner: Feature, source_id: String, xfs: Array) -> void:
	var src := doc.feature_by_id(source_id) as SolidFeature
	if src == null:
		owner.rebuild_error = "its source no longer exists"
		return
	if not part_solids.has(source_id):
		owner.rebuild_error = "its source feature did not compute"
		return
	if src.operation == SolidFeature.OP_NEW_BODY:
		owner.rebuild_error = "source is a body — pick the body instead"
		return
	var ps: RefCounted = part_solids[source_id]
	for k in xfs.size():
		_apply_tool(bodies, owner, src, SolidKernel.transformed(ps, xfs[k]),
			src.operation, "%s:%d" % [owner.id, k + 1],
			"%s %d" % [owner.name, k + 1], Color(0, 0, 0, 0))


## First hit of a ray against the bodies' meshes (flat surface-0
## triangles). -> {t, body, face, point, normal} or {} when nothing is hit
## beyond `min_t`.
static func ray_hit(entries: Array, origin: Vector3, dir: Vector3, min_t := 1e-4,
		only_bodies: Array = []) -> Dictionary:
	var best := {}
	var best_t := INF
	for b: Dictionary in entries:
		if not only_bodies.is_empty() and not only_bodies.has(String(b["id"])):
			continue
		var mesh: ArrayMesh = b.get("mesh")
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		if not mesh.get_aabb().grow(0.01).intersects_ray(origin, dir):
			continue
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var fids: PackedInt32Array = b.get("face_ids", PackedInt32Array())
		var nt := verts.size() / 3
		for t in nt:
			var hit = Geometry3D.ray_intersects_triangle(origin, dir, verts[t * 3],
				verts[t * 3 + 1], verts[t * 3 + 2])
			if hit == null:
				continue
			var tt := (hit as Vector3 - origin).dot(dir)
			if tt < min_t or tt >= best_t:
				continue
			best_t = tt
			best = {"t": tt, "body": String(b["id"]),
				"face": fids[t] if t < fids.size() else -1, "point": hit,
				"normal": (verts[t * 3 + 1] - verts[t * 3]).cross(
					verts[t * 3 + 2] - verts[t * 3]).normalized()}
	return best


static func _new_entry(id: String, name: String, solid: RefCounted, color: Color) -> Dictionary:
	return {"id": id, "name": name, "feature_ids": [id], "solid": solid,
		"color": color, "dirty": true, "mesh": null,
		"face_ids": PackedInt32Array()}


static func _derived_entry(src: Dictionary, id: String, name: String, xf: Transform3D,
		color: Color) -> Dictionary:
	return {"id": id, "name": name, "feature_ids": [id],
		"solid": SolidKernel.transformed(src["solid"], xf), "color": color,
		"dirty": true, "mesh": null, "face_ids": PackedInt32Array()}


static func _entry_by_id(bodies: Array, id: String) -> Dictionary:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return b
	return {}


## Mesh every dirty body (kernel solid -> renderable mesh + face ids) and
## return the list. Entries are the same dictionaries (mutated in place).
static func _entries(bodies: Array) -> Array:
	for b: Dictionary in bodies:
		if bool(b.get("dirty", true)) and b.get("solid") != null:
			var tm := SolidKernel.to_mesh(b["solid"])
			b["mesh"] = tm["mesh"]
			b["face_ids"] = tm["face_ids"]
			b["dirty"] = false
	return bodies


## Legacy path (no kernel binary on this platform): the M18–M35 builder —
## AABB targets, CSG bake, transforms applied after the booleans.
static func _build_csg(doc: CadDocument, host: Node) -> Array:
	var bodies: Array = []
	var ordinal := {}
	for f in doc.features:
		ordinal[(f as Feature).id] = SolidKernel.ordinal_of((f as Feature).id)
	for f in doc.live_features():
		if not (f is SolidFeature):
			continue
		var ef := f as SolidFeature
		var part := ef.solid_part(doc)
		if part.is_empty():
			ef.rebuild_error = "profile no longer resolves"
			continue
		match ef.operation:
			SolidFeature.OP_JOIN:
				var targets := _touching(bodies, part["aabb"])
				if targets.is_empty():
					bodies.append(_new_body(part))
				else:
					var merged: Dictionary = bodies[targets[0]]
					for k in range(targets.size() - 1, 0, -1):
						var other: Dictionary = bodies[targets[k]]
						(merged["parts"] as Array).append_array(other["parts"])
						(merged["feature_ids"] as Array).append_array(
							other["feature_ids"])
						merged["aabb"] = (merged["aabb"] as AABB).merge(other["aabb"])
						bodies.remove_at(targets[k])
					(merged["parts"] as Array).append(part)
					(merged["feature_ids"] as Array).append(ef.id)
					merged["aabb"] = (merged["aabb"] as AABB).merge(part["aabb"])
			SolidFeature.OP_CUT, SolidFeature.OP_INTERSECT:
				var hit := _touching(bodies, part["aabb"])
				if hit.is_empty():
					ef.rebuild_error = "touches no body"
				for bi in hit:
					var b: Dictionary = bodies[bi]
					(b["parts"] as Array).append(part)
					(b["feature_ids"] as Array).append(ef.id)
			_:
				bodies.append(_new_body(part))

	await _mesh_bodies_csg(doc, bodies, host)

	var out: Array = []
	for b: Dictionary in bodies:
		if b.get("mesh") == null \
				or (b["mesh"] as ArrayMesh).get_surface_count() == 0:
			continue
		var root_sf := doc.feature_by_id(String(b["id"])) as SolidFeature
		out.append({"id": b["id"], "name": b["name"], "mesh": b["mesh"],
			"feature_ids": b["feature_ids"], "solid": b.get("solid"),
			"face_ids": b.get("face_ids", PackedInt32Array()),
			"color": root_sf.color if root_sf != null else Color(0, 0, 0, 0)})

	# M32: moves + parametric copies, applied AFTER boolean resolution in
	# timeline order among themselves (booleans still target by pre-move
	# AABB — the known limitation carried since M18). Transforms bake into
	# the mesh so everything downstream (STL, AABB, volume, picking) reads
	# the moved geometry for free.
	var treated := {}
	for f in doc.live_features():
		if f is EdgeTreatFeature:
			# M35: rebuild a SINGLE-plain-extrude body's mesh with its edge
			# treatments baked in — ALL live treatments on the body combine
			# into one rebuild, so a fillet and a chamfer can stack on
			# different edges (QA §M35.3). Boolean/multi-part bodies are
			# skipped (the feature's creation path refuses them with a
			# hint; this guard keeps replay safe).
			var et := f as EdgeTreatFeature
			if treated.has(et.body):
				continue
			for bt: Dictionary in out:
				if String(bt["id"]) != et.body \
						or (bt["feature_ids"] as Array).size() != 1:
					continue
				var root_ef := doc.feature_by_id(et.body) as ExtrudeFeature
				if root_ef == null:
					continue
				var ets: Array = []
				for g in doc.live_features():
					if g is EdgeTreatFeature \
							and (g as EdgeTreatFeature).body == et.body:
						ets.append(g)
				var tm := EdgeTreatFeature.build_combined(doc, root_ef, ets)
				if tm != null:
					bt["mesh"] = tm
					_rekernel(bt, tm, int(ordinal.get(et.body, 1)))
					for g in ets:
						(bt["feature_ids"] as Array).append((g as Feature).id)
					treated[et.body] = true
		elif f is TransformFeature:
			var tf := f as TransformFeature
			for b2: Dictionary in out:
				if String(b2["id"]) != tf.body:
					continue
				var center := (b2["mesh"] as ArrayMesh).get_aabb().get_center()
				var txf := tf.transform3d(center)
				b2["mesh"] = transformed_mesh(b2["mesh"], txf)
				_retransform(b2, txf)
				(b2["feature_ids"] as Array).append(tf.id)
		elif f is CopyBodyFeature:
			var cf := f as CopyBodyFeature
			for b3: Dictionary in out.duplicate():
				if String(b3["id"]) != cf.source:
					continue
				# Copies inherit the source color until they are given one of
				# their own (QA §M32.5).
				var cxf := Transform3D(Basis.IDENTITY, cf.translation)
				out.append(_derived(b3, cf.id, cf.name, cxf, cf.color \
					if cf.color.a > 0.0 else b3.get("color", Color(0, 0, 0, 0))))
		elif f is MirrorBodyFeature:
			var mf := f as MirrorBodyFeature
			for b4: Dictionary in out.duplicate():
				if String(b4["id"]) != mf.source:
					continue
				out.append(_derived(b4, mf.id, mf.name, mf.mirror_transform(),
					b4.get("color", Color(0, 0, 0, 0))))
		elif f is PatternBodyFeature:
			var pf := f as PatternBodyFeature
			for b5: Dictionary in out.duplicate():
				if String(b5["id"]) != pf.source:
					continue
				var xfs := pf.instance_transforms()
				for k in xfs.size():
					out.append(_derived(b5, "%s:%d" % [pf.id, k + 1],
						"%s %d" % [pf.name, k + 1], xfs[k],
						b5.get("color", Color(0, 0, 0, 0))))
	return out


## Legacy path (no kernel binary on this platform): bake through the
## engine's CSG, whose brushes update deferred — the scratch nodes must sit
## in the tree across one frame, so this is a coroutine.
static func _mesh_bodies_csg(doc: CadDocument, bodies: Array, host: Node) -> void:
	# Mesh every body. CSG bodies are all added to the tree first, then one
	# frame's wait covers the whole batch.
	var scratch: Array = []          # [{body, node}]
	for b: Dictionary in bodies:
		var parts: Array = b["parts"]
		if parts.size() == 1:
			var ef0: SolidFeature = parts[0]["feature"]
			b["mesh"] = ef0.build_mesh(doc)
		else:
			var combiner := CSGCombiner3D.new()
			# Never rendered: the combiner exists only to be baked, and a
			# visible one paints the raw CSG brushes over the real body mesh
			# for however many frames the bake takes (the z-fighting ghost of
			# QA §M18.6, round two).
			combiner.visible = false
			for part: Dictionary in parts:
				var ef_p: SolidFeature = part["feature"]
				var node := ef_p.csg_node(part)
				if ef_p.operation == SolidFeature.OP_CUT:
					node.operation = CSGShape3D.OPERATION_SUBTRACTION
				elif ef_p.operation == SolidFeature.OP_INTERSECT:
					node.operation = CSGShape3D.OPERATION_INTERSECTION
				combiner.add_child(node)
			host.add_child(combiner)
			scratch.append({"body": b, "node": combiner})
	if not scratch.is_empty():
		await host.get_tree().process_frame
		for s: Dictionary in scratch:
			var combiner: CSGCombiner3D = s["node"]
			var baked := combiner.bake_static_mesh()
			# The CSG shape rebuilds via a deferred call after entering the
			# tree; one frame is not always enough and the bake comes back
			# NULL or with no surfaces. Wait it out before believing
			# "empty"; a null that survives the retries is treated as empty.
			var tries := 0
			while (baked == null or baked.get_surface_count() == 0) and tries < 8:
				await host.get_tree().process_frame
				baked = combiner.bake_static_mesh()
				tries += 1
			(s["body"] as Dictionary)["mesh"] = _finish_csg_mesh(baked)
			combiner.queue_free()


## A copy of `mesh` with `xf` baked into vertices and normals; surface
## count and materials survive (surface 1 is the edge-line overlay). A
## reflecting transform (negative determinant, M33 mirror) reverses each
## triangle's winding so the solid stays outward-facing.
static func transformed_mesh(mesh: ArrayMesh, xf: Transform3D) -> ArrayMesh:
	var out := ArrayMesh.new()
	var nb := xf.basis.inverse().transposed()
	var flips := xf.basis.determinant() < 0.0
	for s in mesh.get_surface_count():
		var prim := mesh.surface_get_primitive_type(s)
		var arrays := mesh.surface_get_arrays(s)
		var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
		for i in verts.size():
			verts[i] = xf * verts[i]
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var norms := (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate()
			for i in norms.size():
				norms[i] = (nb * norms[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = norms
		if flips and prim == Mesh.PRIMITIVE_TRIANGLES:
			if arrays[Mesh.ARRAY_INDEX] != null \
					and (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
				var idx := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
				var t := 0
				while t + 2 < idx.size():
					var tmp := idx[t + 1]
					idx[t + 1] = idx[t + 2]
					idx[t + 2] = tmp
					t += 3
				arrays[Mesh.ARRAY_INDEX] = idx
			else:
				# Non-indexed: swap the vertex tuples themselves (and any
				# per-vertex arrays would need the same — the meshes here
				# carry only positions + normals).
				var t2 := 0
				while t2 + 2 < verts.size():
					var tmpv := verts[t2 + 1]
					verts[t2 + 1] = verts[t2 + 2]
					verts[t2 + 2] = tmpv
					if arrays[Mesh.ARRAY_NORMAL] != null:
						var norms2 := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
						var tmpn := norms2[t2 + 1]
						norms2[t2 + 1] = norms2[t2 + 2]
						norms2[t2 + 2] = tmpn
					t2 += 3
		arrays[Mesh.ARRAY_VERTEX] = verts
		out.add_surface_from_arrays(prim, arrays)
		var mat := mesh.surface_get_material(s)
		if mat != null:
			out.surface_set_material(s, mat)
	return out


## True when the document needs no CSG pass — every live solid feature is a
## plain NEW_BODY. Callers may then mesh synchronously (no frame wait).
static func all_new_body(doc: CadDocument) -> bool:
	for f in doc.live_features():
		if f is SolidFeature \
				and (f as SolidFeature).operation != SolidFeature.OP_NEW_BODY:
			return false
	return true


## A body derived from `src` by `xf` (copy / mirror / pattern instance):
## mesh and kernel solid both transformed, face ids carried over.
static func _derived(src: Dictionary, id: String, name: String, xf: Transform3D,
		color: Color) -> Dictionary:
	var d := {"id": id, "name": name,
		"mesh": transformed_mesh(src["mesh"], xf),
		"feature_ids": [id], "color": color,
		"solid": null, "face_ids": src.get("face_ids", PackedInt32Array())}
	_retransform(d, xf, src.get("solid"))
	return d


static func _retransform(b: Dictionary, xf: Transform3D, from: Variant = null) -> void:
	var solid: Variant = from if from != null else b.get("solid")
	if solid == null:
		return
	b["solid"] = SolidKernel.transformed(solid, xf)


## Replace a body's mesh with one regenerated through the kernel (so face
## ids + edge overlay match the rest); falls back to `mesh` as-is when the
## kernel rejects it.
static func _rekernel(b: Dictionary, mesh: ArrayMesh, ordinal: int) -> void:
	if not SolidKernel.available():
		return
	var solid := SolidKernel.from_mesh(mesh, ordinal)
	if solid == null:
		return
	var tm := SolidKernel.to_mesh(solid)
	b["mesh"] = tm["mesh"]
	b["face_ids"] = tm["face_ids"]
	b["solid"] = solid


static func _new_body(part: Dictionary) -> Dictionary:
	var ef: SolidFeature = part["feature"]
	return {"id": ef.id, "name": ef.name, "parts": [part],
		"feature_ids": [ef.id], "aabb": part["aabb"], "mesh": null}


## Rebuild a CSG-baked mesh into the same shape single-part bodies use:
## surface 0 = flat-shaded triangles, surface 1 = edge lines at sharp
## dihedrals and open boundaries. The raw bake carries whatever normals the
## CSG classifier left behind (smoothed across some seams, flipped on
## others), which is why boolean bodies lit differently from plain extrudes
## and drew no silhouette outlines (QA §M18 regression note).
static func _finish_csg_mesh(baked: ArrayMesh) -> ArrayMesh:
	if baked == null or baked.get_surface_count() == 0:
		return baked
	var tris := PackedVector3Array()
	for s in baked.get_surface_count():
		if baked.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := baked.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var iv: Variant = arrays[Mesh.ARRAY_INDEX]
		if iv != null and not (iv as PackedInt32Array).is_empty():
			for i in (iv as PackedInt32Array):
				tris.append(verts[i])
		else:
			tris.append_array(verts)
	if tris.is_empty():
		return baked
	# Outward winding check (signed volume): an inward-wound shell would get
	# inward flat normals below and light as if lit from behind.
	var signed_vol := 0.0
	for t in range(0, tris.size(), 3):
		signed_vol += tris[t].cross(tris[t + 1]).dot(tris[t + 2]) / 6.0
	if signed_vol < 0.0:
		for t in range(0, tris.size(), 3):
			var tmp := tris[t + 1]
			tris[t + 1] = tris[t + 2]
			tris[t + 2] = tmp
	var normals := PackedVector3Array()
	var face_n: Array = []
	for t in range(0, tris.size(), 3):
		var n := (tris[t + 1] - tris[t]).cross(tris[t + 2] - tris[t]).normalized()
		face_n.append(n)
		for _i in 3:
			normals.append(n)
	# Edge overlay: an edge draws when its two faces meet sharply or it
	# borders open space. Vertices keyed on a 1 µm grid so CSG's duplicated
	# vertices count as one.
	var vkey := func(v: Vector3) -> String:
		return "%d,%d,%d" % [roundi(v.x * 1000.0), roundi(v.y * 1000.0),
			roundi(v.z * 1000.0)]
	var edge_rec := {}
	for t in range(0, tris.size(), 3):
		for e in 3:
			var a: Vector3 = tris[t + e]
			var b: Vector3 = tris[t + (e + 1) % 3]
			var ka: String = vkey.call(a)
			var kb: String = vkey.call(b)
			var k := ka + "|" + kb if ka < kb else kb + "|" + ka
			if not edge_rec.has(k):
				edge_rec[k] = {"a": a, "b": b, "n": []}
			((edge_rec[k] as Dictionary)["n"] as Array).append(face_n[t / 3])
	var edges := PackedVector3Array()
	# Same 15° sharpness threshold ExtrudeFeature uses for its wall seams, so
	# tessellated circles stay seam-free on boolean bodies too.
	var flat_dot := cos(deg_to_rad(15.0))
	for k: String in edge_rec:
		var rec: Dictionary = edge_rec[k]
		var ns: Array = rec["n"]
		var draw := ns.size() != 2
		if not draw:
			draw = (ns[0] as Vector3).dot(ns[1] as Vector3) < flat_dot
		if draw:
			edges.append(rec["a"])
			edges.append(rec["b"])
	var mesh := ArrayMesh.new()
	var arrays2 := []
	arrays2.resize(Mesh.ARRAY_MAX)
	arrays2[Mesh.ARRAY_VERTEX] = tris
	arrays2[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays2)
	if not edges.is_empty():
		var earr := []
		earr.resize(Mesh.ARRAY_MAX)
		earr[Mesh.ARRAY_VERTEX] = edges
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


static func _touching(bodies: Array, box: AABB) -> Array:
	var out: Array = []
	for i in bodies.size():
		if ((bodies[i] as Dictionary)["aabb"] as AABB).intersects(box):
			out.append(i)
	return out


## Volume of a body list entry's mesh — indexed or not.
static func mesh_volume(mesh: ArrayMesh) -> float:
	var vol := 0.0
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var iv: Variant = arrays[Mesh.ARRAY_INDEX]
		if iv == null or (iv as PackedInt32Array).is_empty():
			for t in range(0, verts.size(), 3):
				vol += verts[t].cross(verts[t + 1]).dot(verts[t + 2]) / 6.0
		else:
			var idx := iv as PackedInt32Array
			for t in range(0, idx.size(), 3):
				vol += verts[idx[t]].cross(verts[idx[t + 1]]) \
					.dot(verts[idx[t + 2]]) / 6.0
	return absf(vol)
