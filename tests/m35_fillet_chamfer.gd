extends SceneTree

# M35: prismatic 3D fillet/chamfer. Analytic volumes for lateral fillet/
# chamfer on a box, exact top-rim chamfer, cylinder cap fillet vs numeric
# integral, watertightness (positive volume), refusals (boolean bodies,
# oversize, double-treat), parametric edit, serialization.

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
	push_error("m35_fillet_chamfer: " + msg)
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


func _body_vol(body_id: String) -> float:
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	for b in bodies:
		if String(b["id"]) == body_id:
			return BodyBuilder.mesh_volume(b["mesh"])
	return -1.0


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)

	# 40x30x10 box.
	var f1 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.finish_sketch()
	await _idle()
	var box_id := _root.extrude(f1, Vector2(20, 15), 10.0)
	await _idle()
	var v_box := 40.0 * 30.0 * 10.0

	# --- lateral fillet r5: V = box - 4*(r^2 - pi r^2/4)*h ----------------
	var fid := _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 5.0,
		true, false, false)
	if fid == "":
		return _fail("lateral fillet refused")
	var want := v_box - 4.0 * (25.0 - PI * 25.0 / 4.0) * 10.0
	var got: float = await _body_vol(box_id)
	if absf(got - want) > want * 0.01:
		return _fail("lateral fillet volume %f vs %f" % [got, want])
	# Double-treat refused.
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 2.0) != "":
		return _fail("second treatment on the same body accepted")
	# Parametric edit: shrink the radius, volume grows toward the box.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(fid, "size_mm", 2.0))
	var got2: float = await _body_vol(box_id)
	var want2 := v_box - 4.0 * (4.0 - PI * 4.0 / 4.0) * 10.0
	if absf(got2 - want2) > want2 * 0.01:
		return _fail("edited fillet volume %f vs %f" % [got2, want2])
	_root.stack.undo()
	_root.stack.undo()   # drop the treatment entirely

	# --- lateral chamfer d5: V = box - 4*(d^2/2)*h ------------------------
	var cid := _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 5.0,
		true, false, false)
	if cid == "":
		return _fail("lateral chamfer refused")
	var want3 := v_box - 4.0 * 12.5 * 10.0
	var got3: float = await _body_vol(box_id)
	if absf(got3 - want3) > want3 * 0.005:
		return _fail("lateral chamfer volume %f vs %f" % [got3, want3])
	_root.stack.undo()

	# --- top-rim chamfer d3 (no lateral): exact integral 594 removed ------
	var tid := _root.edge_treat(box_id, EdgeTreatFeature.KIND_CHAMFER, 3.0,
		false, true, false)
	if tid == "":
		return _fail("top chamfer refused")
	var want4 := v_box - 594.0
	var got4: float = await _body_vol(box_id)
	if absf(got4 - want4) > want4 * 0.01:
		return _fail("top chamfer volume %f vs %f" % [got4, want4])
	_root.stack.undo()

	# --- oversize refused --------------------------------------------------
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 25.0,
			true, false, false) != "":
		return _fail("oversize lateral fillet accepted")
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 12.0,
			false, true, false) != "":
		return _fail("cap fillet taller than the body accepted")

	# --- cylinder cap fillet r3 vs numeric integral -----------------------
	var f2 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(100, 0), 3.0)
	_root.tools.set_active("circle")
	_click(Vector2(100, 0))
	_click(Vector2(115, 0))
	_root.finish_sketch()
	await _idle()
	var cyl_id := _root.extrude(f2, Vector2(100, 0), 12.0)
	await _idle()
	var rid := _root.edge_treat(cyl_id, EdgeTreatFeature.KIND_FILLET, 3.0,
		false, true, false)
	if rid == "":
		return _fail("cylinder cap fillet refused")
	# V = pi R^2 (h - r) + pi * integral_0^r (R - r + sqrt(r^2 - u^2))^2 du
	var R := 15.0
	var fr := 3.0
	var cap := 0.0
	var steps := 4000
	for k in steps:
		var u := fr * (k + 0.5) / steps
		var rad := R - fr + sqrt(maxf(fr * fr - u * u, 0.0))
		cap += PI * rad * rad * (fr / steps)
	var want5 := PI * R * R * (12.0 - fr) + cap
	var got5: float = await _body_vol(cyl_id)
	if absf(got5 - want5) > want5 * 0.02:
		return _fail("cylinder cap fillet volume %f vs %f" % [got5, want5])

	# --- boolean bodies refused -------------------------------------------
	var f3 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.tools.set_active("circle")
	_click(Vector2(20, 15))
	_click(Vector2(25, 15))
	_root.finish_sketch()
	await _idle()
	if _root.extrude(f3, Vector2(20, 15), 12.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("setup cut refused")
	await _idle()
	if _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 2.0) != "":
		return _fail("treatment on a boolean body accepted")
	_root.stack.undo()

	# --- serialization + replay -------------------------------------------
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var et2 := doc2.feature_by_id(rid) as EdgeTreatFeature
	if et2 == null or et2.treat != EdgeTreatFeature.KIND_FILLET \
			or absf(et2.size_mm - 3.0) > 1e-9 or not et2.top or et2.lateral:
		return _fail("treatment lost in serialization")

	print("M35_FILLET_CHAMFER OK: lateral fillet/chamfer analytic, top-rim ",
		"chamfer exact, cylinder cap fillet vs integral, refusals, edit, ",
		"serialization")
	return true
