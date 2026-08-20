extends SceneTree

# QA fix round for volume-2 §M35.4 update (2026-08-20):
#  A. A cylinder with a filleted top rim takes a CHAMFER on its bottom rim
#     (and every other fillet/chamfer pairing): the combined build used to
#     refuse with "the cap failed to triangulate" because the multi-edge
#     corner solve offset each ~5° circle vertex along its own edge normal
#     instead of mitering, zigzagging the cap boundary. Every pairing now
#     builds watertight with the analytic ring volume removed.

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
	push_error("m38_qa_fixes: " + msg)
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


func _body_mesh(bodies: Array, body_id: String) -> ArrayMesh:
	for b: Dictionary in bodies:
		if String(b["id"]) == body_id:
			return b["mesh"]
	return null


## Closed 2-manifold check: every directed edge appears exactly once and
## its reverse exactly once.
func _manifold_ok(mesh: ArrayMesh) -> bool:
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var edges := {}
	var t := 0
	while t + 2 < verts.size():
		for pair in [[verts[t], verts[t + 1]], [verts[t + 1], verts[t + 2]],
				[verts[t + 2], verts[t]]]:
			var k := "%.4f,%.4f,%.4f|%.4f,%.4f,%.4f" % [
				pair[0].x, pair[0].y, pair[0].z, pair[1].x, pair[1].y, pair[1].z]
			edges[k] = int(edges.get(k, 0)) + 1
		t += 3
	for k in edges:
		var parts: PackedStringArray = String(k).split("|")
		var rk := parts[1] + "|" + parts[0]
		if int(edges[k]) != 1 or int(edges.get(rk, 0)) != 1:
			return false
	return true


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	await _idle()

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
	var base: Array = await BodyBuilder.build(_root.doc, _root)
	var base_mesh := _body_mesh(base, cyl_id)
	if base_mesh == null:
		return _fail("cylinder did not build")
	var v_base := BodyBuilder.mesh_volume(base_mesh)
	# Effective radius of the tessellated profile (the analytic ring volumes
	# below are about THIS body, not the ideal circle).
	var r_eff := sqrt(v_base / 12.0 / PI)
	var s := 2.0
	# Ring volumes (Pappus): chamfer triangle s²/2 with centroid s/3 in from
	# the wall; fillet corner (1-π/4)s² with centroid ≈0.2234·s in.
	var v_cham := TAU * (r_eff - s / 3.0) * (s * s * 0.5)
	var v_fil := TAU * (r_eff - 0.2234 * s) * ((1.0 - PI / 4.0) * s * s)
	var removed := {EdgeTreatFeature.KIND_FILLET: v_fil,
		EdgeTreatFeature.KIND_CHAMFER: v_cham}

	for combo: Array in [
			[EdgeTreatFeature.KIND_FILLET, EdgeTreatFeature.KIND_CHAMFER],
			[EdgeTreatFeature.KIND_CHAMFER, EdgeTreatFeature.KIND_FILLET],
			[EdgeTreatFeature.KIND_FILLET, EdgeTreatFeature.KIND_FILLET],
			[EdgeTreatFeature.KIND_CHAMFER, EdgeTreatFeature.KIND_CHAMFER]]:
		var tag := "%s top + %s bottom" % [combo[0], combo[1]]
		var f1 := _root.edge_treat(cyl_id, combo[0], s, false, true, false)
		if f1 == "":
			return _fail("A: first treatment refused (%s)" % tag)
		var f2 := _root.edge_treat(cyl_id, combo[1], s, false, false, true)
		if f2 == "":
			return _fail("A: second rim treatment refused (%s): %s"
				% [tag, EdgeTreatFeature.build_error])
		var bodies: Array = await BodyBuilder.build(_root.doc, _root)
		var mesh := _body_mesh(bodies, cyl_id)
		if mesh == null:
			return _fail("A: no body after %s" % tag)
		if not _manifold_ok(mesh):
			return _fail("A: %s is not watertight" % tag)
		var want: float = v_base - float(removed[combo[0]]) \
			- float(removed[combo[1]])
		var got := BodyBuilder.mesh_volume(mesh)
		if absf(got - want) > want * 0.005:
			return _fail("A: %s volume %f vs %f" % [tag, got, want])
		_root.stack.undo()
		_root.stack.undo()
		await _idle()

	print("M38_QA_FIXES OK: a second rim treatment on a cylinder builds "
		+ "watertight for every fillet/chamfer pairing")
	return true
