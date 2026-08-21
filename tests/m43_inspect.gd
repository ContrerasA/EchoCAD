extends SceneTree

# M43: mass properties vs analytic (volume, area, mass by material,
# centroid, inertia), interference volume of two boxes, section trim +
# cap, overhang census, bed fit, measure snapping, material persistence.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M43_INSPECT OK: mass properties analytic, interference volume, "
			+ "section trim + cap area, overhangs, bed fit, measure snaps to "
			+ "corners/edges, material saved with the document")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m43_inspect: " + msg)
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


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- A. mass properties of a 40x30x10 box --------------------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var box := _root.extrude(s1, Vector2(20, 15), 10.0)
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var e := _entry(bodies, box)
	var mp := Inspect.mass_properties(e, Inspect.density_of("aluminium"))
	if absf(float(mp["volume_mm3"]) - 12000.0) > 1e-6:
		return _fail("A: volume %f" % float(mp["volume_mm3"]))
	if absf(float(mp["area_mm2"]) - 2.0 * (40.0 * 30.0 + 40.0 * 10.0 + 30.0 * 10.0)) > 1e-6:
		return _fail("A: area %f" % float(mp["area_mm2"]))
	if absf(float(mp["mass_g"]) - 12.0 * 2.70) > 1e-6:
		return _fail("A: mass %f g (12 cm³ of Al = 32.4 g)" % float(mp["mass_g"]))
	if (mp["centroid"] as Vector3).distance_to(Vector3(20, 15, 5)) > 1e-4:
		return _fail("A: centroid %s" % str(mp["centroid"]))
	# Ixx = m/12 (b² + c²) with b=30, c=10 for the x axis.
	var m := 12.0 * 2.70
	var ixx := m / 12.0 * (30.0 * 30.0 + 10.0 * 10.0)
	var I: Basis = mp["inertia_gmm2"]
	if absf(I.x.x - ixx) > ixx * 1e-4:
		return _fail("A: Ixx %f vs %f" % [I.x.x, ixx])
	if not bool(mp["watertight"]):
		return _fail("A: box should be watertight")
	if Inspect.material_ids().size() < 10 or Inspect.density_of("pla") != 1.24:
		return _fail("A: materials table")

	# --- B. interference of two overlapping boxes ----------------------------
	var s2 := _sketch_rect("XY", Vector2(30, 20), Vector2(50, 40))
	var box2 := _root.extrude(s2, Vector2(40, 30), 10.0)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 2:
		return _fail("B: expected two separate bodies, got %d" % bodies.size())
	var hits := Inspect.interference(bodies)
	if hits.size() != 1 or absf(float(hits[0]["volume"]) - 10.0 * 10.0 * 10.0) > 1e-6:
		return _fail("B: interference %s" % str(hits))
	if (hits[0]["mesh"] as ArrayMesh).get_surface_count() == 0:
		return _fail("B: interference mesh empty")

	# --- C. section: keep z < 4 of the first box -----------------------------
	e = _entry(bodies, box)
	var sec := Inspect.section(e, Vector3(0, 0, 1), 4.0)
	if sec.is_empty() or absf(float(sec["volume"]) - 40.0 * 30.0 * 4.0) > 1e-6:
		return _fail("C: section volume %s" % str(sec.get("volume")))
	var cap: ArrayMesh = sec["cap"]
	if cap.get_surface_count() == 0:
		return _fail("C: no cap")
	var cap_verts: PackedVector3Array = cap.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cap_area := 0.0
	for t in cap_verts.size() / 3:
		cap_area += (cap_verts[t * 3 + 1] - cap_verts[t * 3]).cross(cap_verts[t * 3 + 2] - cap_verts[t * 3]).length() * 0.5
	if absf(cap_area - 1200.0) > 1e-3:
		return _fail("C: cap area %f" % cap_area)
	# Plane entirely above the body: nothing cut away; entirely below: gone.
	if Inspect.section(e, Vector3(0, 0, 1), 50.0).is_empty():
		return _fail("C: a plane above the body should keep all of it")
	if not Inspect.section(e, Vector3(0, 0, 1), -5.0).is_empty():
		return _fail("C: a plane below the body should hide it")
	# World toggle: bodies display trimmed, caps appear.
	_root.world.set_section(true, Vector3(0, 0, 1), 4.0)
	await _idle()
	var caps := 0
	for c in _root.world._sketch_root.get_children():
		if (c as Node).has_meta("section_cap"):
			caps += 1
	if caps != 2:
		return _fail("C: expected 2 section caps in the world, got %d" % caps)
	_root.world.set_section(false)
	await _idle()

	# --- D. overhangs + bed fit ---------------------------------------------
	var ov := Inspect.overhangs(e, Vector3(0, 0, 1), 45.0)
	# A box has no overhang: the bottom face is the bed face.
	if float(ov["ratio"]) > 1e-9:
		return _fail("D: a box should have no overhang, got %f" % float(ov["ratio"]))
	# Taper the box outward (10°): the underside stays on the bed, walls lean
	# outward by 10° (< 45°): still none. Negative taper -60°: walls overhang.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(box, "taper_deg", 60.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var ov2 := Inspect.overhangs(_entry(bodies, box), Vector3(0, 0, 1), 45.0)
	if float(ov2["ratio"]) <= 0.1:
		return _fail("D: 60° outward taper walls should overhang, got %f" % float(ov2["ratio"]))
	_root.stack.undo()
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	var fit := Inspect.fits_bed(_entry(bodies, box), Vector3(35, 35, 50))
	if not bool(fit["fits"]):
		return _fail("D: 40x30x10 should fit a 35x35x50 bed standing on its side")
	if bool(Inspect.fits_bed(_entry(bodies, box), Vector3(20, 20, 20))["fits"]):
		return _fail("D: should not fit a 20 cube")

	# --- E. measure candidates snap ------------------------------------------
	_root.fit_view()   # snap tolerance is 8 px at the current zoom
	await _idle()
	_root._on_measure_pressed()
	if not _root.picking_measure:
		return _fail("E: measure should arm")
	var near_corner := _root._measure_candidate(Vector3(39.7, 29.7, 50), Vector3(0, 0, -1))
	if near_corner.is_empty() or String(near_corner["label"]) != "corner" \
			or (near_corner["pos"] as Vector3).distance_to(Vector3(40, 30, 10)) > 1e-4:
		return _fail("E: should snap to the (40,30,10) corner: %s" % str(near_corner))
	var near_edge := _root._measure_candidate(Vector3(20, 29.8, 50), Vector3(0, 0, -1))
	if near_edge.is_empty() or String(near_edge["label"]) != "edge" \
			or absf((near_edge["pos"] as Vector3).y - 30.0) > 1e-4:
		return _fail("E: should snap to the y=30 top edge: %s" % str(near_edge))
	var mid := _root._measure_candidate(Vector3(20, 15, 50), Vector3(0, 0, -1))
	if mid.is_empty() or String(mid["label"]) != "face":
		return _fail("E: face interior should not snap: %s" % str(mid))
	_root._end_measure()
	if _root.picking_measure:
		return _fail("E: measure should end")

	# --- F. material persists with the document --------------------------------
	_root.doc.material = "steel"
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	if loaded.material != "steel":
		return _fail("F: material lost in round trip")
	return true
