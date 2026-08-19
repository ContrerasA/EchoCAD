extends SceneTree

# M30: reference images (canvases) — import onto planes, placement math,
# calibration about the first pick, browser eye / suppress, serialization
# with embedded bytes, sketch-mode provider filtering, bad-file refusal.

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
	push_error("m30_ref_image: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _canvas_quad(fid: String) -> MeshInstance3D:
	for c in _root.world._sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.has_meta("canvas_id") \
				and String(mi.get_meta("canvas_id")) == fid:
			return mi
	return null


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	await _idle()

	# A 40x20 test PNG on disk.
	var img := Image.create(40, 20, false, Image.FORMAT_RGB8)
	img.fill(Color(0.8, 0.4, 0.2))
	var path := OS.get_user_data_dir() + "/m30_test.png"
	if img.save_png(path) != OK:
		return _fail("could not write test png")

	# --- import onto XZ with an explicit width ----------------------------
	var fid := _root.import_canvas(path, "XZ", 80.0)
	if fid == "":
		return _fail("import refused a valid png")
	var cf := _root.doc.feature_by_id(fid) as CanvasFeature
	if cf == null or cf.name != "Canvas1" or cf.plane != "XZ":
		return _fail("canvas feature wrong after import")
	if absf(cf.width_mm - 80.0) > 1e-9 or absf(cf.height_mm() - 40.0) > 1e-6:
		return _fail("size wrong: w=%f h=%f" % [cf.width_mm, cf.height_mm()])
	await _idle()
	var quad := _canvas_quad(fid)
	if quad == null or not quad.visible:
		return _fail("no visible 3D quad for the canvas")
	# The quad sits on the XZ plane: its transform basis matches the plane.
	var want_xf := cf.plane_transform()
	if not quad.transform.basis.is_equal_approx(want_xf.basis):
		return _fail("quad not on the canvas plane")

	# --- undo removes the feature -----------------------------------------
	_root.stack.undo()
	if _root.doc.feature_by_id(fid) != null:
		return _fail("undo did not remove the canvas")
	_root.stack.redo()
	cf = _root.doc.feature_by_id(fid) as CanvasFeature
	if cf == null:
		return _fail("redo did not restore the canvas")

	# --- placement edits merge into one undo step -------------------------
	_root.stack.push_no_merge(CmdSetCanvasProps.new(fid,
		{"center": Vector2(10, 5), "rotation": deg_to_rad(30.0)}))
	_root.stack.push(CmdSetCanvasProps.new(fid, {"opacity": 0.3}))
	if cf.center.distance_to(Vector2(10, 5)) > 1e-9 \
			or absf(cf.opacity - 0.3) > 1e-9:
		return _fail("prop edits did not land")
	_root.stack.undo()
	if cf.center != Vector2.ZERO or absf(cf.opacity - 0.6) > 1e-9:
		return _fail("merged prop edits did not undo as one step")

	# --- calibration about the first pick ---------------------------------
	_root.stack.push_no_merge(CmdSetCanvasProps.new(fid,
		{"center": Vector2(10, 0)}))
	var err := _root.apply_canvas_calibration(fid,
		Vector2(0, 0), Vector2(10, 0), 25.4)
	if err != "":
		return _fail("calibration refused: " + err)
	if absf(cf.width_mm - 80.0 * 2.54) > 1e-6:
		return _fail("calibration width wrong: %f" % cf.width_mm)
	if cf.center.distance_to(Vector2(25.4, 0)) > 1e-6:
		return _fail("calibration did not hold the first pick: %s"
			% str(cf.center))
	if _root.apply_canvas_calibration(fid, Vector2.ZERO, Vector2.ZERO,
			10.0) == "":
		return _fail("degenerate calibration accepted")

	# --- browser eye + suppress -------------------------------------------
	_root.set_canvas_shown(fid, false)
	if _canvas_quad(fid).visible:
		return _fail("eye off left the quad visible")
	_root.set_canvas_shown(fid, true)
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(fid, "suppressed", true))
	await _idle()
	if _canvas_quad(fid) != null:
		return _fail("suppressed canvas still has a quad")
	_root.stack.undo()
	await _idle()

	# --- sketch-mode provider filters by plane ----------------------------
	_root.create_sketch("XZ")
	var entries: Array = _root.sketch_view.canvases_provider.call()
	if entries.size() != 1:
		return _fail("provider missed the canvas on the sketch plane")
	if absf(float(entries[0]["width_mm"]) - cf.width_mm) > 1e-9:
		return _fail("provider width mismatch")
	_root.finish_sketch()
	await _idle()
	_root.create_sketch("XY")
	if not (_root.sketch_view.canvases_provider.call() as Array).is_empty():
		return _fail("provider leaked a canvas from another plane")
	_root.finish_sketch()
	await _idle()

	# --- serialization round trip (bytes embedded) ------------------------
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var cf2: CanvasFeature = null
	for f in doc2.features:
		if f is CanvasFeature:
			cf2 = f
	if cf2 == null:
		return _fail("canvas lost in serialization")
	if cf2.image_data != cf.image_data or cf2.plane != cf.plane \
			or absf(cf2.width_mm - cf.width_mm) > 1e-9 \
			or cf2.center != cf.center:
		return _fail("canvas props/bytes lost in serialization")
	if cf2.texture() == null:
		return _fail("round-tripped bytes no longer decode")

	# --- garbage file refused, document untouched -------------------------
	var junk := OS.get_user_data_dir() + "/m30_junk.png"
	var f := FileAccess.open(junk, FileAccess.WRITE)
	f.store_string("not a png at all")
	f.close()
	var n := _root.doc.features.size()
	if _root.import_canvas(junk) != "":
		return _fail("garbage file accepted")
	if _root.doc.features.size() != n:
		return _fail("failed import touched the document")

	print("M30_REF_IMAGE OK: import, placement, calibration, eye/suppress, ",
		"provider, serialization, refusal")
	return true
