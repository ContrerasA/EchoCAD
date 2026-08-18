extends SceneTree

# M18: regions with holes (nested loops), extrude meshes the ring not the
# disc, and extrude booleans — join unions into touched bodies, cut carves
# its prism out of them, new_body stands alone. Plus serialization of the
# operation field and undo/redo through a boolean.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m18_extrude_booleans: " + msg)
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


func _volumes() -> Array:
	var out: Array = []
	for b: Dictionary in await BodyBuilder.build(_root.doc, _root):
		out.append(BodyBuilder.mesh_volume(b["mesh"]))
	return out


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A: a plate with a drilled hole -------------------------------------
	var f1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var sk: Sketch = _root.active_sketch()
	_root.tools.set_active("circle")
	_click(Vector2(20, 15))
	_click(Vector2(25, 15))
	# 32-gon area of the tessellated circle, the exact value regions use.
	var circle_area := 0.5 * 32.0 * 25.0 * sin(TAU / 32.0)

	var profs := ProfileFinder.profiles(sk)
	if profs.size() != 2:
		return _fail("plate+hole should give 2 regions, got %d" % profs.size())
	var ring := ProfileFinder.profile_at(sk, Vector2(2, 2))
	if ring.is_empty() or (ring["holes"] as Array).size() != 1:
		return _fail("ring region missing its hole")
	if absf(float(ring["area"]) - (1200.0 - circle_area)) > 0.5:
		return _fail("ring net area wrong: %f" % float(ring["area"]))
	var disc := ProfileFinder.profile_at(sk, Vector2(20, 15))
	if disc.is_empty() or not (disc["holes"] as Array).is_empty():
		return _fail("clicking inside the hole should pick the disc region")
	_root.finish_sketch()

	var e1 := _root.extrude(f1, Vector2(2, 2), 10.0)
	if e1 == "":
		return _fail("ring extrude refused")
	await _idle()
	var vols: Array = await _volumes()
	var want_a := (1200.0 - circle_area) * 10.0
	if vols.size() != 1 or absf(float(vols[0]) - want_a) > 5.0:
		return _fail("holed plate volume wrong: %s vs %f" % [str(vols), want_a])

	# The world shows the body once things settle.
	await _idle()
	var solids := 0
	for c in _root.world._sketch_root.get_children():
		if (c as Node).has_meta("is_body") and not c.is_queued_for_deletion():
			solids += 1
	if solids != 1:
		return _fail("world should show 1 body, has %d" % solids)

	# Serialization: operation + hole survive a round-trip.
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var lf := loaded.feature_by_id(e1) as ExtrudeFeature
	if lf == null or lf.operation != ExtrudeFeature.OP_NEW_BODY:
		return _fail("operation did not serialize")
	var lbodies: Array = await BodyBuilder.build(loaded, _root)
	if lbodies.size() != 1 \
			or absf(BodyBuilder.mesh_volume(lbodies[0]["mesh"]) - want_a) > 5.0:
		return _fail("loaded holed plate volume wrong")

	# --- B: cut -------------------------------------------------------------
	_root.load_document(CadDocument.new())
	var f2 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	var e2 := _root.extrude(f2, Vector2(20, 15), 10.0)
	if e2 == "":
		return _fail("plate B extrude refused")
	var f3 := _sketch_rect("XY", Vector2(2, 2), Vector2(12, 12))
	_root.finish_sketch()
	var e3 := _root.extrude(f3, Vector2(7, 7), 12.0, ExtrudeFeature.OP_CUT)
	if e3 == "":
		return _fail("cut extrude refused")
	await _idle()
	vols = await _volumes()
	if vols.size() != 1:
		return _fail("cut should leave 1 body, got %d" % vols.size())
	# Cut prisms are inflated EPS_MM sideways (coplanar-skin defence), so an
	# interior 10x10 through-cut removes (10+2*EPS)^2 * 10.
	var cut_side := 10.0 + 2.0 * BodyBuilder.EPS_MM
	var want_cut := 12000.0 - cut_side * cut_side * 10.0
	if absf(float(vols[0]) - want_cut) > 5.0:
		return _fail("cut volume wrong: %f (want %f)" % [float(vols[0]), want_cut])

	# Undo removes the cut; redo restores it.
	_root.stack.undo()
	await _idle()
	vols = await _volumes()
	if absf(float(vols[0]) - 12000.0) > 5.0:
		return _fail("undo of cut wrong: %f" % float(vols[0]))
	_root.stack.redo()
	await _idle()
	vols = await _volumes()
	if absf(float(vols[0]) - want_cut) > 5.0:
		return _fail("redo of cut wrong: %f" % float(vols[0]))

	# A cut that touches no body is a no-op (still one body, same volume).
	var f4 := _sketch_rect("XY", Vector2(200, 200), Vector2(210, 210))
	_root.finish_sketch()
	if _root.extrude(f4, Vector2(205, 205), 10.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("far cut refused")
	await _idle()
	vols = await _volumes()
	if vols.size() != 1 or absf(float(vols[0]) - want_cut) > 5.0:
		return _fail("no-target cut changed something: %s" % str(vols))

	# --- C: join ------------------------------------------------------------
	_root.load_document(CadDocument.new())
	var f5 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	if _root.extrude(f5, Vector2(20, 15), 10.0) == "":
		return _fail("plate C extrude refused")
	var f6 := _sketch_rect("XY", Vector2(30, 10), Vector2(60, 20))
	_root.finish_sketch()
	if _root.extrude(f6, Vector2(45, 15), 10.0, ExtrudeFeature.OP_JOIN) == "":
		return _fail("join extrude refused")
	await _idle()
	vols = await _volumes()
	# 1200*10 + 300*10 - overlap (10x10)*10
	if vols.size() != 1 or absf(float(vols[0]) - 14000.0) > 5.0:
		return _fail("join volume wrong: %s (want 14000)" % str(vols))

	# A separate NEW_BODY stays its own solid.
	var f7 := _sketch_rect("XY", Vector2(100, 100), Vector2(110, 110))
	_root.finish_sketch()
	if _root.extrude(f7, Vector2(105, 105), 10.0) == "":
		return _fail("island extrude refused")
	await _idle()
	vols = await _volumes()
	if vols.size() != 2:
		return _fail("new_body should be a second body, got %d" % vols.size())

	# --- D: QA §M18 regressions ---------------------------------------------
	# Same-height cut: the cut prism overhangs both caps, so no zero-thickness
	# cap skin survives and the pocket goes clean through.
	_root.load_document(CadDocument.new())
	var f8 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	_root.finish_sketch()
	if _root.extrude(f8, Vector2(20, 15), 10.0) == "":
		return _fail("plate D extrude refused")
	var f9 := _sketch_rect("XY", Vector2(10, 10), Vector2(20, 20))
	_root.finish_sketch()
	if _root.extrude(f9, Vector2(15, 15), 10.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("same-height cut refused")
	await _idle()
	vols = await _volumes()
	if vols.size() != 1 or absf(float(vols[0]) - want_cut) > 5.0:
		return _fail("same-height cut volume wrong: %s (want %f)"
			% [str(vols), want_cut])

	# Flush-edge cut (QA §M18.3 follow-up): the pocket shares an edge with the
	# plate's outer boundary — the coplanar side wall must NOT leave a roof
	# skin, and the sideways inflation makes the notch open cleanly. Removed:
	# x spans the full inflated width (interior), y is clipped by the plate
	# edge at 30 so only EPS of the overhang lands inside.
	var f9b := _sketch_rect("XY", Vector2(25, 20), Vector2(35, 30))
	_root.finish_sketch()
	if _root.extrude(f9b, Vector2(30, 25), 12.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("flush-edge cut refused")
	await _idle()
	vols = await _volumes()
	var want_flush := want_cut \
		- (10.0 + 2.0 * BodyBuilder.EPS_MM) * (10.0 + BodyBuilder.EPS_MM) * 10.0
	if vols.size() != 1 or absf(float(vols[0]) - want_flush) > 5.0:
		return _fail("flush-edge cut volume wrong: %s (want %f)"
			% [str(vols), want_flush])

	# Profile picking resolves to the LATEST coplanar sketch: a ray into the
	# small rectangle must pick f9's region, not the plate's outer profile
	# (the old first-sketch-wins scan is what cut whole plates away).
	var hit: Dictionary = _root._profile_under_ray(
		Vector3(15, 15, 50), Vector3(0, 0, -1))
	if hit.is_empty() or String(hit["sketch_id"]) != f9:
		return _fail("profile pick chose %s, want the latest sketch %s"
			% [str(hit), f9])

	# A cut that consumes the whole body removes it cleanly — no ghost body,
	# no empty-mesh crash in the world rebuild.
	var f10 := _sketch_rect("XY", Vector2(-5, -5), Vector2(45, 35))
	_root.finish_sketch()
	if _root.extrude(f10, Vector2(20, 16), 12.0, ExtrudeFeature.OP_CUT) == "":
		return _fail("consuming cut refused")
	await _idle()
	vols = await _volumes()
	if not vols.is_empty():
		return _fail("consumed body should vanish, got %s" % str(vols))

	print("M18_EXTRUDE_BOOLEANS OK: hole regions, ring extrusion, cut, "
		+ "join, no-target cut, undo/redo, serialization, same-height cut, "
		+ "latest-sketch profile pick, consuming cut")
	return true
