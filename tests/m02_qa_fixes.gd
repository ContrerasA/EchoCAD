extends SceneTree

# M2 manual-QA follow-ups: the view cube renders in its own world (no stray
# box at the model origin, no bodies inside the cube), origin planes stay
# hidden until a plane is being picked, the browser tree drives visibility,
# solids are click-selectable in model mode, and both modes share one
# background colour.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m02_qa_fixes: " + msg)
	return false


## Build a square sketch on XY and extrude it, returning the extrude id.
func _make_body() -> String:
	var sid := _root.create_sketch("XY")
	_root.finish_sketch()
	var sk := _root.doc.sketch_feature(sid).sketch
	var pts: Array[Vector2] = [
		Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20)]
	var ents: Array[SketchEntity] = []
	for i in 4:
		var a := SketchPoint.new()
		a.id = "p%d" % i
		a.pos = pts[i]
		ents.append(a)
	for i in 4:
		var l := SketchLine.new()
		l.id = "l%d" % i
		l.p0 = "p%d" % i
		l.p1 = "p%d" % ((i + 1) % 4)
		ents.append(l)
	_root.stack.push_no_merge(CmdAddEntities.new(sid, ents))
	return _root.extrude(sid, Vector2.ZERO, 30.0)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var world: CadWorld = _root.world

	# --- view cube isolation ---------------------------------------------
	# The cube's SubViewport must own its World3D. Sharing the main one is
	# what put a phantom cube at the model origin and leaked every body into
	# the corner widget.
	var cube_vp := _root.view_cube.get_child(0) as SubViewport
	if cube_vp == null:
		return _fail("view cube has no SubViewport")
	if not cube_vp.own_world_3d:
		return _fail("view cube SubViewport shares the main World3D")
	if cube_vp.find_world_3d() == _root.get_viewport().find_world_3d():
		return _fail("view cube world is the main world")
	# Nothing cube-shaped may live in the model scene.
	for c in world.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh is BoxMesh:
			return _fail("a BoxMesh is in the model world: " + mi.name)

	# --- origin planes hidden by default ----------------------------------
	for pname: String in SketchFeature.PLANES:
		var mi := world.get_node("Plane" + pname) as MeshInstance3D
		if mi == null:
			return _fail("missing plane node " + pname)
		if mi.visible:
			return _fail("plane %s is visible in plain model mode" % pname)
	# Create Sketch reveals them...
	_root._on_create_sketch()
	for pname: String in SketchFeature.PLANES:
		if not (world.get_node("Plane" + pname) as MeshInstance3D).visible:
			return _fail("plane %s stayed hidden while picking" % pname)
	# ...and Esc puts them away again.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_root.handle_app_key(esc)
	for pname: String in SketchFeature.PLANES:
		if (world.get_node("Plane" + pname) as MeshInstance3D).visible:
			return _fail("plane %s still visible after Esc" % pname)

	# --- a ticked plane is VISIBLE, right there in model mode -------------
	# The tick is a show/hide switch, not a permission the mode can veto.
	world.set_plane_shown("XY", true)
	if not (world.get_node("PlaneXY") as MeshInstance3D).visible:
		return _fail("ticking XY did not show it in plain model mode")
	if (world.get_node("PlaneXZ") as MeshInstance3D).visible:
		return _fail("unticked XZ showed itself")
	world.set_plane_shown("XY", false)
	if (world.get_node("PlaneXY") as MeshInstance3D).visible:
		return _fail("unticking XY did not hide it")

	# Plane-picking force-shows all three, then restores the ticks — an
	# unticked plane must go back to hidden once the pick ends.
	world.set_plane_shown("XZ", true)
	world.set_planes_visible(true)
	for pname: String in SketchFeature.PLANES:
		if not (world.get_node("Plane" + pname) as MeshInstance3D).visible:
			return _fail("plane %s hidden during a pick" % pname)
	world.set_planes_visible(false)
	if not (world.get_node("PlaneXZ") as MeshInstance3D).visible:
		return _fail("ticked XZ lost its visibility after the pick")
	if (world.get_node("PlaneXY") as MeshInstance3D).visible:
		return _fail("unticked XY stayed visible after the pick")
	world.set_plane_shown("XZ", false)
	world.set_origin_shown(false)
	if (world.get_node("Axes") as MeshInstance3D).visible:
		return _fail("origin axes ignored their browser toggle")
	world.set_origin_shown(true)

	# --- planes are Fusion quadrants, not origin-centred sheets -----------
	# The quad must start AT the origin and run out along +u/+v only. Probe
	# with rays down the plane normal at points either side of the origin.
	for pname: String in SketchFeature.PLANES:
		var b := SketchFeature.plane_basis(pname)
		var q := CadWorld.PLANE_SIDE
		# Inside the quadrant, near the far corner.
		var inside := b.x * (q * 0.8) + b.y * (q * 0.8)
		if world.pick_plane(inside + b.z * 500.0, -b.z) != pname:
			return _fail("plane %s does not cover its own +u/+v quadrant" % pname)
		# The three opposite quadrants must be empty.
		for signs: Vector2 in [Vector2(-1, -1), Vector2(-1, 1), Vector2(1, -1)]:
			var outside := b.x * (q * 0.5 * signs.x) + b.y * (q * 0.5 * signs.y)
			if world.pick_plane(outside + b.z * 500.0, -b.z) == pname:
				return _fail("plane %s extends into quadrant %s — it should "
					% [pname, str(signs)] + "occupy +u/+v only")
		# Just past the far corner is off the quad too.
		var far := b.x * (q * 1.2) + b.y * (q * 1.2)
		if world.pick_plane(far + b.z * 500.0, -b.z) == pname:
			return _fail("plane %s extends past its side length" % pname)

	# --- body selection ---------------------------------------------------
	var bid := _make_body()
	if bid == "":
		return _fail("extrude produced no body")
	if _root.browser == null:
		return _fail("no browser tree")
	# Ray straight down the +Z axis at the body's top face.
	var hit := world.pick_body(Vector3(0, 0, 500), Vector3(0, 0, -1))
	if hit != bid:
		return _fail("pick_body returned '%s', want '%s'" % [hit, bid])
	_root.select_body(bid)
	if world.selected_body() != bid:
		return _fail("select_body did not stick")
	var mesh := world._body_mesh(bid)
	if mesh == null:
		return _fail("no mesh for body " + bid)
	var mat := mesh.material_override as StandardMaterial3D
	if mat.albedo_color != CadWorld.COLOR_BODY_SELECTED:
		return _fail("selected body is not highlighted")
	# Selecting must not touch the model — it is view state.
	var depth := _root.stack.can_undo()
	_root.select_body("")
	if _root.stack.can_undo() != depth:
		return _fail("selecting a body pushed onto the command stack")
	if (mesh.material_override as StandardMaterial3D).albedo_color \
			!= CadWorld.COLOR_BODY:
		return _fail("deselected body kept its highlight")

	# --- hidden bodies are neither pickable nor framed --------------------
	# The sketch's own line mesh stays in the bounds either way (it is a
	# separate child), so compare heights: only the solid has extent in Z.
	var tall := world.model_bounds().size.z
	world.set_body_shown(bid, false)
	if world.pick_body(Vector3(0, 0, 500), Vector3(0, 0, -1)) != "":
		return _fail("hidden body is still pickable")
	if world.model_bounds().size.z >= tall:
		return _fail("hidden body still contributes to model bounds")
	world.set_body_shown(bid, true)
	if absf(world.model_bounds().size.z - tall) > 1e-6:
		return _fail("re-shown body missing from model bounds")

	# --- one background colour for both modes -----------------------------
	if SketchView.COLOR_BG != CadWorld.COLOR_BG:
		return _fail("sketch and model backgrounds differ")
	var env: WorldEnvironment = null
	for c in world.get_children():
		if c is WorldEnvironment:
			env = c
	if env == null:
		return _fail("world has no WorldEnvironment")
	if env.environment.background_mode != Environment.BG_COLOR:
		return _fail("3D background is not a flat colour")
	if env.environment.background_color != CadWorld.COLOR_BG:
		return _fail("3D clear colour is not the shared background")

	# --- camera view round-trips through capture/restore ------------------
	var rig: OrbitCamera = _root.rig
	rig.frame_view(Vector3(0.5, -0.7, 0.5), Vector3(0, 0, 1),
		Vector3(10, 20, 30), 640.0, false)
	var snap := rig.capture_view()
	rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3.ZERO, 200.0, false)
	rig.restore_view(snap, false)
	if absf(rig.yaw - float(snap["yaw"])) > 1e-6 \
			or absf(rig.pitch - float(snap["pitch"])) > 1e-6 \
			or rig.target.distance_to(snap["target"] as Vector3) > 1e-6 \
			or absf(rig.distance - float(snap["distance"])) > 1e-6:
		return _fail("restore_view did not return the captured view")

	# --- ground grid follows the active plane -----------------------------
	var grid := world.get_node("Grid") as MeshInstance3D
	if grid == null or grid.mesh == null:
		return _fail("no ground grid in the 3D world")
	if world.grid_plane() != "XY":
		return _fail("model-mode grid is on %s, want XY" % world.grid_plane())
	# Its lines must lie IN the plane it claims: for XY that means flat in Z.
	if not _grid_lies_on(grid, "XY"):
		return _fail("grid geometry is not on the XY plane")
	# Entering a sketch moves it onto that sketch's plane...
	var xz := _root.create_sketch("XZ")
	if world.grid_plane() != "XZ":
		return _fail("sketch-mode grid is on %s, want XZ" % world.grid_plane())
	if not _grid_lies_on(world.get_node("Grid") as MeshInstance3D, "XZ"):
		return _fail("grid geometry did not move to the XZ plane")
	# ...and finishing puts it back on the ground.
	_root.finish_sketch()
	if world.grid_plane() != "XY":
		return _fail("grid did not return to XY after finishing the sketch")
	if not _grid_lies_on(world.get_node("Grid") as MeshInstance3D, "XY"):
		return _fail("grid geometry did not return to XY")
	# Re-editing an existing sketch moves it again (not just fresh ones).
	_root.edit_sketch(xz)
	if world.grid_plane() != "XZ":
		return _fail("grid ignored edit_sketch on an existing sketch")
	_root.finish_sketch()

	# --- grid density adapts to camera distance ---------------------------
	rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3.ZERO, 200.0, false)
	world.update_grid(rig.distance)
	var near_step := world.grid_step()
	rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3.ZERO,
		20000.0, false)
	world.update_grid(rig.distance)
	if world.grid_step() <= near_step:
		return _fail("grid step %f did not coarsen when zoomed out from %f"
			% [world.grid_step(), near_step])
	# Both steps must sit on the shared 1/2/5 ladder the sketch canvas uses.
	for s: float in [near_step, world.grid_step()]:
		if not is_equal_approx(s, SketchView.step_for(UnitConverter.Unit.IN, s)):
			return _fail("grid step %f is off the 1/2/5 ladder" % s)

	# --- grid browser toggle ----------------------------------------------
	world.set_grid_shown(false)
	if (world.get_node("Grid") as MeshInstance3D).visible:
		return _fail("grid ignored its browser toggle")
	# A rebuild while hidden must not resurrect it.
	world.set_grid_plane("YZ")
	if (world.get_node("Grid") as MeshInstance3D).visible:
		return _fail("hidden grid reappeared after a plane change")
	world.set_grid_shown(true)
	world.set_grid_plane("XY")
	if not (world.get_node("Grid") as MeshInstance3D).visible:
		return _fail("grid did not come back when re-ticked")

	# --- view cube agrees with the camera FROM BOOT ------------------------
	# The rig emits `moved` from its own _ready, before the cube exists, so
	# without an explicit prime the cube sat facing front while the view was
	# at the 3/4 home angle until the user's first orbit.
	var cube_cam := _root.view_cube.get_node("VP/Node3D/Camera3D") as Camera3D \
		if _root.view_cube.has_node("VP/Node3D/Camera3D") else null
	if cube_cam == null:
		# Structure-independent fallback: find the only Camera3D in the widget.
		for n in _root.view_cube.find_children("*", "Camera3D", true, false):
			cube_cam = n as Camera3D
	if cube_cam == null:
		return _fail("view cube has no camera")
	var want := Basis.from_euler(_root.rig.rotation)
	if not cube_cam.transform.basis.is_equal_approx(want):
		return _fail("view cube did not adopt the rig's boot orientation")
	# ...and it keeps tracking after a move.
	_root.rig.frame_view(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3.ZERO,
		-1.0, false)
	if not cube_cam.transform.basis.is_equal_approx(
			Basis.from_euler(_root.rig.rotation)):
		return _fail("view cube stopped tracking the rig")

	# --- grid extent does not depend on the step ---------------------------
	# Tying the extent to the step made the grid's outline lurch as the zoom
	# ladder clicked over, and clipped the two line directions differently, so
	# cells read as rectangles. Both directions must span the same square.
	world.set_grid_plane("XY")
	for dist: float in [400.0, 4000.0, 40000.0]:
		world.update_grid(dist)
		var g := world.get_node("Grid") as MeshInstance3D
		var ext_u := 0.0
		var ext_v := 0.0
		for s in g.mesh.get_surface_count():
			for v in (g.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
					as PackedVector3Array):
				ext_u = maxf(ext_u, absf(v.x))
				ext_v = maxf(ext_v, absf(v.y))
		if absf(ext_u - ext_v) > 1e-6:
			return _fail("grid is not square at distance %f (%f x %f)"
				% [dist, ext_u, ext_v])

	# --- other sketches render as dim reference geometry -------------------
	# Editing a sketch used to hide every other sketch in the document, so you
	# could not place geometry in relation to what was already drawn.
	var f1 := _root.create_sketch("XY")
	var s1: Sketch = _root.doc.sketch_feature(f1).sketch
	var p0 := SketchPoint.make(Vector2(0, 0)); p0.id = s1.next_id()
	var p1 := SketchPoint.make(Vector2(40, 0)); p1.id = s1.next_id()
	var ln := SketchLine.make(p0.id, p1.id); ln.id = s1.next_id()
	for e: SketchEntity in [p0, p1, ln]:
		s1.add(e)
	_root.finish_sketch()
	var f2 := _root.create_sketch("XY")        # same plane -> f1 is reference
	var refs := _root.reference_sketches()
	if not refs.has(s1):
		return _fail("coplanar sketch not offered as reference")
	# The sketch being edited is never its own reference.
	if refs.has(_root.active_sketch()):
		return _fail("active sketch offered as its own reference")
	# A sketch on a DIFFERENT plane is not reference geometry — projecting it
	# onto this canvas would draw a meaningless smear.
	_root.finish_sketch()
	var f3 := _root.create_sketch("XZ")
	# Coplanar-only: the XY sketch built just above must NOT be reference
	# geometry for a sketch on XZ — projecting it onto this canvas would draw
	# a meaningless smear. (Other XZ sketches from earlier in this test
	# legitimately are references, so assert on s1 specifically.)
	if _root.reference_sketches().has(s1):
		return _fail("cross-plane sketch offered as reference")
	for r in _root.reference_sketches():
		var rf: SketchFeature = null
		for f in _root.doc.live_features():
			var sf := f as SketchFeature
			if sf != null and sf.sketch == r:
				rf = sf
		if rf == null or rf.plane != "XZ":
			return _fail("non-coplanar sketch offered as reference")
	# Reference geometry is display-only: it must not enter the snap index.
	_root.rebuild_snap_index()
	var ref_hit := _root.snap.snap_point(Vector2(40, 0), 2.0, 0.0)
	if String(ref_hit.get("kind", "")) == SnapEngine.KIND_POINT:
		return _fail("reference geometry leaked into the snap index")
	_root.finish_sketch()
	if f2 == "" or f3 == "":
		return _fail("reference-sketch setup did not create features")

	print("M02_QA_FIXES OK: cube world isolated + boot-synced, planes gated, "
		+ "bodies selectable/hideable, shared background, view round-trip, "
		+ "grid tracks the active plane, square grid extent, reference sketches")
	return true


## Does the grid lie in `plane_name`? The grid is a single quad oriented by its
## TRANSFORM (it used to be a line mesh whose vertices were baked onto the
## plane), so every corner is checked after transforming — which is the same
## question asked of the geometry that actually reaches the screen.
func _grid_lies_on(grid: MeshInstance3D, plane_name: String) -> bool:
	var n := SketchFeature.plane_basis(plane_name).z
	var mesh := grid.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	for s in mesh.get_surface_count():
		var verts := mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] \
			as PackedVector3Array
		if verts.is_empty():
			return false
		for v in verts:
			if absf((grid.transform * v).dot(n)) > 1e-6:
				return false
	return true
