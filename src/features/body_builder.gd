class_name BodyBuilder
extends RefCounted
## Builds the document's BODIES from its live SOLID features (M18 extrudes,
## M23 revolves). A body is the boolean result of one NEW_BODY feature plus
## every later JOIN/CUT feature whose solid touches it (AABB test),
## evaluated in timeline order — Fusion's operation dropdown semantics:
##   new_body — starts a solid of its own,
##   join     — unions into every body it touches (none touched: new body),
##   cut      — carves its shape out of every body it touches (none: no-op).
##
## Single-part bodies mesh through the feature's build_mesh (synchronous,
## exact, carries the edge-line overlay surface). Multi-part bodies bake
## through the engine's CSG, whose brushes update deferred — the scratch
## nodes must sit in the tree across one frame, so `build` is a COROUTINE
## and takes a host node. Callers await it. Each feature supplies its own
## exact mesh, CSG node and AABB (SolidFeature interface).


## The CSG coplanarity margin lives on SolidFeature now; re-exported here
## because tests and older call sites read it off BodyBuilder.
const EPS_MM := SolidFeature.EPS_MM


## -> Array of {id: String (root feature id), name: String,
##              mesh: ArrayMesh, feature_ids: Array[String]}
static func build(doc: CadDocument, host: Node) -> Array:
	var bodies: Array = []
	for f in doc.live_features():
		if not (f is SolidFeature):
			continue
		var ef := f as SolidFeature
		var part := ef.solid_part(doc)
		if part.is_empty():
			continue
		match ef.operation:
			SolidFeature.OP_JOIN:
				var targets := _touching(bodies, part["aabb"])
				if targets.is_empty():
					bodies.append(_new_body(part))
				else:
					# Union the touched bodies and this prism into ONE body,
					# rooted at the earliest of them.
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
			SolidFeature.OP_CUT:
				for bi in _touching(bodies, part["aabb"]):
					var b: Dictionary = bodies[bi]
					(b["parts"] as Array).append(part)
					(b["feature_ids"] as Array).append(ef.id)
			_:
				bodies.append(_new_body(part))

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
				combiner.add_child(node)
			host.add_child(combiner)
			scratch.append({"body": b, "node": combiner})
	if not scratch.is_empty():
		await host.get_tree().process_frame
		for s: Dictionary in scratch:
			var combiner: CSGCombiner3D = s["node"]
			var baked := combiner.bake_static_mesh()
			# The CSG shape rebuilds via a deferred call after entering the
			# tree; depending on when this build was kicked off (an undo, a
			# coalesced rebuild, a fresh document load) one frame is not
			# always enough and the bake comes back NULL or with no surfaces
			# — which is how perfectly good bodies vanished after Ctrl+Z, and
			# how an unguarded null aborted this coroutine mid-build and left
			# `_bodies_building` stuck forever. Wait it out before believing
			# "empty"; a null that survives the retries is treated as empty.
			var tries := 0
			while (baked == null or baked.get_surface_count() == 0) and tries < 8:
				await host.get_tree().process_frame
				baked = combiner.bake_static_mesh()
				tries += 1
			(s["body"] as Dictionary)["mesh"] = _finish_csg_mesh(baked)
			combiner.queue_free()

	var out: Array = []
	for b: Dictionary in bodies:
		if b.get("mesh") == null \
				or (b["mesh"] as ArrayMesh).get_surface_count() == 0:
			continue
		var root_sf := doc.feature_by_id(String(b["id"])) as SolidFeature
		out.append({"id": b["id"], "name": b["name"], "mesh": b["mesh"],
			"feature_ids": b["feature_ids"],
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
			# treatment baked in. Boolean/multi-part bodies and second
			# treatments are skipped (the feature's creation path refuses
			# them with a hint; this guard keeps replay safe).
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
				var tm := et.build_treated_mesh(doc, root_ef)
				if tm != null:
					bt["mesh"] = tm
					(bt["feature_ids"] as Array).append(et.id)
					treated[et.body] = true
		elif f is TransformFeature:
			var tf := f as TransformFeature
			for b2: Dictionary in out:
				if String(b2["id"]) != tf.body:
					continue
				var center := (b2["mesh"] as ArrayMesh).get_aabb().get_center()
				b2["mesh"] = transformed_mesh(b2["mesh"],
					tf.transform3d(center))
				(b2["feature_ids"] as Array).append(tf.id)
		elif f is CopyBodyFeature:
			var cf := f as CopyBodyFeature
			for b3: Dictionary in out.duplicate():
				if String(b3["id"]) != cf.source:
					continue
				out.append({"id": cf.id, "name": cf.name,
					"mesh": transformed_mesh(b3["mesh"],
						Transform3D(Basis.IDENTITY, cf.translation)),
					"feature_ids": [cf.id], "color": b3.get("color",
						Color(0, 0, 0, 0))})
		elif f is MirrorBodyFeature:
			var mf := f as MirrorBodyFeature
			for b4: Dictionary in out.duplicate():
				if String(b4["id"]) != mf.source:
					continue
				out.append({"id": mf.id, "name": mf.name,
					"mesh": transformed_mesh(b4["mesh"],
						mf.mirror_transform()),
					"feature_ids": [mf.id], "color": b4.get("color",
						Color(0, 0, 0, 0))})
		elif f is PatternBodyFeature:
			var pf := f as PatternBodyFeature
			for b5: Dictionary in out.duplicate():
				if String(b5["id"]) != pf.source:
					continue
				var xfs := pf.instance_transforms()
				for k in xfs.size():
					out.append({"id": "%s:%d" % [pf.id, k + 1],
						"name": "%s %d" % [pf.name, k + 1],
						"mesh": transformed_mesh(b5["mesh"], xfs[k]),
						"feature_ids": [pf.id], "color": b5.get("color",
							Color(0, 0, 0, 0))})
	return out


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
