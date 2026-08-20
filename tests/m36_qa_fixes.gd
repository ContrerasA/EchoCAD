extends SceneTree

# QA fix round 2 for volume-2 §M30–§M35 (2026-08-19):
#  A. §M33.2 / "big bug" — editing a sketch and moving the whole shape used
#     to strand the extrude's anchor outside every region: the body silently
#     vanished. Anchors now self-heal to the nearest region (M33.ecad).
#  B. §M34.1 round 2 — the drawn profile offset is only kept when the path
#     start actually sits ON the profile plane; a start far along the plane
#     normal (whose PROJECTION lands inside) re-anchors to the centroid.
#  C. §M35.1 round 2 — rim segments are individually selectable: a chamfer/
#     fillet on ONE top edge removes exactly that edge's material; the
#     picked segments survive serialization.
#  D. Sweep path hover (hard rule): world.set_curve_hover draws and clears.

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
	push_error("m36_qa_fixes: " + msg)
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


func _body_volume(bodies: Array, body_id: String) -> float:
	for b: Dictionary in bodies:
		if String(b["id"]) == body_id:
			return BodyBuilder.mesh_volume(b["mesh"])
	return -1.0


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	await _idle()

	# --- A1. the saved repro: M33.ecad's anchor is stranded ----------------
	var d33: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://tests/M33.ecad"))
	var doc33 := CadDocument.from_dict(d33 as Dictionary)
	var bodies33: Array = await BodyBuilder.build(doc33, _root)
	if bodies33.size() != 1:
		return _fail("A1: M33.ecad should rebuild 1 body, got %d"
			% bodies33.size())
	var want33 := 76.2 * 63.5 * 50.8
	var got33 := BodyBuilder.mesh_volume(bodies33[0]["mesh"])
	if absf(got33 - want33) > want33 * 0.01:
		return _fail("A1: healed body volume %f vs %f" % [got33, want33])
	var ef33 := doc33.feature_by_id("f2") as ExtrudeFeature
	if ProfileFinder.profile_at(
			doc33.sketch_feature("f1").sketch, ef33.anchor).is_empty():
		return _fail("A1: anchor was not healed into the region")

	# --- A2. live edit: move every point, body must survive ----------------
	var fbox := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.finish_sketch()
	await _idle()
	var box_id := _root.extrude(fbox, Vector2(20, 15), 10.0)
	await _idle()
	var sk := _root.doc.sketch_feature(fbox).sketch
	for e in sk.entities():
		if e.kind() == "point":
			(e as SketchPoint).pos += Vector2(200.0, 120.0)
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var vol := _body_volume(bodies, box_id)
	if absf(vol - 12000.0) > 120.0:
		return _fail("A2: moved-sketch body volume %f (vanished?)" % vol)
	for e in sk.entities():
		if e.kind() == "point":
			(e as SketchPoint).pos -= Vector2(200.0, 120.0)
	await _idle()

	# --- B. sweep: path start off the profile plane re-anchors -------------
	var fprof := _root.create_sketch("XZ")
	_root.sketch_view.set_view(Vector2(20, 0), 4.0)
	_root.tools.set_active("circle")
	_click(Vector2(20, 0))
	_click(Vector2(25, 0))
	_root.finish_sketch()
	await _idle()
	var fpath := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(60, 100), 2.0)
	_root.tools.set_active("line")
	_click(Vector2(20, 100))
	_click(Vector2(120, 100))
	var path_line := ""
	for e in _root.doc.sketch_feature(fpath).sketch.entities():
		if e.kind() == "line":
			path_line = e.id
	_root.tools.handle_cancel()
	_root.finish_sketch()
	await _idle()
	if path_line == "":
		return _fail("B: no path line drawn")
	# Projected onto XZ the path start lands at uv (20, 0) — INSIDE the
	# circle — but it sits 100 mm off the plane. The offset must be dropped.
	var sweep_id := _root.sweep(fprof, Vector2(20, 0), fpath, path_line)
	if sweep_id == "":
		return _fail("B: off-plane-start sweep refused")
	var sw := _root.doc.feature_by_id(sweep_id) as SweepFeature
	var smesh := sw.build_mesh(_root.doc)
	var swant := PI * 25.0 * 100.0   # r=5 circle along a 100 mm line
	var sgot := BodyBuilder.mesh_volume(smesh)
	if absf(sgot - swant) > swant * 0.02:
		return _fail("B: swept tube volume %f vs %f" % [sgot, swant])
	# The tube must be centered ON the path (y from 95 to 105), not carried
	# at the phantom 100 mm arm.
	var saabb := smesh.get_aabb()
	if absf(saabb.get_center().y - 100.0) > 1.0:
		return _fail("B: tube not centered on the path (y center %f)"
			% saabb.get_center().y)
	_root.stack.undo()   # sweep
	_root.stack.undo()   # path sketch
	_root.stack.undo()   # profile sketch
	await _idle()

	# --- C. per-segment rim treatment (M35.1 round 2) -----------------------
	var root_ef := _root.doc.feature_by_id(box_id) as ExtrudeFeature
	var edges := EdgeTreatFeature.pickable_edges(_root.doc, root_ef)
	var top_keys: Array = []
	for e: Dictionary in edges:
		if String(e["key"]).begins_with("top:"):
			top_keys.append(String(e["key"]))
	if top_keys.size() != 4:
		return _fail("C: expected 4 top rim segments, got %d"
			% top_keys.size())
	# Find the bottom (y=0) edge of the rect profile: its two endpoints
	# have y == 0 in sketch uv — that is the 40 mm-long segment.
	var seg40 := -1
	var prof := ProfileFinder.profile_at(sk, root_ef.anchor)
	var poly: PackedVector2Array = prof["polygon"]
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		if absf(a.y) < 1e-4 and absf(b.y) < 1e-4:
			seg40 = i
	if seg40 < 0:
		return _fail("C: could not locate the y=0 profile segment")
	# Chamfer ONE top edge, size 2: removes a 2x2/2 wedge along 40 mm.
	var fid := _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 2.0,
		false, true, false, [], [seg40])
	if fid == "":
		return _fail("C: single-edge top chamfer refused")
	bodies = await BodyBuilder.build(_root.doc, _root)
	var cwant := 12000.0 - (2.0 * 2.0 * 0.5) * 40.0
	var cgot := _body_volume(bodies, box_id)
	if absf(cgot - cwant) > cwant * 0.01:
		return _fail("C: single-edge chamfer volume %f vs %f" % [cgot, cwant])
	var et2 := CadDocument.from_dict(_root.doc.to_dict()).feature_by_id(
		fid) as EdgeTreatFeature
	if et2 == null or et2.top_segs != [seg40]:
		return _fail("C: top_segs lost in serialization")
	_root.stack.undo()
	# Fillet the same single edge, size 3.
	var fid2 := _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 3.0,
		false, true, false, [], [seg40])
	if fid2 == "":
		return _fail("C: single-edge top fillet refused")
	bodies = await BodyBuilder.build(_root.doc, _root)
	var fwant := 12000.0 - (9.0 - PI * 9.0 / 4.0) * 40.0
	var fgot := _body_volume(bodies, box_id)
	if absf(fgot - fwant) > fwant * 0.015:
		return _fail("C: single-edge fillet volume %f vs %f" % [fgot, fwant])
	_root.stack.undo()
	# Two ADJACENT top edges chamfered: the miter joint must close the mesh
	# (signed volume sane, below the single-edge result).
	var seg_next := (seg40 + 1) % poly.size()
	var fid3 := _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 2.0,
		false, true, false, [], [seg40, seg_next])
	if fid3 == "":
		return _fail("C: two-edge chamfer refused")
	bodies = await BodyBuilder.build(_root.doc, _root)
	var ggot := _body_volume(bodies, box_id)
	if ggot <= 0.0 or ggot >= cwant or ggot < 11700.0:
		return _fail("C: two-edge chamfer volume %f out of range" % ggot)
	_root.stack.undo()

	# --- D. sweep-path hover band draws and clears --------------------------
	var fcurve := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.tools.set_active("line")
	_click(Vector2(0, 0))
	_click(Vector2(30, 20))
	_root.tools.handle_cancel()
	var sfc := _root.doc.sketch_feature(fcurve)
	var ent: SketchEntity = null
	for e in sfc.sketch.entities():
		if e.kind() == "line":
			ent = e
	_root.finish_sketch()
	await _idle()
	if ent == null:
		return _fail("D: no line for the hover check")
	_root.world.set_curve_hover(sfc, ent.id,
		SketchGeometry.entity_polyline(sfc.sketch, ent), 2.0)
	if _root.world.get_node_or_null("CurveHover") == null:
		return _fail("D: set_curve_hover drew nothing")
	_root.world.clear_axis_hover()
	await _idle()
	if _root.world.get_node_or_null("CurveHover") != null:
		return _fail("D: clear_axis_hover left the curve band behind")

	print("M36_QA_FIXES OK: anchors self-heal (M33), sweep drops off-plane "
		+ "offsets (M34), per-segment rims (M35), sweep path hover")
	return true
