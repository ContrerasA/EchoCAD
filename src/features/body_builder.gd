class_name BodyBuilder
extends RefCounted
## Builds the document's BODIES from its live extrude features (M18).
## A body is the boolean result of one NEW_BODY extrude plus every later
## JOIN/CUT extrude whose prism touches it (AABB test), evaluated in
## timeline order — Fusion's operation dropdown semantics:
##   new_body — starts a solid of its own,
##   join     — unions into every body it touches (none touched: new body),
##   cut      — carves its prism out of every body it touches (none: no-op).
##
## Single-part bodies mesh through ExtrudeFeature.build_mesh (synchronous,
## exact, carries the edge-line overlay surface). Multi-part bodies bake
## through the engine's CSG, whose brushes update deferred — the scratch
## nodes must sit in the tree across one frame, so `build` is a COROUTINE
## and takes a host node. Callers await it.

## Coplanar boolean faces z-fight and confuse the CSG classifier; cut/hole
## prisms are extended by this much past both caps.
const EPS_MM := 0.05


## -> Array of {id: String (root feature id), name: String,
##              mesh: ArrayMesh, feature_ids: Array[String]}
static func build(doc: CadDocument, host: Node) -> Array:
	var bodies: Array = []
	for f in doc.live_features():
		if not (f is ExtrudeFeature):
			continue
		var ef := f as ExtrudeFeature
		var part := _part_of(doc, ef)
		if part.is_empty():
			continue
		match ef.operation:
			ExtrudeFeature.OP_JOIN:
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
			ExtrudeFeature.OP_CUT:
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
			var ef0: ExtrudeFeature = parts[0]["feature"]
			b["mesh"] = ef0.build_mesh(doc)
		else:
			var combiner := CSGCombiner3D.new()
			# Never rendered: the combiner exists only to be baked, and a
			# visible one paints the raw CSG brushes over the real body mesh
			# for however many frames the bake takes (the z-fighting ghost of
			# QA §M18.6, round two).
			combiner.visible = false
			for part: Dictionary in parts:
				var node := _prism_node(part)
				var ef_p: ExtrudeFeature = part["feature"]
				if ef_p.operation == ExtrudeFeature.OP_CUT:
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
		out.append({"id": b["id"], "name": b["name"], "mesh": b["mesh"],
			"feature_ids": b["feature_ids"]})
	return out


## True when the document needs no CSG pass — every live extrude is a plain
## NEW_BODY. Callers may then mesh synchronously (no frame wait).
static func all_new_body(doc: CadDocument) -> bool:
	for f in doc.live_features():
		if f is ExtrudeFeature \
				and (f as ExtrudeFeature).operation != ExtrudeFeature.OP_NEW_BODY:
			return false
	return true


static func _new_body(part: Dictionary) -> Dictionary:
	var ef: ExtrudeFeature = part["feature"]
	return {"id": ef.id, "name": ef.name, "parts": [part],
		"feature_ids": [ef.id], "aabb": part["aabb"], "mesh": null}


## Resolve a feature's prism: region + plane transform + world AABB.
static func _part_of(doc: CadDocument, ef: ExtrudeFeature) -> Dictionary:
	var sf := doc.sketch_feature(ef.sketch_id)
	if sf == null:
		return {}
	var prof := ProfileFinder.profile_at(sf.sketch, ef.anchor)
	if prof.is_empty():
		return {}
	var xf := sf.plane_transform()
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	var aabb := AABB()
	var first := true
	for z in [0.0, ef.distance]:
		for p in outer:
			var w: Vector3 = xf * Vector3(p.x, p.y, 0.0) + xf.basis.z * float(z)
			if first:
				aabb = AABB(w, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(w)
	return {"feature": ef, "prof": prof, "xf": xf,
		"aabb": aabb.grow(0.001)}


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


## A prism as a CSG node: the region's outer loop extruded `distance` along
## the plane normal, holes subtracted with a little overhang. CSGPolygon3D
## extrudes its local-XY polygon toward LOCAL -Z; for a positive distance
## the node is rotated PI about X (and the polygon y-mirrored to compensate)
## so -Z lands on +normal.
static func _prism_node(part: Dictionary) -> CSGShape3D:
	var prof: Dictionary = part["prof"]
	var ef: ExtrudeFeature = part["feature"]
	var xf: Transform3D = part["xf"]
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	var holes: Array = prof.get("holes", [])
	var d := absf(ef.distance)
	var up := ef.distance >= 0.0
	# CUT prisms extend EPS_MM past BOTH caps (the same trick the hole prisms
	# below use): a cut face coplanar with the target's cap leaves the CSG
	# classifier undecided and a zero-thickness cap skin behind (QA §M18.8).
	var cut := ef.operation == ExtrudeFeature.OP_CUT
	var z0 := EPS_MM if cut else 0.0
	var depth := maxf(d, 0.001) + (2.0 * EPS_MM if cut else 0.0)
	var lift := Transform3D(Basis.IDENTITY, Vector3(0, 0, z0))
	if cut:
		# LATERAL coplanarity leaves skins too: a cut flush with the target's
		# outer face (QA §M18.3 follow-up — the roof over the notch) puts a
		# cut wall exactly ON a body wall. Grow the cut profile sideways by
		# the same hair; kept islands (holes) shrink by it.
		var grown := _offset_ring(outer, EPS_MM)
		if grown.size() >= 3:
			outer = grown
		var kept: Array = []
		for h in holes:
			var hh := _offset_ring(h as PackedVector2Array, -EPS_MM)
			if hh.size() >= 3:
				kept.append(hh)
		holes = kept
	var local := Transform3D(Basis.from_euler(Vector3(PI, 0, 0)), Vector3.ZERO) \
		if up else Transform3D.IDENTITY

	var map_poly := func(p_poly: PackedVector2Array) -> PackedVector2Array:
		if not up:
			return p_poly.duplicate()
		var out_p := PackedVector2Array()
		for p in p_poly:
			out_p.append(Vector2(p.x, -p.y))
		return out_p

	var outer_node := CSGPolygon3D.new()
	outer_node.polygon = map_poly.call(outer)
	outer_node.depth = depth
	if holes.is_empty():
		outer_node.transform = xf * local * lift
		return outer_node
	var c := CSGCombiner3D.new()
	c.transform = xf * local
	outer_node.transform = lift
	c.add_child(outer_node)
	for h in holes:
		var hn := CSGPolygon3D.new()
		hn.polygon = map_poly.call(h)
		hn.depth = depth + 2.0 * EPS_MM
		hn.position = Vector3(0, 0, z0 + EPS_MM)
		hn.operation = CSGShape3D.OPERATION_SUBTRACTION
		c.add_child(hn)
	return c


## Offset a ccw ring by `by` mm (positive grows, negative shrinks; verified
## convention of Geometry2D.offset_polygon for ccw input). Offsetting can
## split a ring into several or collapse it entirely — the largest surviving
## ring wins, and an empty result comes back empty (callers skip the ring).
static func _offset_ring(poly: PackedVector2Array, by: float) -> PackedVector2Array:
	var res := Geometry2D.offset_polygon(poly, by, Geometry2D.JOIN_MITER)
	if res.is_empty():
		return PackedVector2Array()
	var best: PackedVector2Array = res[0]
	var best_a := absf(_ring_area(best))
	for r: PackedVector2Array in res:
		var a := absf(_ring_area(r))
		if a > best_a:
			best = r
			best_a = a
	return best


static func _ring_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return a * 0.5


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
