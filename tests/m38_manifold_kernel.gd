extends SceneTree

# M38: the Manifold kernel behind BodyBuilder — exact booleans, face ids
# that survive cuts, watertight results under random boolean chains,
# per-feature rebuild errors (red chips) and a rebuild time budget.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M38_MANIFOLD_KERNEL OK: box booleans analytic, cut keeps both "
			+ "features' face ids, 40-step random chain watertight, consumed "
			+ "body vanishes, no-target cut flags its chip, 30-feature rebuild "
			+ "under budget, edge overlay on boolean bodies")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m38_manifold_kernel: " + msg)
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
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	return fid


## Every edge of a welded triangle mesh is shared by exactly two triangles.
func _watertight(solid: RefCounted) -> bool:
	var m: Dictionary = solid.call("to_mesh")
	var idx: PackedInt32Array = m["indices"]
	var count := {}
	for t in range(0, idx.size(), 3):
		for e in 3:
			var i0 := idx[t + e]
			var i1 := idx[t + (e + 1) % 3]
			var k := Vector2i(mini(i0, i1), maxi(i0, i1))
			count[k] = int(count.get(k, 0)) + 1
	for k in count:
		if int(count[k]) != 2:
			return false
	return true


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	if not SolidKernel.available():
		return _fail("MeshSolid class missing — geometry addon not loaded")

	# --- A: kernel booleans against analytic volumes ------------------------
	var box := func(size: Vector3, at: Vector3) -> RefCounted:
		var b: RefCounted = ClassDB.class_call_static("MeshSolid", "make_box", size, false)
		return b.call("transformed", Transform3D(Basis.IDENTITY, at))
	var a: RefCounted = box.call(Vector3(10, 10, 10), Vector3.ZERO)
	var b: RefCounted = box.call(Vector3(10, 10, 10), Vector3(5, 5, 5))
	var u: RefCounted = SolidKernel.boolean(a, b, SolidFeature.OP_JOIN)
	var d: RefCounted = SolidKernel.boolean(a, b, SolidFeature.OP_CUT)
	var i: RefCounted = SolidKernel.boolean(a, b, SolidFeature.OP_INTERSECT)
	for pair in [[u, 1875.0], [d, 875.0], [i, 125.0]]:
		if absf(SolidKernel.volume(pair[0]) - float(pair[1])) > 1e-6:
			return _fail("box boolean volume %f, want %f"
				% [SolidKernel.volume(pair[0]), float(pair[1])])
	if not _watertight(u) or not _watertight(d):
		return _fail("box boolean result not watertight")

	# --- B: unwelded flat-shaded soup (what generators emit) round-trips ----
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 6, 8)
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bm.get_mesh_arrays())
	var soup := SolidKernel.from_mesh(am, 7)
	if soup == null:
		return _fail("box soup rejected: " + SolidKernel.last_error)
	if absf(SolidKernel.volume(soup) - 192.0) > 1e-6:
		return _fail("soup volume %f" % SolidKernel.volume(soup))
	var faces := SolidKernel.local_faces(SolidKernel.triangles_of(am))
	var distinct := {}
	for f in faces:
		distinct[f] = true
	if distinct.size() != 6:
		return _fail("box should group into 6 faces, got %d" % distinct.size())
	var tm := SolidKernel.to_mesh(soup)
	var ids := {}
	for f in (tm["face_ids"] as PackedInt32Array):
		ids[f >> SolidKernel.FACE_SHIFT] = true
	if ids.size() != 1 or not ids.has(7):
		return _fail("face ids lost the feature ordinal: %s" % str(ids))
	if (tm["mesh"] as ArrayMesh).get_surface_count() != 2:
		return _fail("kernel mesh should carry an edge overlay surface")
	# A box has 12 edges = 24 line vertices.
	var edge_verts: int = ((tm["mesh"] as ArrayMesh).surface_get_arrays(1)[
		Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if edge_verts != 24:
		return _fail("box edge overlay should have 12 edges, got %d" % (edge_verts / 2))

	# --- C: random boolean chain stays watertight ---------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = 38
	var chain: RefCounted = box.call(Vector3(30, 30, 30), Vector3.ZERO)
	for k in 40:
		var size := Vector3(rng.randf_range(3, 20), rng.randf_range(3, 20),
			rng.randf_range(3, 20))
		var at := Vector3(rng.randf_range(-5, 25), rng.randf_range(-5, 25),
			rng.randf_range(-5, 25))
		var tool: RefCounted = box.call(size, at)
		if rng.randf() < 0.3:
			tool = tool.call("transformed", Transform3D(
				Basis(Vector3(0, 0, 1), rng.randf_range(0, TAU)), Vector3.ZERO))
		var op := SolidFeature.OP_JOIN if k % 2 == 0 else SolidFeature.OP_CUT
		var res: RefCounted = SolidKernel.boolean(chain, tool, op)
		if not SolidKernel.is_valid(res):
			return _fail("chain step %d produced an invalid solid: %s"
				% [k, res.call("status")])
		chain = res
	if not _watertight(chain):
		return _fail("random chain result not watertight")
	if SolidKernel.volume(chain) <= 0.0:
		return _fail("random chain volume not positive")

	# --- D: through the document — plate, cut, face ids from both ---------
	var f1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	if _root.extrude(f1, Vector2(20, 15), 10.0) == "":
		return _fail("plate extrude refused")
	await _idle()
	var f3 := _sketch_rect("XY", Vector2(10, 10), Vector2(20, 20))
	_root.finish_sketch()
	if _root.extrude(f3, Vector2(15, 15), 10.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("pocket cut refused")
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 1:
		return _fail("expected one body, got %d" % bodies.size())
	var body: Dictionary = bodies[0]
	var want := 40.0 * 30.0 * 10.0 - 10.0 * 10.0 * 10.0
	if absf(BodyBuilder.mesh_volume(body["mesh"]) - want) > 2.0:
		return _fail("pocket volume %f, want %f"
			% [BodyBuilder.mesh_volume(body["mesh"]), want])
	if body.get("solid") == null:
		return _fail("body carries no kernel solid")
	var feats := {}
	for f in (body["face_ids"] as PackedInt32Array):
		feats[f >> SolidKernel.FACE_SHIFT] = true
	if feats.size() != 2:
		return _fail("pocket body should carry face ids of 2 features, got %s"
			% str(feats))
	if (body["mesh"] as ArrayMesh).get_surface_count() != 2:
		return _fail("boolean body lost its edge overlay")
	for f in _root.doc.live_features():
		if (f as Feature).rebuild_error != "":
			return _fail("unexpected rebuild error on %s: %s"
				% [(f as Feature).name, (f as Feature).rebuild_error])

	# --- E: a cut touching nothing flags its chip (and only its chip) -------
	var f5 := _sketch_rect("XY", Vector2(200, 200), Vector2(210, 210))
	_root.finish_sketch()
	var cut_id := _root.extrude(f5, Vector2(205, 205), 5.0, ExtrudeFeature.OP_CUT)
	if cut_id == "":
		return _fail("far cut refused")
	await _idle()
	var cut_f := _root.doc.feature_by_id(cut_id)
	if cut_f == null or cut_f.rebuild_error == "":
		return _fail("no-target cut should carry a rebuild error")
	var chip := _root.timeline.find_child("Chip_" + cut_id, true, false) as Button
	if chip == null or chip.theme_type_variation != "TimelineChipError":
		return _fail("no-target cut chip should use TimelineChipError, got %s"
			% (chip.theme_type_variation if chip != null else "<none>"))
	if not chip.tooltip_text.contains(cut_f.rebuild_error):
		return _fail("error chip tooltip should carry the reason")
	var plate_chip := _root.timeline.find_child("Chip_" + _root.doc.live_features()[1].id,
		true, false) as Button
	if plate_chip != null and plate_chip.theme_type_variation == "TimelineChipError":
		return _fail("healthy feature chip must not be error-tinted")

	# --- F: consuming cut leaves no body ------------------------------------
	var f7 := _sketch_rect("XY", Vector2(-5, -5), Vector2(45, 35))
	_root.finish_sketch()
	if _root.extrude(f7, Vector2(20, 16), 12.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("consuming cut refused")
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if not bodies.is_empty():
		return _fail("consumed body should vanish, got %d bodies" % bodies.size())
	_root.stack.undo()
	_root.stack.undo()
	await _idle()

	# --- G: rebuild budget — 30 features ------------------------------------
	for k in 14:
		var fs := _sketch_rect("XY", Vector2(2 + k * 2.5, 2), Vector2(3.5 + k * 2.5, 8))
		_root.finish_sketch()
		_root.extrude(fs, Vector2(2.75 + k * 2.5, 5), 10.0, ExtrudeFeature.OP_CUT)
	await _idle()
	var t0 := Time.get_ticks_msec()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var dt := Time.get_ticks_msec() - t0
	if bodies.size() != 1:
		return _fail("budget document should still be one body, got %d" % bodies.size())
	if dt > 3000:
		return _fail("30-feature rebuild took %d ms (budget 3000)" % dt)
	return true
