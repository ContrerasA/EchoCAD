class_name OrbitCamera
extends Node3D
## Orbit camera rig for model mode: this node holds yaw (Y) and pitch (X) in
## its rotation; the Camera3D child sits `distance` back along +Z. World
## units are mm. Fusion bindings: MMB pan, Shift+MMB orbit, wheel zoom.
##
## `frame_view(...)` animates to a named orientation (view cube / sketch
## entry); animation is skipped when the tree runs headless so tests see the
## final transform immediately.

signal moved

const PITCH_LIMIT := PI / 2.0 - 0.01
const ANIM_TIME := 0.25

var distance := 800.0:                # mm
	set(v):
		distance = clampf(v, 10.0, 100000.0)
		_apply()
var target := Vector3.ZERO:
	set(v):
		target = v
		_apply()

var camera: Camera3D = null
var _tween: Tween = null


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.far = 1000000.0
	camera.near = 1.0
	add_child(camera)
	# Home view: Fusion-like 3/4 view onto XY.
	rotation = Vector3(-PI / 5.0, PI / 6.0, 0)
	_apply()


func _apply() -> void:
	position = target
	if camera != null:
		camera.position = Vector3(0, 0, distance)
	moved.emit()


func orbit(dx: float, dy: float) -> void:
	rotation.y = wrapf(rotation.y - dx * 0.01, -PI, PI)
	rotation.x = clampf(rotation.x - dy * 0.01, -PITCH_LIMIT, PITCH_LIMIT)
	_apply()


func pan(dx: float, dy: float) -> void:
	var scale_mm := distance * 0.0015
	target += global_transform.basis * Vector3(-dx * scale_mm, dy * scale_mm, 0)


func zoom(factor: float) -> void:
	distance *= factor


## Animate so the camera looks along `-normal` with `up_hint` upward, framing
## `at_target` from `at_distance`. Instant when headless or `animate` false.
func frame_view(normal: Vector3, up_hint: Vector3, at_target := Vector3.ZERO,
		at_distance := -1.0, animate := true) -> void:
	var d := at_distance if at_distance > 0.0 else distance
	var look := Basis.looking_at(-normal, up_hint)
	var to_rot := look.get_euler()
	if _tween != null:
		_tween.kill()
		_tween = null
	if not animate or DisplayServer.get_name() == "headless":
		rotation = to_rot
		target = at_target
		distance = d
		return
	_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "rotation", to_rot, ANIM_TIME)
	_tween.tween_property(self, "target", at_target, ANIM_TIME)
	_tween.tween_property(self, "distance", d, ANIM_TIME)


## The camera ray through viewport pixel `screen` (origin + direction).
func pixel_ray(screen: Vector2) -> Array:
	return [camera.project_ray_origin(screen), camera.project_ray_normal(screen)]
