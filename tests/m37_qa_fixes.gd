extends SceneTree

# QA fix round for volume-2 §M35 (2026-08-19):
#  A. §M35.3 — a fillet and a chamfer STACK on the same body (different
#     edges): both build, volumes are exact for non-adjacent rim edges;
#     mixing two treatments at a shared corner refuses; re-treating an
#     already-treated edge refuses.
#  B. §M35.4 — rim segments chain by smoothness: a cylinder's rim is ONE
#     chain (one click picks it all), a box rim is four separate chains.
#  C. §M35.6 — editing a treatment's size from the timeline chip validates:
#     an oversize entry refuses with a hint and no timeline change.
#  D. Hover follows the chain: hovering one cylinder rim segment highlights
#     the whole rim.

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
	push_error("m37_qa_fixes: " + msg)
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

	# 40x30x10 box.
	var fbox := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.finish_sketch()
	await _idle()
	var box_id := _root.extrude(fbox, Vector2(20, 15), 10.0)
	await _idle()
	var v_box := 12000.0

	# --- A. §M35.3: fillet + chamfer stack on one body ----------------------
	var root_ef := _root.doc.feature_by_id(box_id) as ExtrudeFeature
	var sk := _root.doc.sketch_feature(fbox).sketch
	var prof := ProfileFinder.profile_at(sk, root_ef.anchor)
	var poly: PackedVector2Array = prof["polygon"]
	var seg40 := -1
	var seg_opp := -1
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		if absf(a.y) < 1e-4 and absf(b.y) < 1e-4:
			seg40 = i
		if absf(a.y - 30.0) < 1e-4 and absf(b.y - 30.0) < 1e-4:
			seg_opp = i
	if seg40 < 0 or seg_opp < 0:
		return _fail("A: could not locate the two 40mm profile segments")
	var fidc := _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 2.0,
		false, true, false, [], [seg40])
	if fidc == "":
		return _fail("A: first treatment (chamfer) refused")
	var fidf := _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 3.0,
		false, true, false, [], [seg_opp])
	if fidf == "":
		return _fail("A: second treatment (fillet, other edge) refused — "
			+ "stacking broken")
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var want := v_box - (2.0 * 2.0 * 0.5) * 40.0 \
		- (9.0 - PI * 9.0 / 4.0) * 40.0
	var got := _body_volume(bodies, box_id)
	if absf(got - want) > want * 0.01:
		return _fail("A: stacked fillet+chamfer volume %f vs %f" % [got, want])
	# Mixing at a shared corner refuses: the edge between seg40 and seg_opp
	# is adjacent to BOTH — a fillet there would meet the chamfer at a
	# corner with no joint curve.
	var seg_side := (seg40 + 1) % poly.size()
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 4.0,
			false, true, false, [], [seg_side]) != "":
		return _fail("A: mixed treatments meeting at a corner were accepted")
	# Re-treating an already-treated edge refuses.
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 1.0,
			false, true, false, [], [seg40]) != "":
		return _fail("A: double-treating one edge was accepted")

	# --- C. §M35.6: chip edit validates the size ---------------------------
	_root.open_edge_treat_dialog(fidf)
	(_root._treat_fields["size"] as LineEdit).text = "15mm"   # > body height
	_root._commit_edge_treat()
	var etf := _root.doc.feature_by_id(fidf) as EdgeTreatFeature
	if absf(etf.size_mm - 3.0) > 1e-9:
		return _fail("C: oversize chip edit was committed")
	if not _root._treat_dialog.visible:
		return _fail("C: oversize chip edit closed the dialog (no retry)")
	(_root._treat_fields["size"] as LineEdit).text = "4mm"
	_root._commit_edge_treat()
	if absf(etf.size_mm - 4.0) > 1e-9:
		return _fail("C: valid chip edit did not commit")
	bodies = await BodyBuilder.build(_root.doc, _root)
	var want2 := v_box - (2.0 * 2.0 * 0.5) * 40.0 \
		- (16.0 - PI * 16.0 / 4.0) * 40.0
	var got2 := _body_volume(bodies, box_id)
	if absf(got2 - want2) > want2 * 0.01:
		return _fail("C: edited stacked volume %f vs %f" % [got2, want2])
	_root.stack.undo()   # size edit
	_root.stack.undo()   # fillet
	_root.stack.undo()   # chamfer
	await _idle()

	# --- B. §M35.4: smoothness chains ---------------------------------------
	var box_edges := EdgeTreatFeature.pickable_edges(_root.doc, root_ef)
	var box_chains := {}
	for e: Dictionary in box_edges:
		if String(e["key"]).begins_with("top:"):
			box_chains[String(e["chain"])] = true
	if box_chains.size() != 4:
		return _fail("B: box top rim should be 4 chains, got %d"
			% box_chains.size())
	# Cylinder r15 h12.
	var fcyl := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(100, 0), 3.0)
	_root.tools.set_active("circle")
	_click(Vector2(100, 0))
	_click(Vector2(115, 0))
	_root.finish_sketch()
	await _idle()
	var cyl_id := _root.extrude(fcyl, Vector2(100, 0), 12.0)
	await _idle()
	var cyl_ef := _root.doc.feature_by_id(cyl_id) as ExtrudeFeature
	var cyl_edges := EdgeTreatFeature.pickable_edges(_root.doc, cyl_ef)
	var top_keys: Array = []
	var cyl_chains := {}
	for e: Dictionary in cyl_edges:
		if String(e["key"]).begins_with("top:"):
			top_keys.append(String(e["key"]))
			cyl_chains[String(e["chain"])] = true
	if top_keys.size() < 8:
		return _fail("B: cylinder rim census too small (%d)" % top_keys.size())
	if cyl_chains.size() != 1:
		return _fail("B: cylinder top rim should be ONE chain, got %d"
			% cyl_chains.size())

	# --- D. hover highlights the whole chain --------------------------------
	_root.world.set_treat_edge_hover(String(top_keys[0]), cyl_edges, 1.0)
	var hover := _root.world.get_node_or_null("TreatEdgeHover")
	if hover == null or hover.get_child_count() != top_keys.size():
		return _fail("D: cylinder rim hover drew %s tubes, expected %d"
			% ["none" if hover == null else str(hover.get_child_count()),
				top_keys.size()])
	_root.world.clear_treat_edge_hover()

	print("M37_QA_FIXES OK: fillet+chamfer stack (M35.3), mixing/overlap ",
		"refusals, chip-edit size validation (M35.6), smoothness chains + ",
		"chain hover (M35.4)")
	return true
