extends SceneTree

# M39: face identity + explicit targets — a sketch on a face follows the
# face when the extrude changes, explicit boolean targets spare the
# neighbour the AABB rule would have hit, a pattern of a CUT feature
# re-cuts per instance, a later cut targets a MOVED body where it is, a
# lost face reference is a warning not a crash, and pre-M39 snapshot
# planes adopt a matching face on load.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	if ok:
		print("M39_TOPOLOGY_REFS OK: face plane follows its extrude, explicit "
			+ "targets, intersect, pattern/mirror of a cut feature re-cut per "
			+ "instance, in-order move before cut, lost ref = warning chip, "
			+ "snapshot-plane migration, serialization")
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m39_topology_refs: " + msg)
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


func _rect_in_active(a: Vector2, b: Vector2) -> void:
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view((a + b) * 0.5, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)


func _sketch_rect(plane: String, a: Vector2, b: Vector2) -> String:
	var fid := _root.create_sketch(plane)
	_rect_in_active(a, b)
	_root.finish_sketch()
	return fid


func _body(bodies: Array, id: String) -> Dictionary:
	for b: Dictionary in bodies:
		if String(b["id"]) == id:
			return b
	return {}


func _vol(bodies: Array, id: String) -> float:
	var b := _body(bodies, id)
	return BodyBuilder.mesh_volume(b["mesh"]) if not b.is_empty() else -1.0


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	if not SolidKernel.available():
		return _fail("kernel missing")

	# --- A. sketch on a face follows the face -------------------------------
	var s1 := _sketch_rect("XY", Vector2(0, 0), Vector2(40, 30))
	var plate := _root.extrude(s1, Vector2(20, 15), 10.0)
	await _idle()
	# Pick the top face by ray (what the click does) — expect face id + body.
	var face := _root.world.pick_face(Vector3(20, 15, 50), Vector3(0, 0, -1))
	if face.is_empty() or String(face["body"]) != plate or int(face.get("face", -1)) < 0:
		return _fail("A: top-face pick should return body + face id, got %s" % str(face))
	if SolidKernel.feature_of_face(int(face["face"])) != SolidKernel.ordinal_of(plate):
		return _fail("A: face id should belong to the plate's extrude")
	var s2 := _root.create_sketch_on_face(face["point"], face["normal"],
		String(face["body"]), int(face["face"]))
	var sf2 := _root.doc.sketch_feature(s2)
	var pf := _root.doc.plane_feature(sf2.plane)
	if pf == null or pf.plane_kind != PlaneFeature.KIND_FACE or pf.ref == null:
		return _fail("A: sketch-on-face should mint a FACE plane with a ref")
	if absf(pf.transform().origin.z - 10.0) > 1e-6:
		return _fail("A: face plane should sit at z=10, got %f" % pf.transform().origin.z)
	_rect_in_active(Vector2(10, 10), Vector2(20, 20))
	_root.finish_sketch()
	var boss := _root.extrude(s2, Vector2(15, 15), 5.0, SolidFeature.OP_JOIN)
	await _idle()
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	if bodies.size() != 1 or absf(_vol(bodies, plate) - (12000.0 + 500.0)) > 0.5:
		return _fail("A: plate+boss volume wrong: %s" % str(bodies.map(func(b): return _vol(bodies, b["id"]))))
	# Edit the plate's height: the face plane must move with it.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(plate, "distance", 25.0))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(pf.transform().origin.z - 25.0) > 1e-6:
		return _fail("A: face plane should follow to z=25, got %f" % pf.transform().origin.z)
	if absf(_vol(bodies, plate) - (30000.0 + 500.0)) > 0.5:
		return _fail("A: boss should ride on the taller plate: %f" % _vol(bodies, plate))
	if pf.rebuild_error != "":
		return _fail("A: unexpected warning on the face plane: " + pf.rebuild_error)
	var top_z := (bodies[0]["mesh"] as ArrayMesh).get_aabb().end.z
	if absf(top_z - 30.0) > 1e-4:
		return _fail("A: body top should be at 30, got %f" % top_z)
	_root.stack.undo()
	await _idle()

	# --- B. explicit targets spare the neighbour ---------------------------
	# Second plate touching the first's AABB (adjacent in x, same z range).
	var s3 := _sketch_rect("XY", Vector2(40, 0), Vector2(80, 30))
	var plate2 := _root.extrude(s3, Vector2(60, 15), 10.0)
	await _idle()
	# A cut straddling the seam: AABB rule would hit both.
	var s4 := _sketch_rect("XY", Vector2(35, 10), Vector2(45, 20))
	var cut_auto := _root.extrude(s4, Vector2(40, 15), 10.0, SolidFeature.OP_CUT)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, plate) - (12500.0 - 500.0)) > 0.5 \
			or absf(_vol(bodies, plate2) - (12000.0 - 500.0)) > 0.5:
		return _fail("B: auto cut should hit both plates: %f / %f"
			% [_vol(bodies, plate), _vol(bodies, plate2)])
	_root.stack.undo()
	await _idle()
	var cut_t := _root.extrude(s4, Vector2(40, 15), 10.0, SolidFeature.OP_CUT, [plate2])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, plate) - 12500.0) > 0.5 \
			or absf(_vol(bodies, plate2) - 11500.0) > 0.5:
		return _fail("B: targeted cut should spare plate 1: %f / %f"
			% [_vol(bodies, plate), _vol(bodies, plate2)])
	var cf := _root.doc.feature_by_id(cut_t) as SolidFeature
	if cf.targets != [plate2]:
		return _fail("B: targets not stored")
	# Serialization keeps targets.
	var loaded := Serializer.from_json(Serializer.to_json(_root.doc))
	var lcf := loaded.feature_by_id(cut_t) as SolidFeature
	if lcf == null or lcf.targets != [plate2]:
		return _fail("B: targets lost in round trip")
	var lpf := loaded.plane_feature(sf2.plane)
	if lpf == null or lpf.plane_kind != PlaneFeature.KIND_FACE or lpf.ref == null \
			or lpf.ref.body != plate:
		return _fail("B: face plane ref lost in round trip")

	# --- C. intersect -------------------------------------------------------
	var s5 := _sketch_rect("XY", Vector2(20, 0), Vector2(60, 30))
	var inter := _root.extrude(s5, Vector2(40, 15), 10.0, SolidFeature.OP_INTERSECT, [plate])
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# Plate 1 ∩ (x 20..40) = 20x30x10 minus nothing of the boss (boss x 10..20 is outside)
	if absf(_vol(bodies, plate) - 6000.0) > 0.5:
		return _fail("C: intersect volume %f, want 6000" % _vol(bodies, plate))
	if absf(_vol(bodies, plate2) - 11500.0) > 0.5:
		return _fail("C: intersect leaked onto plate 2")
	_root.stack.undo()
	await _idle()

	# --- D. pattern of a CUT feature re-cuts per instance -------------------
	var s6 := _sketch_rect("XY", Vector2(42, 2), Vector2(46, 6))
	var hole := _root.extrude(s6, Vector2(44, 4), 10.0, SolidFeature.OP_CUT, [plate2])
	await _idle()
	var pat := _root.pattern_body(hole, {"mode": PatternBodyFeature.MODE_LINEAR,
		"count1": 4, "offset1": Vector3(8, 0, 0), "count2": 2,
		"offset2": Vector3(0, 20, 0)})   # rows at y 2..6 and 22..26, clear of the notch
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	# 8 holes of 4x4x10 = 1280 out of plate2 (11500 after the seam cut).
	if absf(_vol(bodies, plate2) - (11500.0 - 8.0 * 160.0)) > 0.5:
		return _fail("D: pattern of cut should remove 8 holes: %f" % _vol(bodies, plate2))
	if bodies.size() != 2:
		return _fail("D: feature pattern must not add bodies, got %d" % bodies.size())
	var patf := _root.doc.feature_by_id(pat) as Feature
	if patf.rebuild_error != "":
		return _fail("D: pattern error: " + patf.rebuild_error)
	# Mirror of the same cut across YZ... (x -> -x lands outside both plates → error, kept)
	var mir := _root.mirror_body(hole, "XZ")   # y -> -y: outside the plates
	await _idle()
	var mirf := _root.doc.feature_by_id(mir) as Feature
	bodies = await BodyBuilder.build(_root.doc, _root)
	if mirf.rebuild_error == "":
		return _fail("D: mirrored cut outside every body should flag an error")
	_root.stack.undo()
	await _idle()

	# --- E. a move BEFORE a cut: the cut targets the moved body -------------
	var s7 := _sketch_rect("XY", Vector2(100, 0), Vector2(120, 20))
	var block := _root.extrude(s7, Vector2(110, 10), 10.0)
	await _idle()
	_root.move_body(block, Vector3(50, 0, 0))   # now x 150..170
	await _idle()
	var s8 := _sketch_rect("XY", Vector2(155, 5), Vector2(165, 15))
	var cut_moved := _root.extrude(s8, Vector2(160, 10), 10.0, SolidFeature.OP_CUT)
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if absf(_vol(bodies, block) - (4000.0 - 1000.0)) > 0.5:
		return _fail("E: cut should carve the MOVED block: %f" % _vol(bodies, block))
	var cmf := _root.doc.feature_by_id(cut_moved) as Feature
	if cmf.rebuild_error != "":
		return _fail("E: " + cmf.rebuild_error)

	# --- F. lost reference = warning, last pose stands ----------------------
	# Suppress the plate the face plane references → sketch on it warns.
	_root.stack.push_no_merge(CmdSetFeatureFlag.new(plate, "suppressed", true))
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if pf.rebuild_error == "" or pf.rebuild_level != "warning":
		return _fail("F: face plane should warn when its body is gone (%s/%s)"
			% [pf.rebuild_error, pf.rebuild_level])
	if absf(pf.transform().origin.z - 10.0) > 1e-6:
		return _fail("F: last pose should stand (z=10), got %f" % pf.transform().origin.z)
	var chip := _root.timeline.find_child("Chip_" + pf.id, true, false) as Button
	if chip == null or chip.theme_type_variation != "TimelineChipWarn":
		return _fail("F: plane chip should be warning-tinted, got %s"
			% (chip.theme_type_variation if chip != null else "<none>"))
	_root.stack.undo()
	await _idle()
	bodies = await BodyBuilder.build(_root.doc, _root)
	if pf.rebuild_error != "":
		return _fail("F: warning should clear once the body is back")

	# --- G. migration: a pre-M39 snapshot plane adopts its face ------------
	var snap: Dictionary = JSON.parse_string(Serializer.to_json(_root.doc))
	# Rewrite the face plane as an old-style custom snapshot (no ref).
	for fd in (snap["features"] as Array):
		if String((fd as Dictionary).get("id", "")) == pf.id:
			(fd as Dictionary)["plane_kind"] = "custom"
			(fd as Dictionary).erase("ref")
	var doc2 := Serializer.from_json(JSON.stringify(snap))
	var pf2 := doc2.plane_feature(pf.id)
	if pf2 == null or pf2.plane_kind != PlaneFeature.KIND_FACE or pf2.ref == null \
			or pf2.ref.body != "":
		return _fail("G: snapshot plane should load as an UNBOUND face plane")
	# Unbound planes serialize back as custom — byte-identical for old files.
	if String((pf2.to_dict() as Dictionary).get("plane_kind", "")) != "custom":
		return _fail("G: unbound face plane should still save as custom")
	await BodyBuilder.build(doc2, _root)
	if pf2.ref.body != plate:
		return _fail("G: first rebuild should bind the plane to the plate, got '%s'" % pf2.ref.body)
	if String((pf2.to_dict() as Dictionary).get("plane_kind", "")) != "face":
		return _fail("G: bound plane should save as face")
	return true
