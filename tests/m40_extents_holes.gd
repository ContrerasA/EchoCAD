extends SceneTree

# M40: extrude extents (symmetric, two-sided, through all, to next, to
# object, taper) and the hole wizard (simple / counterbore / countersink,
# through all, drill tip, modelled thread, face-following, tables).

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M40_EXTENTS_HOLES OK: symmetric/two-sided/through-all/to-next/"
			+ "to-object extents, taper frustum, holes simple/cbore/csink/"
			+ "through/tip, modelled thread watertight, hole follows its face, "
			+ "tables, serialization")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m40_extents_holes: " + msg)
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


func _vol(bodies: Array, id: String) -> float:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return BodyBuilder.mesh_volume(b["mesh"])
	return -1.0


func _ext(fid: String, props: Dictionary) -> void:
	var batch := CmdMergeBatch.new("Edit Extrude", [])
	_root.stack.push_no_merge(batch)
	for k in props:
		_root.stack.push(CmdSetFeatureFlag.new(fid, k, props[k]))
	batch.seal()


func _watertight(mesh: ArrayMesh) -> bool:
	var s := SolidKernel.from_mesh(mesh, 1)
	return s != null and SolidKernel.is_valid(s)


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A. distance-type extents ------------------------------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(10, 10))
	var e1 := _root.extrude(s1, Vector2(5, 5), 10.0)
	await _idle()
	_ext(e1, {"extent": ExtrudeFeature.EXT_SYMMETRIC})
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var box := (bodies[0]["mesh"] as ArrayMesh).get_aabb()
	if absf(_vol(bodies, e1) - 2000.0) > 0.01 or absf(box.position.z + 10.0) > 1e-4:
		return _fail("A: symmetric (per side) should span -10..10: vol %f, z0 %f"
			% [_vol(bodies, e1), box.position.z])
	_ext(e1, {"symmetric_whole": true})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	box = (bodies[0]["mesh"] as ArrayMesh).get_aabb()
	if absf(_vol(bodies, e1) - 1000.0) > 0.01 or absf(box.position.z + 5.0) > 1e-4:
		return _fail("A: symmetric (whole) should span -5..5")
	_ext(e1, {"extent": ExtrudeFeature.EXT_TWO_SIDED, "distance": 5.0, "distance2": 3.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	box = (bodies[0]["mesh"] as ArrayMesh).get_aabb()
	if absf(_vol(bodies, e1) - 800.0) > 0.01 or absf(box.position.z + 3.0) > 1e-4 \
			or absf(box.end.z - 5.0) > 1e-4:
		return _fail("A: two-sided should span -3..5, got %f..%f" % [box.position.z, box.end.z])
	# Taper: 20x20 base... use the 10x10: frustum with 10° draft over h=10.
	_ext(e1, {"extent": ExtrudeFeature.EXT_DISTANCE, "distance": 10.0, "taper_deg": 10.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var top_side := 10.0 + 2.0 * 10.0 * tan(deg_to_rad(10.0))
	var a1 := 100.0
	var a2 := top_side * top_side
	var frustum := 10.0 / 3.0 * (a1 + a2 + sqrt(a1 * a2))
	if absf(_vol(bodies, e1) - frustum) > frustum * 1e-3:
		return _fail("A: taper frustum volume %f vs %f" % [_vol(bodies, e1), frustum])
	if not _watertight(bodies[0]["mesh"]):
		return _fail("A: tapered prism not watertight")
	_ext(e1, {"taper_deg": -10.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var small := 10.0 - 2.0 * 10.0 * tan(deg_to_rad(10.0))
	var frustum2 := 10.0 / 3.0 * (a1 + small * small + sqrt(a1 * small * small))
	if absf(_vol(bodies, e1) - frustum2) > frustum2 * 1e-3:
		return _fail("A: negative taper volume %f vs %f" % [_vol(bodies, e1), frustum2])
	for _i in 5:
		_root.stack.undo()   # back to the plain 10 mm extrude
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, e1) - 1000.0) > 0.01:
		return _fail("A: undo chain should restore the 10x10x10 box, got %f" % _vol(bodies, e1))

	# --- B. through all / to next / to object -------------------------------
	# Step block: box A z 0..10 (x 0..10) + box B z 0..20 at x 10..20, joined.
	var s2 := _sketch_rect("XY", Vector2(10, 0), Vector2(20, 10))
	var e2 := _root.extrude(s2, Vector2(15, 5), 20.0, SolidFeature.OP_JOIN)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 1 or absf(_vol(bodies, e1) - 3000.0) > 0.01:
		return _fail("B: step block volume %f" % _vol(bodies, e1))
	# Through-all cut from an offset plane below, across both steps.
	var pl := _root.create_offset_plane("XY", -20.0)
	var s3 := _sketch_rect(pl, Vector2(4, 4), Vector2(16, 6))
	var c3 := _root.extrude(s3, Vector2(10, 5), 1.0, SolidFeature.OP_CUT)
	_ext(c3, {"extent": ExtrudeFeature.EXT_THROUGH_ALL})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# Removes 6x2x10 from A and 6x2x20 from B.
	var want_b := 3000.0 - 6.0 * 2.0 * 10.0 - 6.0 * 2.0 * 20.0
	if absf(_vol(bodies, e1) - want_b) > 0.01:
		return _fail("B: through-all cut volume %f vs %f" % [_vol(bodies, e1), want_b])
	_root.stack.undo()
	_root.stack.undo()
	await _idle()
	# To next: a new body from the plane at z=-20 up to the block's underside.
	var s4 := _sketch_rect(pl, Vector2(2, 2), Vector2(8, 8))
	var e4 := _root.extrude(s4, Vector2(5, 5), 1.0)
	_ext(e4, {"extent": ExtrudeFeature.EXT_TO_NEXT})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, e4) - 36.0 * 20.0) > 0.01:
		return _fail("B: to-next should reach z=0 (36*20): got %f" % _vol(bodies, e4))
	var e4f := _root.doc.feature_by_id(e4) as Feature
	if e4f.rebuild_error != "":
		return _fail("B: to-next error: " + e4f.rebuild_error)
	# To object: the block's TOP face of step B (z=20).
	var face := _root.world.pick_face(Vector3(15, 5, 50), Vector3(0, 0, -1))
	if face.is_empty() or int(face.get("face", -1)) < 0:
		return _fail("B: could not pick the step-B top face")
	var ref := TopoRef.make(String(face["body"]), int(face["face"]), face["normal"], face["point"])
	_ext(e4, {"extent": ExtrudeFeature.EXT_TO_OBJECT, "to_ref": ref})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# The pillar 2..8 x 2..8 from z=-20 to z=20 overlaps block A (z 0..10) —
	# as a NEW body it simply spans 40 mm.
	if absf(_vol(bodies, e4) - 36.0 * 40.0) > 0.01:
		return _fail("B: to-object should reach z=20 (36*40): got %f" % _vol(bodies, e4))
	# Change the block height: the to-object pillar follows.
	_ext(e2, {"distance": 30.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, e4) - 36.0 * 50.0) > 0.01:
		return _fail("B: to-object should follow the face to z=30: got %f" % _vol(bodies, e4))
	# Serialization of the extent fields.
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var le4 := loaded.feature_by_id(e4) as ExtrudeFeature
	if le4 == null or le4.extent != ExtrudeFeature.EXT_TO_OBJECT or le4.to_ref == null \
			or le4.to_ref.body != String(face["body"]):
		return _fail("B: extent/to_ref lost in round trip")
	_root.stack.undo()   # block height
	_root.stack.undo()   # to-object
	_root.stack.undo()   # to-next
	_root.stack.undo()   # e4
	_root.stack.undo()   # s4
	await _idle()

	# --- C. holes -----------------------------------------------------------
	_root.load_document(CadDocument.new())
	await _idle()
	var p1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var plate := _root.extrude(p1, Vector2(20, 15), 10.0)
	await _idle()
	var top := _root.world.pick_face(Vector3(20, 15, 50), Vector3(0, 0, -1))
	if top.is_empty():
		return _fail("C: no plate top face")
	var h := HoleFeature.new()
	h.id = _root.doc.next_feature_id()
	h.name = "Hole1"
	h.ref = TopoRef.make(String(top["body"]), int(top["face"]), top["normal"], top["point"])
	h.plane_xf = PlaneFeature.face_transform(top["point"], top["normal"])
	h.uv = [Vector2(10, 15), Vector2(30, 15)]
	h.diameter = 6.0
	h.extent = HoleFeature.EXT_THROUGH_ALL
	_root.stack.push_no_merge(CmdAddFeature.new(h))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_c := 12000.0 - 2.0 * PI * 9.0 * 10.0
	# The lathe is a 48-gon: area ratio sin(2π/48)·48/(2π) ≈ 0.99715.
	var poly_k := sin(TAU / 48.0) * 48.0 / TAU
	var want_c_poly := 12000.0 - 2.0 * PI * 9.0 * 10.0 * poly_k
	if absf(_vol(bodies, plate) - want_c_poly) > 0.05:
		return _fail("C: two through holes: %f vs %f (analytic %f)"
			% [_vol(bodies, plate), want_c_poly, want_c])
	if h.rebuild_error != "":
		return _fail("C: hole error: " + h.rebuild_error)
	if not _watertight(bodies[0]["mesh"]):
		return _fail("C: holed plate not watertight")
	# Blind hole with a 118° tip: depth 6, r=3 -> cone height r/tan(59°).
	_ext(h.id, {"extent": HoleFeature.EXT_DISTANCE, "depth": 6.0, "uv": [Vector2(20, 15)]})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var cone_h := 3.0 / tan(deg_to_rad(59.0))
	var want_blind := 12000.0 - (PI * 9.0 * 6.0 + PI * 9.0 * cone_h / 3.0) * poly_k
	if absf(_vol(bodies, plate) - want_blind) > 0.05:
		return _fail("C: blind hole with tip: %f vs %f" % [_vol(bodies, plate), want_blind])
	# Counterbore M6 (6.6 through, 11 x 6.5 cbore).
	_ext(h.id, {"hole_type": HoleFeature.TYPE_COUNTERBORE, "extent": HoleFeature.EXT_THROUGH_ALL,
		"diameter": 6.6, "cb_diameter": 11.0, "cb_depth": 6.5})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want_cb := 12000.0 - (PI * 3.3 * 3.3 * 10.0 + PI * (5.5 * 5.5 - 3.3 * 3.3) * 6.5) * poly_k
	if absf(_vol(bodies, plate) - want_cb) > 0.05:
		return _fail("C: counterbore: %f vs %f" % [_vol(bodies, plate), want_cb])
	# Countersink 90°, 12.6 dia: cone from r 6.3 at the face to r 3.3.
	_ext(h.id, {"hole_type": HoleFeature.TYPE_COUNTERSINK, "cs_diameter": 12.6, "cs_angle": 90.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var cs_h := (6.3 - 3.3) / tan(deg_to_rad(45.0))
	var cone_frustum := PI * cs_h / 3.0 * (6.3 * 6.3 + 3.3 * 3.3 + 6.3 * 3.3)
	var want_cs := 12000.0 - (PI * 3.3 * 3.3 * 10.0 + (cone_frustum - PI * 3.3 * 3.3 * cs_h)) * poly_k
	if absf(_vol(bodies, plate) - want_cs) > 0.1:
		return _fail("C: countersink: %f vs %f" % [_vol(bodies, plate), want_cs])
	# Modelled M6 thread: volume between the minor and major bores, watertight.
	var m6 := HoleTable.find("M6")
	if m6.is_empty() or absf(float(m6["pitch"]) - 1.0) > 1e-9:
		return _fail("C: hole table missing M6")
	_ext(h.id, {"hole_type": HoleFeature.TYPE_SIMPLE, "diameter": HoleTable.tap_drill(m6),
		"thread_mode": HoleFeature.THREAD_MODELED, "thread_id": "M6"})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var r_minor := HoleTable.tap_drill(m6) * 0.5
	var v_minor := 12000.0 - PI * r_minor * r_minor * 10.0 * poly_k
	var v_major := 12000.0 - PI * 9.0 * 10.0 * poly_k
	var got_t := _vol(bodies, plate)
	if not (got_t < v_minor - 1.0 and got_t > v_major + 1.0):
		return _fail("C: threaded volume %f should sit between major %f and minor %f"
			% [got_t, v_major, v_minor])
	if not _watertight(bodies[0]["mesh"]):
		return _fail("C: threaded hole body not watertight")
	if h.rebuild_error != "":
		return _fail("C: thread error: " + h.rebuild_error)
	# The hole follows its face: raise the plate, the hole still starts at the top.
	_ext(plate, {"distance": 16.0})
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(h.plane_xf.origin.z - 16.0) > 1e-6:
		return _fail("C: hole plane should follow to z=16, got %f" % h.plane_xf.origin.z)
	var top_z := (bodies[0]["mesh"] as ArrayMesh).get_aabb().end.z
	if absf(top_z - 16.0) > 1e-4 or _vol(bodies, plate) >= 40.0 * 30.0 * 16.0 - 1.0:
		return _fail("C: raised plate should still be drilled")
	# Serialization.
	var loaded2 := Serializer.from_json(Serializer.to_json(_root.doc))
	var lh := loaded2.feature_by_id(h.id) as HoleFeature
	if lh == null or lh.uv.size() != 1 or lh.thread_mode != HoleFeature.THREAD_MODELED \
			or lh.ref == null or lh.ref.body != plate or lh.kind() != "hole":
		return _fail("C: hole lost in round trip")
	var lb: Array = await BodyBuilder.build(loaded2, _root)
	if absf(_vol(lb, plate) - _vol(bodies, plate)) > 1e-3:
		return _fail("C: loaded hole volume differs")
	# Table sanity.
	if HoleTable.find("1/4-20").is_empty() or HoleTable.preset_labels().size() < 12:
		return _fail("C: hole table incomplete")
	return true
