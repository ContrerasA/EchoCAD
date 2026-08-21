extends SceneTree

# M47: incremental rebuild correctness (cached result == fresh result after
# edits anywhere in the timeline, undo, delete, suppress) and speed (an
# edit of the last feature costs a fraction of a full rebuild); a seeded
# fuzz of random feature chains never crashes, never yields a non-manifold
# body, and round-trips through the serializer.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M47_PERF_FUZZ OK: incremental rebuild matches a fresh build through "
			+ "edits/undo/delete/suppress, last-feature edit is cheap, 60-step "
			+ "random chain watertight + serializable")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m47_perf_fuzz: " + msg)
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


## Volumes per body id, from a FRESH build (cache dropped) and from the
## cached path; they must agree.
func _vols_both() -> Array:
	var cached: Array = await BodyBuilder.build(_root.doc, _root)
	BodyBuilder.invalidate(_root.doc)
	var fresh: Array = await BodyBuilder.build(_root.doc, _root)
	var a := {}
	var b := {}
	for e: Dictionary in cached:
		a[String(e["id"])] = BodyBuilder.mesh_volume(e["mesh"])
	for e: Dictionary in fresh:
		b[String(e["id"])] = BodyBuilder.mesh_volume(e["mesh"])
	return [a, b]


func _same(pair: Array) -> bool:
	var a: Dictionary = pair[0]
	var b: Dictionary = pair[1]
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or absf(float(a[k]) - float(b[k])) > 1e-6:
			return false
	return true


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A. incremental == fresh through a series of edits ----------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(60, 40))
	var plate := _root.extrude(s1, Vector2(30, 20), 10.0)
	var cuts: Array = []
	for k in 6:
		var sk := _sketch_rect("XY", Vector2(5 + k * 9, 5), Vector2(10 + k * 9, 12))
		cuts.append(_root.extrude(sk, Vector2(7.5 + k * 9, 8.5), 10.0, SolidFeature.OP_CUT))
	var s2 := _sketch_rect("XY", Vector2(70, 0), Vector2(90, 20))
	var box2 := _root.extrude(s2, Vector2(80, 10), 8.0)
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: first build mismatch")
	# Edit the middle cut.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cuts[3], "distance", 4.0))
	await _idle()
	var pair := await _vols_both()
	if not _same(pair):
		return _fail("A: edit of a middle feature: cached %s vs fresh %s" % [str(pair[0]), str(pair[1])])
	# Edit the first feature (everything downstream).
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(plate, "distance", 14.0))
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: edit of the root feature")
	# Suppress one cut, then unsuppress.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(cuts[1], "suppressed", true))
	await _idle()
	pair = await _vols_both()
	# 60x40x14 plate, four 5x7 cuts 10 deep, one 4 deep, one suppressed.
	if not _same(pair) or absf(float(pair[0][plate]) - (60.0 * 40.0 * 14.0 - 4.0 * 35.0 * 10.0 - 35.0 * 4.0)) > 0.5:
		return _fail("A: suppress: %s" % str(pair[0]))
	_root.stack.undo()
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: unsuppress via undo")
	# Delete a cut outright.
	_root.request_delete_feature(cuts[5])
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: delete")
	# Roll back the marker and forward.
	_root.stack.push_no_merge(CmdSetMarker.new(_root.doc.timeline_marker, 4))
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: rollback")
	_root.stack.undo()
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: roll forward")
	# A fresh build after undoing everything back to the plate matches too.
	for _i in 3:
		_root.stack.undo()
	await _idle()
	if not _same(await _vols_both()):
		return _fail("A: after undos")

	# --- B. speed: editing the last feature vs a full rebuild ------------------
	BodyBuilder.invalidate(_root.doc)
	var t0 := Time.get_ticks_usec()
	await BodyBuilder.build(_root.doc, _root)
	var full := Time.get_ticks_usec() - t0
	var last_cut: String = cuts[4]
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(last_cut, "distance", 5.0))
	# The world rebuild after the push already refreshed the cache; time the
	# incremental build of a NEW edit directly.
	_root.doc.feature_by_id(last_cut).set("distance", 6.0)
	var t1 := Time.get_ticks_usec()
	await BodyBuilder.build(_root.doc, _root)
	var incr := Time.get_ticks_usec() - t1
	if full > 20000 and incr > full * 0.6:
		return _fail("B: last-feature edit %d us should be well under a full rebuild %d us" % [incr, full])
	var t2 := Time.get_ticks_usec()
	await BodyBuilder.build(_root.doc, _root)
	var hit := Time.get_ticks_usec() - t2
	if hit > maxi(full / 4, 3000):
		return _fail("B: an unchanged document should rebuild from cache in a few ms (%d us vs %d us)" % [hit, full])

	# --- C. seeded fuzz: random chain of solid features -----------------------------
	_root.load_document(CadDocument.new())
	_root.stack.mark_saved()
	await _idle()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4747
	var base := _sketch_rect("XY", Vector2(0, 0), Vector2(50, 50))
	var root := _root.extrude(base, Vector2(25, 25), 20.0)
	await _idle()
	var steps := 0
	for i in 60:
		var kind := rng.randi_range(0, 6)
		var x := rng.randf_range(2, 40)
		var y := rng.randf_range(2, 40)
		var w := rng.randf_range(3, 10)
		var hgt := rng.randf_range(2, 25)
		match kind:
			0, 1:
				var sk := _sketch_rect("XY", Vector2(x, y), Vector2(x + w, y + w))
				_root.extrude(sk, Vector2(x + w * 0.5, y + w * 0.5), hgt,
					SolidFeature.OP_CUT if kind == 0 else SolidFeature.OP_JOIN)
			2:
				var pl := _root.create_offset_plane("XY", 20.0)
				var sk2 := _sketch_rect(pl, Vector2(x, y), Vector2(x + w, y + w))
				var e := _root.extrude(sk2, Vector2(x + w * 0.5, y + w * 0.5), -hgt, SolidFeature.OP_CUT)
				if rng.randf() < 0.5 and e != "":
					_root.stack.push_no_merge(CmdSetFeatureFlag.new(e, "taper_deg", rng.randf_range(-5, 5)))
			3:
				var bodies: Array = await BodyBuilder.build(_root.doc, _root)
				if not bodies.is_empty():
					var top := _root.world.pick_face(Vector3(x, y, 100), Vector3(0, 0, -1))
					if not top.is_empty() and int(top.get("face", -1)) >= 0:
						_root.add_holes(String(top["body"]), int(top["face"]),
							[Vector2(x, y)], {"diameter": rng.randf_range(2, 6),
							"extent": HoleFeature.EXT_THROUGH_ALL if rng.randf() < 0.5 else HoleFeature.EXT_DISTANCE,
							"depth": hgt * 0.5})
			4:
				var bodies2: Array = await BodyBuilder.build(_root.doc, _root)
				if not bodies2.is_empty():
					_root.add_edge_fillet(String(bodies2[0]["id"]),
						EdgeFilletFeature.KIND_FILLET if rng.randf() < 0.5 else EdgeFilletFeature.KIND_CHAMFER,
						rng.randf_range(0.5, 2.0), [Vector3(25, 0, 20)])
			5:
				var bodies3: Array = await BodyBuilder.build(_root.doc, _root)
				if bodies3.size() > 0:
					_root.move_body(String(bodies3[0]["id"]), Vector3(rng.randf_range(-2, 2), 0, 0))
			6:
				if _root.stack.can_undo() and rng.randf() < 0.3:
					_root.stack.undo()
		steps += 1
		await _idle()
		var bodies4: Array = await BodyBuilder.build(_root.doc, _root)
		for b: Dictionary in bodies4:
			if b.get("solid") != null and not SolidKernel.is_valid(b["solid"]):
				return _fail("C: step %d produced a non-manifold body" % i)
	var final: Array = await BodyBuilder.build(_root.doc, _root)
	if final.is_empty():
		return _fail("C: the fuzz consumed every body (seed 4747) — check the chain")
	if not _same(await _vols_both()):
		return _fail("C: fuzz: cached vs fresh mismatch")
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	if loaded == null or loaded.features.size() != _root.doc.features.size():
		return _fail("C: fuzzed document does not round-trip")
	var lb: Array = await BodyBuilder.build(loaded, _root)
	if lb.size() != final.size():
		return _fail("C: loaded fuzz document builds %d bodies vs %d" % [lb.size(), final.size()])
	for i in lb.size():
		if absf(BodyBuilder.mesh_volume(lb[i]["mesh"]) - BodyBuilder.mesh_volume(final[i]["mesh"])) > 1e-3:
			return _fail("C: loaded fuzz volume differs")
	return true
