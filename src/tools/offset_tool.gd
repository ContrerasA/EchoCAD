class_name OffsetTool
extends SketchTool
## Offset (O): click an entity, then the cursor's side/distance previews the
## offset copy — line -> parallel line, circle/arc -> concentric with
## r +/- d. Typed distance + Enter for exactness. One undo step, no
## constraints (Fusion adds an offset constraint; deferred).

var _target := ""
var _hover := false
var _preview := Vector2.ZERO
var _fields := DimFields.new(["D"])


func _init() -> void:
	id = "offset"
	title = "Offset"
	shortcut = KEY_O


func activate() -> void:
	_reset()
	app.rebuild_snap_index()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_target = ""
	_hover = false
	_fields.reset()


func cancel() -> bool:
	if _target != "" or _hover:
		_reset()
		return true
	return false


func commit() -> bool:
	if _target == "":
		return false
	_apply()
	return true


func key_input(e: InputEventKey) -> bool:
	if _target == "":
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return commit()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	if _target == "":
		var hit := SketchGeometry.entity_at(sk, world, 6.0 / view().zoom())
		if hit != "" and sk.entity(hit).kind() != "point":
			_target = hit
		return true
	_preview = world
	_apply()
	return true


## Signed offset for the current cursor (positive toward cursor side).
func _resolve(sk: Sketch) -> Dictionary:
	var e := sk.entity(_target)
	var typed := _fields.value_mm(0, app.doc.display_unit)
	match e.kind():
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0).pos
			var b := sk.point(l.p1).pos
			var n := (b - a).normalized().orthogonal()
			var side := signf(n.dot(_preview - a))
			if side == 0.0:
				side = 1.0
			var d := absf(typed) if not is_nan(typed) \
				else absf(n.dot(_preview - a))
			return {"kind": "line", "a": a + n * side * d, "b": b + n * side * d}
		"circle", "arc":
			var c: Vector2
			var r: float
			if e is SketchCircle:
				c = sk.point((e as SketchCircle).center).pos
				r = (e as SketchCircle).radius
			else:
				var arc := e as SketchArc
				c = sk.point(arc.center).pos
				r = c.distance_to(sk.point(arc.start).pos)
			var cursor_r := c.distance_to(_preview)
			var d := absf(typed) if not is_nan(typed) else absf(cursor_r - r)
			var new_r := r + d if cursor_r > r else maxf(r - d, 0.01)
			return {"kind": e.kind(), "c": c, "r": new_r}
	return {}


func _apply() -> void:
	var sk := sketch()
	var spec := _resolve(sk)
	if spec.is_empty():
		_reset()
		return
	var adds: Array = []
	match String(spec["kind"]):
		"line":
			var pa := SketchPoint.make(spec["a"])
			var pb := SketchPoint.make(spec["b"])
			pa.id = sk.next_id()
			pb.id = sk.next_id()
			var nl := SketchLine.make(pa.id, pb.id)
			nl.id = sk.next_id()
			adds = [pa, pb, nl]
		"circle":
			var cp := SketchPoint.make(spec["c"])
			cp.id = sk.next_id()
			var nc := SketchCircle.make(cp.id, spec["r"])
			nc.id = sk.next_id()
			adds = [cp, nc]
		"arc":
			var src := sk.entity(_target) as SketchArc
			var c: Vector2 = spec["c"]
			var r: float = spec["r"]
			var s_ang := (sk.point(src.start).pos - c).angle()
			var e_ang := (sk.point(src.end).pos - c).angle()
			var cp2 := SketchPoint.make(c)
			var sp := SketchPoint.make(c + Vector2(cos(s_ang), sin(s_ang)) * r)
			var ep := SketchPoint.make(c + Vector2(cos(e_ang), sin(e_ang)) * r)
			for p: SketchPoint in [cp2, sp, ep]:
				p.id = sk.next_id()
			var na := SketchArc.make(cp2.id, sp.id, ep.id, src.ccw)
			na.id = sk.next_id()
			adds = [cp2, sp, ep, na]
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id, adds))
	app.rebuild_snap_index()
	_reset()


func draw_overlay(overlay: Control) -> void:
	if not _hover or _target == "":
		return
	var sk := sketch()
	var v := view()
	var spec := _resolve(sk)
	if spec.is_empty():
		return
	var col := Color(1, 1, 1, 0.8)
	match String(spec["kind"]):
		"line":
			overlay.draw_line(v.world_to_screen(spec["a"]),
				v.world_to_screen(spec["b"]), col, 1.0)
		"circle":
			overlay.draw_arc(v.world_to_screen(spec["c"]),
				float(spec["r"]) * v.zoom(), 0, TAU, 64, col, 1.0)
		"arc":
			overlay.draw_arc(v.world_to_screen(spec["c"]),
				float(spec["r"]) * v.zoom(), 0, TAU, 64, col, 1.0)
	_fields.draw(overlay, v.world_to_screen(_preview),
		app.doc.display_unit, [0.0])
