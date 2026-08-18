extends SceneTree

# M22: construction planes — offset-plane transforms (all bases + chaining),
# sketching and extruding on them, parametric offset edits, face-derived
# custom planes, the sketch-on-face batch, delete protection, rollback, and
# serialization.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m22_planes: " + msg)
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


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- offset-plane transforms, every base.
	var p1 := _root.create_offset_plane("XY", 25.0)
	if p1 == "":
		return _fail("create_offset_plane refused XY")
	var pf1 := _root.doc.plane_feature(p1)
	if pf1 == null or pf1.kind() != "plane" or pf1.name != "Plane1":
		return _fail("plane feature wrong: %s" % (pf1.name if pf1 else "null"))
	var xf1 := pf1.transform()
	if not xf1.origin.is_equal_approx(Vector3(0, 0, 25)):
		return _fail("XY+25 origin wrong: %s" % xf1.origin)
	if not xf1.basis.z.is_equal_approx(Vector3(0, 0, 1)):
		return _fail("XY+25 normal wrong")
	var pxz := _root.create_offset_plane("XZ", 10.0)
	var xfz := _root.doc.plane_feature(pxz).transform()
	if not xfz.origin.is_equal_approx(Vector3(0, -10, 0)):
		return _fail("XZ+10 origin wrong: %s" % xfz.origin)
	# Chained: an offset plane on an offset plane.
	var p2 := _root.create_offset_plane(p1, 10.0)
	var xf2 := _root.doc.plane_feature(p2).transform()
	if not xf2.origin.is_equal_approx(Vector3(0, 0, 35)):
		return _fail("chained offset wrong: %s" % xf2.origin)
	if _root.create_offset_plane("bogus", 5.0) != "":
		return _fail("bogus base accepted")

	# --- sketch on the offset plane: world positions carry the offset.
	var sid := _root.create_sketch(p1)
	var sf := _root.doc.sketch_feature(sid)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	if not sf.to_world(Vector2(10, 5)).is_equal_approx(Vector3(10, 5, 25)):
		return _fail("sketch-on-plane world pos wrong: %s"
			% sf.to_world(Vector2(10, 5)))
	if _root.world._grid_xf.origin.z != 25.0:
		return _fail("grid did not move to the offset plane: %s"
			% _root.world._grid_xf.origin)
	_root.finish_sketch()

	# --- extrude from it lands at the plane's height.
	var eid := _root.extrude(sid, Vector2(20, 15), 12.7)
	if eid == "":
		return _fail("extrude refused offset-plane profile")
	var ef := _root.doc.feature_by_id(eid) as ExtrudeFeature
	var mesh := ef.build_mesh(_root.doc)
	if absf(ExtrudeFeature.mesh_volume(mesh) - 1200.0 * 12.7) > 30.0:
		return _fail("offset extrude volume wrong")
	var box := mesh.get_aabb()
	if absf(box.position.z - 25.0) > 1e-4 or absf(box.end.z - 37.7) > 1e-4:
		return _fail("offset extrude z-range wrong: %f..%f"
			% [box.position.z, box.end.z])

	# --- parametric edit: driving the offset moves the sketch AND the solid.
	_root.stack.push_no_merge(CmdSetPlaneOffset.new(p1, 40.0))
	if not sf.to_world(Vector2.ZERO).is_equal_approx(Vector3(0, 0, 40)):
		return _fail("offset edit did not move the sketch")
	var box2 := ef.build_mesh(_root.doc).get_aabb()
	if absf(box2.position.z - 40.0) > 1e-4:
		return _fail("offset edit did not move the solid: %f" % box2.position.z)
	_root.stack.undo()
	if not sf.to_world(Vector2.ZERO).is_equal_approx(Vector3(0, 0, 25)):
		return _fail("offset edit undo failed")

	# --- face transforms: orthonormal, right-handed, origin = the world
	# origin's projection onto the face plane.
	var fxf := PlaneFeature.face_transform(Vector3(20, 15, 37.7), Vector3(0, 0, 1))
	if not fxf.origin.is_equal_approx(Vector3(0, 0, 37.7)):
		return _fail("face plane origin wrong: %s" % fxf.origin)
	if not fxf.basis.z.is_equal_approx(Vector3(0, 0, 1)):
		return _fail("face plane normal wrong")
	var side := PlaneFeature.face_transform(Vector3(40, 15, 30), Vector3(1, 0, 0))
	if not side.basis.z.is_equal_approx(Vector3(1, 0, 0)) \
			or not side.origin.is_equal_approx(Vector3(40, 0, 0)):
		return _fail("side face plane wrong")
	if not side.basis.x.cross(side.basis.y).is_equal_approx(side.basis.z):
		return _fail("face basis not right-handed")

	# --- sketch-on-face: one batch = plane + sketch, one undo step.
	var feats_before := _root.doc.features.size()
	var fsid := _root.create_sketch_on_face(Vector3(20, 15, 37.7), Vector3(0, 0, 1))
	var fsf := _root.doc.sketch_feature(fsid)
	if fsf == null or _root.doc.features.size() != feats_before + 2:
		return _fail("sketch-on-face did not add plane+sketch")
	if not fsf.plane_transform().origin.is_equal_approx(Vector3(0, 0, 37.7)):
		return _fail("face sketch plane wrong: %s" % fsf.plane_transform().origin)
	_root.finish_sketch()
	_root.stack.undo()
	if _root.doc.features.size() != feats_before:
		return _fail("sketch-on-face not one undo step")
	_root.stack.redo()
	if _root.doc.sketch_feature(fsid) == null:
		return _fail("sketch-on-face redo failed")

	# --- delete protection: p1 carries a sketch and a chained plane.
	_root.request_delete_feature(p1)
	if _root.doc.plane_feature(p1) == null:
		return _fail("referenced plane was deleted")
	# An unreferenced plane deletes fine.
	var lone := _root.create_offset_plane("YZ", 5.0)
	_root.request_delete_feature(lone)
	if _root.doc.plane_feature(lone) != null:
		return _fail("unreferenced plane refused deletion")

	# --- plane quads: visible construction planes are pickable; the NEAREST
	# wins. Topmost here is the face plane (z=37.7), over p2 (35) and p1 (25).
	var face_plane: String = _root.doc.sketch_feature(fsid).plane
	_root.world.set_planes_visible(true)
	var picked := _root.world.pick_plane(Vector3(20, 15, 100), Vector3(0, 0, -1))
	if picked != face_plane:
		return _fail("pick_plane over stacked planes returned %s" % picked)
	_root.world.set_planes_visible(false)

	# --- rollback before everything hides the construction planes.
	_root.stack.push_no_merge(CmdSetMarker.new(_root.doc.timeline_marker, 0))
	if not _root.world._cplane_meshes.is_empty():
		return _fail("rolled-back planes still built")
	_root.stack.undo()
	if _root.world._cplane_meshes.size() != 4:
		return _fail("planes did not return after rollback undo: %d"
			% _root.world._cplane_meshes.size())

	# --- serialization: byte-identical round trip, resolution survives.
	var text := Serializer.to_json(_root.doc)
	var loaded := Serializer.from_json(text)
	if Serializer.to_json(loaded) != text:
		return _fail("round trip not byte-identical")
	if not loaded.plane_transform(p1).origin.is_equal_approx(Vector3(0, 0, 25)):
		return _fail("loaded plane transform wrong")
	var lsf := loaded.sketch_feature(sid)
	if not lsf.plane_transform().origin.is_equal_approx(Vector3(0, 0, 25)):
		return _fail("loaded sketch did not resolve its plane")
	var lef := loaded.feature_by_id(eid) as ExtrudeFeature
	var lbox := lef.build_mesh(loaded).get_aabb()
	if absf(lbox.position.z - 25.0) > 1e-4:
		return _fail("loaded extrude z wrong")

	print("M22_PLANES OK: offset transforms (XY/XZ/chained), sketch+extrude "
		+ "on plane, parametric offset edit, face planes, sketch-on-face "
		+ "batch, delete guard, rollback, serialization")
	return true
