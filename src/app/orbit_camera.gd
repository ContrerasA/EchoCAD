class_name OrbitCamera
extends Node3D
## Orbit camera rig for model mode. The world is Z-UP (Blender/Fusion
## convention): +Z is up, XY is the ground plane.
##
## Orientation is stored as `yaw`/`pitch` about the WORLD +Z axis: yaw spins
## around +Z (0 = looking from -Y toward +Y, the front view), pitch tilts up
## toward +Z. `Z_UP_FIX` maps that Z-up frame onto the Camera3D's Y-up
## convention, so the Camera3D child still sits `distance` back along its
## local +Z and looks down its local -Z.
##
## World units are mm. Fusion bindings: MMB pan, Shift+MMB orbit, wheel zoom.
## Orbit pivots around the model by default, falling back to the world origin
## on an empty document — see `PivotMode` and `resolve_pivot`.

signal moved

const PITCH_LIMIT := PI / 2.0 - 0.01
const ANIM_TIME := 0.25

## Rotates the Z-up world frame into the camera's Y-up frame: world +Z becomes
## camera up, world +Y becomes camera forward.
const Z_UP_FIX := Vector3(PI / 2.0, 0.0, 0.0)

## Where orbit rotates about.
enum PivotMode {
	BODY_CENTER,   ## Fusion default: center of the visible model's bounds.
	ORBIT_POINT,   ## Blender-ish: the point under the cursor when orbit began.
	VIEW_CENTER,   ## Plain: whatever the camera is currently centered on.
}

## Yaw about world +Z, radians. 0 looks from -Y toward +Y (front view).
var yaw := 0.0
## Pitch above the ground plane, radians. +PI/2 looks straight down.
var pitch := 0.0

var pivot_mode: PivotMode = PivotMode.BODY_CENTER

## Supplies model bounds for BODY_CENTER; set by the owner. Returns an AABB —
## a zero-size AABB means "no bodies", which falls back to the world origin.
var bounds_provider: Callable = Callable()
## Supplies the world point under the cursor for ORBIT_POINT; set by the owner.
## Takes a screen Vector2, returns {"ok": bool, "pos": Vector3}.
var orbit_point_provider: Callable = Callable()

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

## Orbit gesture state, captured on press and held until release — so the
## gesture survives Shift being let go mid-drag and cannot switch pivot
## partway through.
var _orbiting := false
var _orbit_pivot := Vector3.ZERO
## Camera offset from the pivot at gesture start, in camera-local terms.
## Rotating it by the new yaw/pitch swings the camera around the pivot.
var _orbit_arm := Vector3.ZERO


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.far = 1000000.0
	camera.near = 1.0
	add_child(camera)
	# Home view: Fusion-like 3/4 view onto the XY ground plane, from above.
	yaw = -PI / 6.0
	pitch = PI / 5.0
	_apply()


## Rig rotation (Godot Euler) for the current yaw/pitch.
func _rig_rotation() -> Vector3:
	return basis_for(yaw, pitch).get_euler()


## The rig basis for a yaw/pitch pair: yaw about world +Z, then the Z-up ->
## Y-up fix, then pitch about the camera's local X.
static func basis_for(y: float, p: float) -> Basis:
	return Basis.from_euler(Vector3(0, 0, y)) \
		* Basis.from_euler(Z_UP_FIX) \
		* Basis.from_euler(Vector3(-p, 0, 0))


## World-space camera position for the current orientation.
func _eye() -> Vector3:
	return target + basis_for(yaw, pitch) * Vector3(0, 0, distance)


func _apply() -> void:
	rotation = _rig_rotation()
	position = target
	if camera != null:
		camera.position = Vector3(0, 0, distance)
	moved.emit()


## Begin an orbit gesture. `screen` is the cursor position, used only by
## ORBIT_POINT. Repeat calls during one drag are ignored.
##
## Resolves the pivot once, here, so the gesture cannot change pivot mid-drag,
## and captures the camera's offset from it. The orientation is deliberately
## left untouched: re-aiming at the pivot would snap it to the middle of the
## window, when the point is to leave it exactly where the user put it.
func begin_orbit(screen := Vector2.ZERO) -> void:
	if _orbiting:
		return
	_orbiting = true
	_orbit_pivot = resolve_pivot(screen)
	_orbit_arm = basis_for(yaw, pitch).inverse() * (_eye() - _orbit_pivot)


## End the current orbit gesture (drag finished).
func end_orbit() -> void:
	_orbiting = false


func is_orbiting() -> bool:
	return _orbiting


