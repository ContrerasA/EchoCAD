class_name ViewCube
extends SubViewportContainer
## Fusion-style view cube: a corner viewport with a labelled cube (FRONT /
## TOP / RIGHT â€¦) whose orientation mirrors the main camera, plus an X/Y/Z
## axis triad under it; clicking a face snaps the main camera to that view.
## Face detection is math (ray vs box), no physics.

signal face_picked(normal: Vector3, up: Vector3)

const SIZE_PX := 150
const CUBE_HALF := 20.0
const CAM_DIST := 118.0
const AXIS_LEN := 14.0
## Camera-space offsets: the cube sits up-right of centre, the triad pinned
## to the bottom-left corner of the widget (Fusion's layout) so neither ever
## clips at the viewport edge whichever way the view turns.
const CUBE_SHIFT := Vector3(-7.0, -8.0, 0.0)
const TRIAD_AT := Vector3(-29.0, -31.0, 0.0)

## Face normal -> [label, on-screen up]. World is Z-up; the home view looks
## from -Y, so -Y is FRONT and +X is RIGHT (matches Fusion's default cube).
const FACES := {
	Vector3(0, -1, 0): ["FRONT", Vector3(0, 0, 1)],
	Vector3(0, 1, 0): ["BACK", Vector3(0, 0, 1)],
	Vector3(1, 0, 0): ["RIGHT", Vector3(0, 0, 1)],
	Vector3(-1, 0, 0): ["LEFT", Vector3(0, 0, 1)],
	Vector3(0, 0, 1): ["TOP", Vector3(0, 1, 0)],
	Vector3(0, 0, -1): ["BOTTOM", Vector3(0, -1, 0)],
}

var _cube: MeshInstance3D = null
var _cam: Camera3D = null
var _labels: Array = []        # Label3D per face
var _axes: Array = []          # [{mesh: MeshInstance3D, label: Label3D, role}]
var _edges: MeshInstance3D = null
var _triad: Node3D = null

## Orientation to adopt in `_ready`. The rig emits `moved` from its own
## `_ready`, which runs before this widget exists, so the first sync would
## otherwise not arrive until the user orbited â€” leaving the cube facing front
## while the view sat at the 3/4 home angle. Owners set this before adding the
## node (or call `sync_orientation` right after) to start in agreement.
var rotation_hint := Vector3.ZERO


## Re-read the theme's body / edge / axis colors (M36).
func apply_theme() -> void:
	if _cube != null and _cube.material_override is StandardMaterial3D:
		(_cube.material_override as StandardMaterial3D).albedo_color = \
			ThemeService.col("body")
	for l in _labels:
		(l as Label3D).modulate = ThemeService.col("view_cube_text")
		(l as Label3D).font = ThemeService.font(ThemeService.font_weight("weight_bold"))
	if _edges != null and _edges.material_override is StandardMaterial3D:
		(_edges.material_override as StandardMaterial3D).albedo_color = \
			ThemeService.col("view_cube_text")
	for a: Dictionary in _axes:
		var c := ThemeService.col(String(a["role"]))
		((a["mesh"] as MeshInstance3D).material_override as StandardMaterial3D) \
			.albedo_color = c
		(a["label"] as Label3D).modulate = c


func _ready() -> void:
	custom_minimum_size = Vector2(SIZE_PX, SIZE_PX)
	stretch = true
	var vp := SubViewport.new()
	vp.name = "VP"
	vp.transparent_bg = true
	vp.size = Vector2i(SIZE_PX, SIZE_PX)
	vp.msaa_3d = Viewport.MSAA_4X
	# The cube lives in a world of its OWN. Sharing the main World3D would
	# cross-contaminate both ways: the cube would render as a stray box at the
	# model origin, and every body would show up inside the cube's corner.
	vp.own_world_3d = true
	# Flat ambient fill so the faces turned from the key light still read
	# (and their labels with them) instead of going near-black.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.55
	var w3 := World3D.new()
	w3.environment = env
	vp.world_3d = w3
	add_child(vp)
	var root := Node3D.new()
	vp.add_child(root)
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE_HALF * 2.0
	_cube = MeshInstance3D.new()
	_cube.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	mat.albedo_color = ThemeService.col("view_cube")
	_cube.material_override = mat
	root.add_child(_cube)
	_build_edges(root)
	_build_labels(root)
	_build_axes(root)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.8, 0.5, 0)
	root.add_child(light)
	_cam = Camera3D.new()
	_cam.position = Vector3(0, 0, CAM_DIST)
	_cam.near = 1.0
	_cam.far = 500.0
	_cam.fov = 42.0
	root.add_child(_cam)
	# Seed a defined orientation. The owner overwrites this with the rig's real
	# rotation, but the cube must never sit in an unset pose waiting for the
	# first orbit â€” that is exactly the bug this guards against.
	sync_orientation(rotation_hint)


## Hairline cube edges so the faces read as a box even where two lit faces
## share a tone.
func _build_edges(root: Node3D) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var h := CUBE_HALF
	var xs: Array[float] = [-h, h, h, -h]
	var ys: Array[float] = [-h, -h, h, h]
	for z: float in [-h, h]:
		for i in 4:
			im.surface_add_vertex(Vector3(xs[i], ys[i], z))
			im.surface_add_vertex(Vector3(xs[(i + 1) % 4], ys[(i + 1) % 4], z))
	for i in 4:
		im.surface_add_vertex(Vector3(xs[i], ys[i], -h))
		im.surface_add_vertex(Vector3(xs[i], ys[i], h))
	im.surface_end()
	_edges = MeshInstance3D.new()
	_edges.mesh = im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = ThemeService.col("view_cube_text")
	_edges.material_override = m
	root.add_child(_edges)


