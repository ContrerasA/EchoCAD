extends SceneTree

# M34: sweep + loft. Straight sweep matches extrude volume; L-path sweep
# approximates area×length; splines sweep; hairpin paths refuse; loft of
# concentric circles matches the cone-frustum volume; watertightness via
# positive signed volume + boolean cut works through BodyBuilder.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m34_sweep_loft: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


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


func _line_id(sk: Sketch, near_pt: Vector2) -> String:
	var best := ""
	var best_d := INF
	for e in sk.entities():
		if e.kind() != "line":
			continue
		var d := SketchGeometry.distance_to_entity(sk, e, near_pt)
		if d < best_d:
			best_d = d
			best = e.id
	return best


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)

	# --- profile: 8x6 rect on XZ (so its plane normal runs along -Y) ------
	var fp := _root.create_sketch("XZ")
	_root.sketch_view.set_view(Vector2(10, 10), 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	_root.tools.set_active("rect")
	_click(Vector2(-4, 2))
	_click(Vector2(4, 8))
	_root.finish_sketch()
	await _idle()

	# --- straight path on XY along +Y: length 40 --------------------------
	var fpath := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(0, 20), 4.0)
	_root.tools.set_active("line")
	_click(Vector2(0, 0))
	_click(Vector2(0, 40))
	_root.tools.handle_cancel()
	_root.finish_sketch()
	await _idle()
	var path_sk := _root.doc.sketch_feature(fpath).sketch
	var seg := _line_id(path_sk, Vector2(0, 20))

	var sid := _root.sweep(fp, Vector2(0, 5), fpath, seg)
	if sid == "":
		return _fail("straight sweep refused")
	var sw := _root.doc.feature_by_id(sid) as SweepFeature
	var vol := BodyBuilder.mesh_volume(sw.build_mesh(_root.doc))
	if absf(vol - 8.0 * 6.0 * 40.0) > 8.0 * 6.0 * 40.0 * 0.01:
		return _fail("straight sweep volume %f vs %f" % [vol, 8 * 6 * 40.0])

	# --- L path: two 40mm legs --------------------------------------------
	var flp := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 20), 3.0)
	_root.tools.set_active("line")
	_click(Vector2(0, 0))
	_click(Vector2(0, 40))
	_click(Vector2(40, 40))
	_root.tools.handle_cancel()
	_root.finish_sketch()
	await _idle()
	var lsk := _root.doc.sketch_feature(flp).sketch
	var lseg := _line_id(lsk, Vector2(0, 20))
	var lid := _root.sweep(fp, Vector2(0, 5), flp, lseg)
	if lid == "":
		return _fail("L sweep refused")
	var lw := _root.doc.feature_by_id(lid) as LoftFeature if false \
		else _root.doc.feature_by_id(lid) as SweepFeature
	var lvol := BodyBuilder.mesh_volume(lw.build_mesh(_root.doc))
	if absf(lvol - 8.0 * 6.0 * 80.0) > 8.0 * 6.0 * 80.0 * 0.03:
		return _fail("L sweep volume %f vs ~%f" % [lvol, 8 * 6 * 80.0])

	# --- hairpin (reversal) refused; gentle tight bends only warn ---------
	var ftight := _root.create_sketch("XY")
	_root.tools.set_active("line")
	_click(Vector2(100, 0))
	_click(Vector2(103, 0))     # 3mm leg, then a hairpin
	_click(Vector2(100, 0.5))
	_root.tools.handle_cancel()
	_root.finish_sketch()
	await _idle()
	var tsk := _root.doc.sketch_feature(ftight).sketch
	var tseg := _line_id(tsk, Vector2(101.5, 0))
	if _root.sweep(fp, Vector2(0, 5), ftight, tseg) != "":
		return _fail("hairpin sweep was not refused")

	# --- spline path sweeps -----------------------------------------------
	# Gentle curve STARTING AT THE PROFILE (the profile rides at its drawn
	# offset from the path start, so a distant start means a huge swing arm
	# that trips the bend check — correctly).
	var fsp := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(45, 5), 3.0)
	_root.tools.set_active("spline")
	for p: Vector2 in [Vector2(0, 0), Vector2(40, 6), Vector2(80, -4),
			Vector2(120, 6)]:
		_click(p)
	_root.tools.handle_commit()
	_root.finish_sketch()
	await _idle()
	var ssk := _root.doc.sketch_feature(fsp).sketch
	var spline_id := ""
	for e in ssk.entities():
		if e.kind() == "spline":
			spline_id = e.id
	var spid := _root.sweep(fp, Vector2(0, 5), fsp, spline_id)
	if spid == "":
		return _fail("spline-path sweep refused")

	# --- loft: circle 20 -> circle 10, 30 apart = cone frustum ------------
	var fc1 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(80, 0), 3.0)
	_root.tools.set_active("circle")
	_click(Vector2(80, 0))
	_click(Vector2(100, 0))
	_root.finish_sketch()
	await _idle()
	var plane_id := _root.create_offset_plane("XY", 30.0)
	var fc2 := _root.create_sketch(plane_id)
	_root.sketch_view.set_view(Vector2(80, 0), 3.0)
	_root.tools.set_active("circle")
	_click(Vector2(80, 0))
	_click(Vector2(90, 0))
	_root.finish_sketch()
	await _idle()
	var loft_id := _root.loft([{"sketch": fc1, "at": Vector2(80, 0)},
		{"sketch": fc2, "at": Vector2(80, 0)}])
	if loft_id == "":
		return _fail("loft refused")
	var lf := _root.doc.feature_by_id(loft_id) as LoftFeature
	var frustum := PI * 30.0 * (400.0 + 200.0 + 100.0) / 3.0
	var lfvol := BodyBuilder.mesh_volume(lf.build_mesh(_root.doc))
	if absf(lfvol - frustum) > frustum * 0.03:
		return _fail("loft volume %f vs frustum %f" % [lfvol, frustum])

	# --- loft cut through BodyBuilder -------------------------------------
	var before: Array = await BodyBuilder.build(_root.doc, _root)
	var n_before := before.size()
	var cut_id := _root.loft([{"sketch": fc1, "at": Vector2(80, 0)},
		{"sketch": fc2, "at": Vector2(80, 0)}], SolidFeature.OP_CUT)
	if cut_id == "":
		return _fail("cut loft refused")
	var after: Array = await BodyBuilder.build(_root.doc, _root)
	# An identical cut consumes the loft body entirely (it may vanish from
	# the list) while every other body keeps its volume.
	var loft_body_vol := 0.0
	for b in after:
		if String(b["id"]) == loft_id:
			loft_body_vol = BodyBuilder.mesh_volume(b["mesh"])
	if loft_body_vol > frustum * 0.2:
		return _fail("cut did not carve the loft body (%f left)" % loft_body_vol)
	var spline_vol_before := 0.0
	var spline_vol_after := 0.0
	for b in before:
		if String(b["id"]) == spid:
			spline_vol_before = BodyBuilder.mesh_volume(b["mesh"])
	for b in after:
		if String(b["id"]) == spid:
			spline_vol_after = BodyBuilder.mesh_volume(b["mesh"])
	# M38: the cone cut genuinely passes through the spline sweep (x 60..100,
	# z 0..30 crosses the tube) — the old CSG missed it; the exact kernel
	# carves it, and only it: volume drops but the body survives.
	if spline_vol_after >= spline_vol_before or spline_vol_after < spline_vol_before * 0.5:
		return _fail("cut should carve the overlapping sweep too (%f -> %f)"
			% [spline_vol_before, spline_vol_after])
		return _fail("cut bled into an unrelated body (%f -> %f)" % [spline_vol_before, spline_vol_after])
	_root.stack.undo()

	# --- serialization -----------------------------------------------------
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var sw2 := doc2.feature_by_id(sid) as SweepFeature
	var lf2 := doc2.feature_by_id(loft_id) as LoftFeature
	if sw2 == null or lf2 == null:
		return _fail("features lost in serialization")
	if sw2.path_sketch != fpath or lf2.sections.size() != 2:
		return _fail("feature props lost in serialization")
	var vol2 := BodyBuilder.mesh_volume(sw2.build_mesh(doc2))
	if absf(vol2 - vol) > vol * 1e-6:
		return _fail("re-loaded sweep rebuilds differently")

	print("M34_SWEEP_LOFT OK: straight/L/spline sweeps, bend refusal, ",
		"frustum loft, cut boolean, serialization")
	return true
