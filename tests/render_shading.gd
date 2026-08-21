extends SceneTree

# Solid shading: the two things that decided whether a body has any visible
# form at all.
#
# 1. WINDING. Godot rasterises clockwise-wound triangles as FRONT faces; every
#    mesh here is counter-clockwise-outward (the STL / volume-integral /
#    kernel convention). Handed over unchanged, a body is entirely back-facing
#    and a double-sided material flips the normal of every fragment — the
#    model shades inside-out and a cylinder renders as one flat silhouette.
#    CadWorld flips the winding at the render boundary; the model mesh keeps
#    its own convention.
# 2. SMOOTH NORMALS. A tessellated cylinder wall is ONE kernel face, so its
#    triangles must share averaged vertex normals or the wall reads as a fan
#    of facets. Face boundaries (wall -> cap) must stay hard.
#
# Plus the studio light rig: four lights that follow the camera azimuth.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("render_shading: " + msg)
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


func _signed_volume(v: PackedVector3Array) -> float:
	var vol := 0.0
	for i in range(0, v.size(), 3):
		vol += v[i].cross(v[i + 1]).dot(v[i + 2]) / 6.0
	return vol


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var f1 := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("circle")
	_click(Vector2(0, 0))
	_click(Vector2(25, 0))
	_root.finish_sketch()
	if _root.extrude(f1, Vector2(0, 0), 40.0) == "":
		return _fail("extrude refused the circle")

	# --- the MODEL mesh: counter-clockwise outward, normals agreeing.
	var bodies := _root.world.bodies()
	if bodies.size() != 1:
		return _fail("expected one body, got %d" % bodies.size())
	var model := bodies[0]["mesh"] as ArrayMesh
	var marr := model.surface_get_arrays(0)
	var mv: PackedVector3Array = marr[Mesh.ARRAY_VERTEX]
	var mn: PackedVector3Array = marr[Mesh.ARRAY_NORMAL]
	if _signed_volume(mv) <= 0.0:
		return _fail("model mesh is not CCW-outward (volume %f)" % _signed_volume(mv))

	# --- the DISPLAYED mesh: same triangles, winding reversed for Godot,
	# normals still outward. That mismatch is the whole point: Godot's
	# front-face rule wants the reversed winding, the normals stay honest.
	var smi: MeshInstance3D = null
	for c in _root.world._sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.has_meta("is_body") and not mi.is_queued_for_deletion():
			smi = mi
	if smi == null:
		return _fail("no body mesh in the scene")
	var darr := (smi.mesh as ArrayMesh).surface_get_arrays(0)
	var dv: PackedVector3Array = darr[Mesh.ARRAY_VERTEX]
	var dn: PackedVector3Array = darr[Mesh.ARRAY_NORMAL]
	if dv.size() != mv.size():
		return _fail("display mesh lost triangles (%d vs %d)" % [dv.size(), mv.size()])
	if _signed_volume(dv) >= 0.0:
		return _fail("display winding was not flipped for Godot's front-face rule")
	var backwards := 0
	for i in range(0, dv.size(), 3):
		# Winding normal must now OPPOSE the stored normal — that is what
		# makes Godot's front-facing test agree with the shading normal.
		if (dv[i + 1] - dv[i]).cross(dv[i + 2] - dv[i]).dot(dn[i]) > 0.0:
			backwards += 1
	if backwards != 0:
		return _fail("%d display triangles still wound the model's way" % backwards)
	# Triangle ORDER must survive: face ids and the pick's triangle index are
	# keyed on it, so triangle t must still cover the same three points.
	for i in [0, dv.size() / 6 * 3, dv.size() - 3]:
		var same := {}
		for k in 3:
			same[mv[i + k].snappedf(1e-4)] = true
		for k in 3:
			if not same.has(dv[i + k].snappedf(1e-4)):
				return _fail("display triangle %d is not the model's triangle" % (i / 3))

	# --- smooth shading INSIDE the wall face, hard at the cap boundary.
	var faceted := 0
	var smooth := 0
	var cap_tris := 0
	for i in range(0, mv.size(), 3):
		var fn := (mv[i + 1] - mv[i]).cross(mv[i + 2] - mv[i]).normalized()
		if absf(fn.z) > 0.9:
			cap_tris += 1
			for k in 3:
				if absf(mn[i + k].z) < 0.999:
					return _fail("cap normal leaked across the face boundary: %v"
						% mn[i + k])
			continue
		if mn[i].is_equal_approx(mn[i + 1]) and mn[i].is_equal_approx(mn[i + 2]):
			faceted += 1
		else:
			smooth += 1
	if cap_tris == 0:
		return _fail("no cap triangles found")
	if smooth < faceted:
		return _fail("cylinder wall is still flat-shaded (%d faceted, %d smooth)"
			% [faceted, smooth])

	# --- the studio rig: four lights, all aimed, spinning with the camera.
	var lights: Array = []
	for c in _root.world.get_children():
		if c is DirectionalLight3D:
			lights.append(c)
	if lights.size() != CadWorld.LIGHT_RIG.size():
		return _fail("expected %d rig lights, got %d"
			% [CadWorld.LIGHT_RIG.size(), lights.size()])
	var key := lights[0] as DirectionalLight3D
	# The key light shines DOWNWARD: its forward (-Z, the direction light
	# travels) must have a negative Z, or tops shade darker than undersides.
	var fwd := -key.global_transform.basis.z
	if fwd.z >= 0.0:
		return _fail("key light shines upward: %v" % fwd)
	if key.light_energy <= 0.0:
		return _fail("key light has no energy")
	var before := fwd
	_root.world.sync_lights(PI / 2.0)
	var after := -key.global_transform.basis.z
	if after.is_equal_approx(before):
		return _fail("rig did not follow the camera azimuth")
	if not is_equal_approx(after.z, before.z):
		return _fail("azimuth spin tilted the rig (z %f -> %f)" % [before.z, after.z])

	print("RENDER_SHADING OK: display winding flipped for Godot, model winding "
		+ "kept, wall smooth-shaded (%d tris) with hard caps, %d-light rig follows the view"
		% [smooth, lights.size()])
	return true