func _build_labels(root: Node3D) -> void:
	for n: Vector3 in FACES:
		var up: Vector3 = FACES[n][1]
		var l := Label3D.new()
		l.text = String(FACES[n][0])
		l.font = ThemeService.font(ThemeService.font_weight("weight_bold"))
		l.font_size = 64
		l.pixel_size = 0.14
		l.modulate = ThemeService.col("view_cube_text")
		l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
		l.double_sided = false
		l.shaded = false
		# Text faces +Z of its own basis: z = outward normal, y = on-screen up.
		var x := up.cross(n)
		l.transform = Transform3D(Basis(x, up, n), n * (CUBE_HALF + 0.3))
		root.add_child(l)
		_labels.append(l)


## X/Y/Z triad in the viewport axis colors. Lives under `_triad`, which
## sync_orientation pins to the widget's bottom-left corner (world-aligned,
## so it turns with the view like the cube does).
func _build_axes(root: Node3D) -> void:
	_triad = Node3D.new()
	_triad.name = "Triad"
	root.add_child(_triad)
	var defs := [[Vector3.RIGHT, "X", "axis_x"], [Vector3(0, 1, 0), "Y", "axis_y"],
		[Vector3(0, 0, 1), "Z", "axis_z"]]
	for d in defs:
		var dir: Vector3 = d[0]
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(dir * AXIS_LEN)
		im.surface_end()
		var mi := MeshInstance3D.new()
		mi.mesh = im
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.no_depth_test = true
		m.albedo_color = ThemeService.col(String(d[2]))
		mi.material_override = m
		_triad.add_child(mi)
		var l := Label3D.new()
		l.text = String(d[1])
		l.font = ThemeService.font(ThemeService.font_weight("weight_bold"))
		l.font_size = 64
		l.pixel_size = 0.13
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.shaded = false
		l.modulate = ThemeService.col(String(d[2]))
		l.position = dir * (AXIS_LEN + 4.0)
		_triad.add_child(l)
		_axes.append({"mesh": mi, "label": l, "role": d[2]})


## Mirror the main rig's orientation: the cube camera orbits the cube exactly
## as the main camera orbits the model.
func sync_orientation(rig_rotation: Vector3) -> void:
	if _cam == null:
		return
	var b := Basis.from_euler(rig_rotation)
	_cam.transform = Transform3D(b, b * (Vector3(0, 0, CAM_DIST) + CUBE_SHIFT))
	if _triad != null:
		_triad.position = _cam.transform * (TRIAD_AT + Vector3(0, 0, -CAM_DIST))


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var n := _pick_face(mb.position)
	if n == Vector3.ZERO:
		return
	accept_event()
	# World is Z-up: +Z is the top face, so a side face's up is +Z and the
	# top/bottom faces fall back to +Y / -Y as their on-screen north.
	var up := Vector3(0, 0, 1)
	if absf(n.z) > 0.9:
		up = Vector3(0, 1, 0) * signf(n.z)
	face_picked.emit(n, up)


## Window-pixel position of a face's center, plus whether that face currently
## faces the camera enough to click. Lets automation aim REAL clicks at the
## cube instead of teleporting the camera behind the UI's back.
func face_screen_px(normal: Vector3) -> Dictionary:
	if _cam == null:
		return {"ok": false, "x": 0.0, "y": 0.0}
	var n := normal.normalized()
	var world_pt: Vector3 = n * CUBE_HALF
	var to_cam := (_cam.global_transform.origin - world_pt).normalized()
	# Grazing faces are sliver-thin on screen; require a real facing angle.
	var clickable := n.dot(to_cam) > 0.35
	var vp := get_child(0) as SubViewport
	var px := _cam.unproject_position(world_pt)
	var g := get_global_rect().position + px * (size / Vector2(vp.size))
	return {"ok": clickable, "x": g.x, "y": g.y}


## Ray vs axis-aligned cube; returns the hit face's outward normal or ZERO.
func _pick_face(pos: Vector2) -> Vector3:
	# Container pixels -> viewport pixels (stretch may scale).
	var vp := get_child(0) as SubViewport
	var scale_v := Vector2(vp.size) / size
	var origin := _cam.project_ray_origin(pos * scale_v)
	var dir := _cam.project_ray_normal(pos * scale_v)
	var t_enter := -INF
	var t_exit := INF
	var enter_axis := -1
	for axis in 3:
		var o := origin[axis]
		var d := dir[axis]
		if absf(d) < 1e-9:
			if absf(o) > CUBE_HALF:
				return Vector3.ZERO
			continue
		var t1 := (-CUBE_HALF - o) / d
		var t2 := (CUBE_HALF - o) / d
		var lo := minf(t1, t2)
		var hi := maxf(t1, t2)
		if lo > t_enter:
			t_enter = lo
			enter_axis = axis
		t_exit = minf(t_exit, hi)
	if t_enter > t_exit or t_exit < 0.0 or enter_axis < 0:
		return Vector3.ZERO
	var hit := origin + dir * t_enter
	var n := Vector3.ZERO
	n[enter_axis] = signf(hit[enter_axis])
	return n
