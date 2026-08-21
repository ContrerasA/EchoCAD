extends SceneTree

# M41: fillet / chamfer on any edge chain — straight convex edges, a hole
# rim on a boolean body, a concave pocket-floor edge (join), all four top
# edges with ball corners, edge refs healing after an upstream edit,
# serialization.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M41_EDGE_FILLET OK: chain census + convexity, chamfer + fillet "
			+ "volumes analytic, hole rim after a cut, concave join fillet, "
			+ "four-edge rim with ball corners watertight, refs survive an "
			+ "upstream edit, serialization")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m41_edge_fillet: " + msg)
	return false


func _click(world: Vector2) -> void:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	_root.tools.handle_pointer_move(world, screen, InputEventMouseMotion.new())
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(world, screen, down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(world, screen, up)


func _sketch_rect(plane: String, a: Vector2, b: Vector2) -> String:
	var fid := _root.create_sketch(plane)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view((a + b) * 0.5, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	_root.finish_sketch()
	return fid


func _entry(bodies: Array, id: String) -> Dictionary:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return b
	return {}


func _vol(bodies: Array, id: String) -> float:
	var e := _entry(bodies, id)
	return BodyBuilder.mesh_volume(e["mesh"]) if not e.is_empty() else -1.0


func _watertight(mesh: ArrayMesh) -> bool:
	var s := SolidKernel.from_mesh(mesh, 1)
	return s != null and SolidKernel.is_valid(s)


## Chains whose midpoint matches a predicate.
func _chains_where(chains: Array, pred: Callable) -> Array:
	var out: Array = []
	for ch: Dictionary in chains:
		if pred.call(ch):
			out.append(ch)
	return out


func _edge_ref(ch: Dictionary) -> Dictionary:
	var parts: PackedStringArray = String(ch["key"]).split("|")
	return {"fa": int(ch["fa"]), "fb": int(ch["fb"]), "k": int(parts[2]),
		"hint": EdgeFilletFeature.chain_midpoint(ch)}


func _add_fillet(body: String, treat: String, size: float, refs: Array) -> String:
	var f := EdgeFilletFeature.new()
	f.id = _root.doc.next_feature_id()
	f.name = _root.doc.auto_name("Fillet" if treat == EdgeFilletFeature.KIND_FILLET else "Chamfer")
	f.body = body
	f.treat = treat
	f.size_mm = size
	f.edges = refs
	_root.stack.push_no_merge(CmdAddFeature.new(f))
	return f.id


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A. census: a 40x30x10 box has 12 convex chains ---------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var box := _root.extrude(s1, Vector2(20, 15), 10.0)
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var chains := SolidKernel.edge_chains(_entry(bodies, box))
	if chains.size() != 12:
		return _fail("A: box should have 12 edge chains, got %d" % chains.size())
	for ch: Dictionary in chains:
		if not bool(ch["convex"]) or bool(ch["closed"]) or (ch["points"] as PackedVector3Array).size() != 2:
			return _fail("A: box chains should be straight, open and convex")
	# The top edge along x at y=0 (midpoint (20, 0, 10)).
	var top_front := _chains_where(chains, func(ch): return EdgeFilletFeature.chain_midpoint(ch).distance_to(Vector3(20, 0, 10)) < 1e-3)
	if top_front.size() != 1:
		return _fail("A: expected one chain at (20,0,10), got %d" % top_front.size())

	# --- B. chamfer one straight edge: removes d²/2 * length ---------------
	var ch_id := _add_fillet(box, EdgeFilletFeature.KIND_CHAMFER, 3.0, [_edge_ref(top_front[0])])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_ch := 12000.0 - 0.5 * 3.0 * 3.0 * 40.0
	if absf(_vol(bodies, box) - want_ch) > 0.05:
		return _fail("B: chamfer volume %f vs %f (%s)" % [_vol(bodies, box), want_ch,
			(_root.doc.feature_by_id(ch_id) as Feature).rebuild_error])
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("B: chamfered body not watertight")
	_root.stack.undo()
	await _idle()

	# --- C. fillet the same edge: removes (r² - πr²/4) * length ------------
	var fi_id := _add_fillet(box, EdgeFilletFeature.KIND_FILLET, 3.0, [_edge_ref(top_front[0])])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var seg := 9.0 - PI * 9.0 / 4.0
	# The arc is a 10-segment polyline: chord area is slightly less.
	var poly_arc := 0.5 * 9.0 * (PI / 2.0 - sin(PI / 2.0 / 10.0) * 10.0)  # area between arc and chords
	var want_fi := 12000.0 - (seg + poly_arc) * 40.0
	if absf(_vol(bodies, box) - want_fi) > want_fi * 2e-4:
		return _fail("C: fillet volume %f vs %f" % [_vol(bodies, box), want_fi])
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("C: filleted body not watertight")
	_root.stack.undo()
	await _idle()

	# --- D. hole rim on a boolean body + concave pocket floor ---------------
	var s2 := _sketch_rect("XY", Vector2(10, 10), Vector2(20, 20))
	var pocket := _root.extrude(s2, Vector2(15, 15), 5.0, SolidFeature.OP_CUT)
	# Cut from z=0 up 5: a pocket open at the BOTTOM face. Use a top pocket
	# instead: sketch on the top face plane via an offset plane at z=10.
	_root.stack.undo()
	await _idle()
	var pl := _root.create_offset_plane("XY", 10.0)
	var s3 := _sketch_rect(pl, Vector2(10, 10), Vector2(20, 20))
	pocket = _root.extrude(s3, Vector2(15, 15), -5.0, SolidFeature.OP_CUT)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	chains = SolidKernel.edge_chains(_entry(bodies, box))
	# Pocket floor edges are concave (z=5 plane, y=10 side: midpoint (15,10,5)).
	var floor_edge := _chains_where(chains, func(ch): return EdgeFilletFeature.chain_midpoint(ch).distance_to(Vector3(15, 10, 5)) < 1e-3)
	if floor_edge.size() != 1 or bool(floor_edge[0]["convex"]):
		var dbg := ""
		for ch: Dictionary in chains:
			dbg += "%s %s cvx=%s closed=%s n=%d; " % [ch["key"], str(EdgeFilletFeature.chain_midpoint(ch)), str(ch["convex"]), str(ch["closed"]), (ch["points"] as PackedVector2Array).size() if false else (ch["points"] as PackedVector3Array).size()]
		return _fail("D: pocket floor edge should be one CONCAVE chain (%d) vol=%f chains=%s" % [floor_edge.size(), _vol(bodies, box), dbg])
	# Pocket rim edges at z=10 are convex.
	var rim_edge := _chains_where(chains, func(ch): return EdgeFilletFeature.chain_midpoint(ch).distance_to(Vector3(15, 10, 10)) < 1e-3)
	if rim_edge.size() != 1 or not bool(rim_edge[0]["convex"]):
		return _fail("D: pocket rim edge should be convex")
	var v0 := _vol(bodies, box)
	var cf_id := _add_fillet(box, EdgeFilletFeature.KIND_FILLET, 2.0, [_edge_ref(floor_edge[0])])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var seg2 := 4.0 - PI * 4.0 / 4.0
	var poly_arc2 := 0.5 * 4.0 * (PI / 2.0 - sin(PI / 2.0 / 10.0) * 10.0)
	var want_cf := v0 + (seg2 + poly_arc2) * 10.0
	if absf(_vol(bodies, box) - want_cf) > 0.05:
		return _fail("D: concave fillet should ADD material: %f vs %f (%s)" % [_vol(bodies, box), want_cf,
			(_root.doc.feature_by_id(cf_id) as Feature).rebuild_error])
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("D: concave fillet body not watertight")
	_root.stack.undo()
	await _idle()
	# A round hole through the plate: its top rim is ONE closed chain.
	var h := HoleFeature.new()
	h.id = _root.doc.next_feature_id()
	h.name = "Hole1"
	var top := _root.world.pick_face(Vector3(30, 15, 50), Vector3(0, 0, -1))
	h.ref = TopoRef.make(String(top["body"]), int(top["face"]), top["normal"], top["point"])
	h.plane_xf = PlaneFeature.face_transform(top["point"], top["normal"])
	h.uv = [Vector2(30, 15)]
	h.diameter = 8.0
	h.extent = HoleFeature.EXT_THROUGH_ALL
	_root.stack.push_no_merge(CmdAddFeature.new(h))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	chains = SolidKernel.edge_chains(_entry(bodies, box))
	var rims := _chains_where(chains, func(ch): return bool(ch["closed"]) and absf(EdgeFilletFeature.chain_midpoint(ch).z - 10.0) < 1e-3 and EdgeFilletFeature.chain_midpoint(ch).distance_to(Vector3(30, 15, 10)) < 0.5)
	if rims.size() != 1 or (rims[0]["points"] as PackedVector3Array).size() < 40:
		return _fail("D: hole top rim should be one closed 48-gon chain (%d)" % rims.size())
	var vh := _vol(bodies, box)
	var rim_id := _add_fillet(box, EdgeFilletFeature.KIND_CHAMFER, 1.0, [_edge_ref(rims[0])])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# Chamfer ring volume ≈ rotating the triangle (legs 1,1) about the axis
	# at radius 4+1/3 (centroid): A = 0.5, V = 2π·(4 + 1/3)·0.5.
	var want_rim := vh - TAU * (4.0 + 1.0 / 3.0) * 0.5
	if absf(_vol(bodies, box) - want_rim) > 0.2:
		return _fail("D: hole rim chamfer %f vs %f (%s)" % [_vol(bodies, box), want_rim,
			(_root.doc.feature_by_id(rim_id) as Feature).rebuild_error])
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("D: rim-chamfered body not watertight")

	# --- E. refs survive an upstream edit (plate grows): chamfer follows ---
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(box, "distance", 14.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var rf := _root.doc.feature_by_id(rim_id) as EdgeFilletFeature
	if rf.rebuild_error != "":
		return _fail("E: chamfer should re-find the rim after the edit: " + rf.rebuild_error)
	var top_z := (_entry(bodies, box)["mesh"] as ArrayMesh).get_aabb().end.z
	if absf(top_z - 14.0) > 1e-4:
		return _fail("E: plate top should be 14")
	# Volume: 14-tall plate minus pocket(5 deep from 14) minus hole minus rim chamfer.
	var poly_k := sin(TAU / 48.0) * 48.0 / TAU
	var want_e := 40.0 * 30.0 * 14.0 - 500.0 - PI * 16.0 * 14.0 * poly_k - TAU * (4.0 + 1.0 / 3.0) * 0.5
	if absf(_vol(bodies, box) - want_e) > 0.3:
		return _fail("E: after edit %f vs %f" % [_vol(bodies, box), want_e])
	_root.stack.undo()
	_root.stack.undo()
	_root.stack.undo()   # rim chamfer, hole... keep the plate + pocket
	await _idle()

	# --- F. all four top edges filleted with ball corners -------------------
	_root.stack.undo()   # pocket
	_root.stack.undo()   # s3
	_root.stack.undo()   # plane
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	chains = SolidKernel.edge_chains(_entry(bodies, box))
	var top_edges := _chains_where(chains, func(ch): return absf(EdgeFilletFeature.chain_midpoint(ch).z - 10.0) < 1e-3 and (ch["points"] as PackedVector3Array).size() == 2 and absf(((ch["points"] as PackedVector3Array)[0].z) - 10.0) < 1e-3 and absf(((ch["points"] as PackedVector3Array)[1].z) - 10.0) < 1e-3)
	if top_edges.size() != 4:
		return _fail("F: expected 4 top rim edges, got %d" % top_edges.size())
	var refs: Array = []
	for ch in top_edges:
		refs.append(_edge_ref(ch))
	var four := _add_fillet(box, EdgeFilletFeature.KIND_FILLET, 3.0, refs)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if not _watertight(_entry(bodies, box)["mesh"]):
		return _fail("F: four-edge fillet not watertight")
	# Bands: (40-6)+(30-6) twice = 116 mm of straight band (the corners are
	# handled by the overshoot + ball tool); corners: a cube 27 minus a
	# sphere octant... bound check: between the no-corner estimate and the
	# full analytic with spherical corners.
	var band := (seg + poly_arc) * (2.0 * 34.0 + 2.0 * 24.0)
	var corner_full := 4.0 * (27.0 - 4.0 / 3.0 * PI * 27.0 / 8.0)   # cube minus sphere octant
	var got := _vol(bodies, box)
	if got > 12000.0 - band - corner_full * 0.5 or got < 12000.0 - band - corner_full * 1.3:
		return _fail("F: four-edge fillet volume %f outside [%f, %f]" % [got,
			12000.0 - band - corner_full * 1.3, 12000.0 - band - corner_full * 0.5])
	var ff := _root.doc.feature_by_id(four) as EdgeFilletFeature
	if ff.rebuild_error != "":
		return _fail("F: " + ff.rebuild_error)

	# --- G. serialization ---------------------------------------------------
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var lf := loaded.feature_by_id(four) as EdgeFilletFeature
	if lf == null or lf.edges.size() != 4 or lf.kind() != "edge_fillet":
		return _fail("G: fillet lost in round trip")
	var lb: Array = await BodyBuilder.build(loaded, _root)
	if absf(_vol(lb, box) - got) > 1e-3:
		return _fail("G: loaded volume differs")
	return true
