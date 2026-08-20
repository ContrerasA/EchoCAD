class_name ViewCube
extends SubViewportContainer
## Fusion-style view cube: a small corner viewport with a cube whose
## orientation mirrors the main camera; clicking a face snaps the main
## camera to that view. Face detection is math (ray vs box), no physics.

signal face_picked(normal: Vector3, up: Vector3)

const SIZE_PX := 96
const CUBE_HALF := 25.0
const CAM_DIST := 120.0

var _cube: MeshInstance3D = null
var _cam: Camera3D = null

## Orientation to adopt in `_ready`. The rig emits `moved` from its own
## `_ready`, which runs before this widget exists, so the first sync would
## otherwise not arrive until the user orbited — leaving the cube facing front
## while the view sat at the 3/4 home angle. Owners set this before adding the
## node (or call `sync_orientation` right after) to start in agreement.
var rotation_hint := Vector3.ZERO


## Re-read the theme's body color (M36).
func apply_theme() -> void:
	if _cube != null and _cube.material_override is StandardMaterial3D:
		(_cube.material_override as StandardMaterial3D).albedo_color = 			ThemeService.col("body")


func _ready() -> void:
	custom_minimum_size = Vector2(SIZE_PX, SIZE_PX)
	stretch = true
	var vp := SubViewport.new()
	vp.name = "VP"
	vp.transparent_bg = true
	vp.size = Vector2i(SIZE_PX, SIZE_PX)
	# The cube lives in a world of its OWN. Sharing the main World3D would
	# cross-contaminate both ways: the cube would render as a stray box at the
	# model origin, and every body would show up inside the cube's corner.
	vp.own_world_3d = true
	add_child(vp)
	var root := Node3D.new()
	vp.add_child(root)
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE_HALF * 2.0
	_cube = MeshInstance3D.new()
	_cube.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	mat.albedo_color = ThemeService.col("body")
	_cube.material_override = mat
	root.add_child(_cube)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.8, 0.5, 0)
	root.add_child(light)
	_cam = Camera3D.new()
	_cam.position = Vector3(0, 0, CAM_DIST)
	_cam.near = 1.0
	_cam.far = 500.0
	root.add_child(_cam)
	# Seed a defined orientation. The owner overwrites this with the rig's real
	# rotation, but the cube must never sit in an unset pose waiting for the
	# first orbit — that is exactly the bug this guards against.
	sync_orientation(rotation_hint)


## Mirror the main rig's orientation: the cube camera orbits the cube exactly
## as the main camera orbits the model.
func sync_orientation(rig_rotation: Vector3) -> void:
	if _cam == null:
		return
	var b := Basis.from_euler(rig_rotation)
	_cam.transform = Transform3D(b, b * Vector3(0, 0, CAM_DIST))


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
