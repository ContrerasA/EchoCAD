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
			(s["body"] as Dictionary)["mesh"] = combiner.bake_static_mesh()
			combiner.queue_free()

	var out: Array = []
	for b: Dictionary in bodies:
		if b.get("mesh") == null:
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
	outer_node.depth = maxf(d, 0.001)
	if holes.is_empty():
		outer_node.transform = xf * local
		return outer_node
	var c := CSGCombiner3D.new()
	c.transform = xf * local
	c.add_child(outer_node)
	for h in holes:
		var hn := CSGPolygon3D.new()
		hn.polygon = map_poly.call(h)
		hn.depth = maxf(d, 0.001) + 2.0 * EPS_MM
		hn.position = Vector3(0, 0, EPS_MM)
		hn.operation = CSGShape3D.OPERATION_SUBTRACTION
		c.add_child(hn)
	return c


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