## The world point orbit rotates about, per the active pivot mode.
##
## BODY_CENTER and ORBIT_POINT both fall back to the WORLD ORIGIN, not the
## view center: an empty document is the normal state on open, and the origin
## is where the axes and origin planes sit. Falling back to the view center
## there would orbit about the middle of the window, spinning the guides
## around the screen instead of the camera around them.
func resolve_pivot(screen := Vector2.ZERO) -> Vector3:
	match pivot_mode:
		PivotMode.BODY_CENTER:
			if bounds_provider.is_valid():
				var aabb: AABB = bounds_provider.call()
				if aabb.size.length_squared() > 1e-12:
					return aabb.get_center()
			return Vector3.ZERO
		PivotMode.ORBIT_POINT:
			if orbit_point_provider.is_valid():
				var r: Dictionary = orbit_point_provider.call(screen)
				if bool(r.get("ok", false)):
					return r["pos"] as Vector3
			# Nothing under the cursor — orbit the origin, as Blender does
			# when its ray misses all geometry.
			return Vector3.ZERO
	return target


## Orbit by a mouse delta in pixels. The eye swings around the pivot on a
## fixed arm while the view direction rotates with it, so the pivot keeps both
## its world position AND its position on screen — the camera moves around the
## model rather than the model spinning about the middle of the window.
func orbit(dx: float, dy: float) -> void:
	if not _orbiting:
		begin_orbit()
	yaw = wrapf(yaw - dx * 0.01, -PI, PI)
	pitch = clampf(pitch + dy * 0.01, -PITCH_LIMIT, PITCH_LIMIT)
	var b := basis_for(yaw, pitch)
	# Eye rides the rotated arm; target trails it by `distance` along the new
	# view direction, which preserves the pivot's screen offset from centre.
	target = (_orbit_pivot + b * _orbit_arm) - b * Vector3(0, 0, distance)


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
	var yp := yaw_pitch_for(normal, up_hint)
	_animate_to(yp.x, yp.y, at_target, d, animate)


func _animate_to(to_yaw: float, to_pitch: float, at_target: Vector3,
		d: float, animate: bool) -> void:
	if _tween != null:
		_tween.kill()
		_tween = null
	if not animate or DisplayServer.get_name() == "headless":
		yaw = wrapf(to_yaw, -PI, PI)
		pitch = to_pitch
		target = at_target
		distance = d
		return
	# Sweep the short way around the yaw circle: aim at whichever branch of
	# `to_yaw` is nearest the current angle, which is never more than PI off.
	# The tween runs through unwrapped angles, so re-wrap once it lands.
	var goal_yaw := yaw + wrapf(to_yaw - yaw, -PI, PI)
	_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_yaw_pitch, Vector2(yaw, pitch),
		Vector2(goal_yaw, to_pitch), ANIM_TIME)
	_tween.tween_property(self, "target", at_target, ANIM_TIME)
	_tween.tween_property(self, "distance", d, ANIM_TIME)
	_tween.chain().tween_callback(func() -> void: yaw = wrapf(yaw, -PI, PI))


func _set_yaw_pitch(v: Vector2) -> void:
	yaw = v.x
	pitch = v.y
	_apply()


## Yaw/pitch that make the camera look along `-normal` — i.e. face a plane
## whose outward normal is `normal`. For the top/bottom views the yaw is
## ambiguous, so `up_hint` picks which way north points.
static func yaw_pitch_for(normal: Vector3, up_hint := Vector3(0, 0, 1)) -> Vector2:
	# Camera forward is (-sin y * cos p, cos y * cos p, -sin p) and must
	# equal -n, which gives p = asin(n.z) and y = atan2(n.x, -n.y).
	var n := normal.normalized()
	var p := asin(clampf(n.z, -1.0, 1.0))
	if absf(n.z) > 0.999999:
		# Looking straight down/up: yaw is degenerate, so the up hint's
		# ground heading picks which way is "up" on screen. At yaw 0 the
		# screen-up heading is +Y, so y = atan2(-h.x, h.y).
		var h := Vector2(up_hint.x, up_hint.y)
		if h.length_squared() < 1e-12:
			return Vector2(0.0, p)
		return Vector2(wrapf(atan2(-h.x, h.y), -PI, PI), p)
	return Vector2(wrapf(atan2(n.x, -n.y), -PI, PI), p)


## The camera ray through viewport pixel `screen` (origin + direction).
func pixel_ray(screen: Vector2) -> Array:
	return [camera.project_ray_origin(screen), camera.project_ray_normal(screen)]
