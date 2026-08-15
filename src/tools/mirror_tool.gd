class_name MirrorTool
extends SketchTool
## Mirror (M): with entities selected (Select tool first), activate Mirror
## and click the AXIS line. Mirrored copies are created with SYMMETRY
## constraints tying each original/copy point pair about the axis — the
## mirror stays live under edits, like Fusion. One undo step.

const HIT_PX := 6.0

var _hover := false
var _preview := Vector2.ZERO


func _init() -> void:
	id = "mirror"
	title = "Mirror"
	shortcut = KEY_M


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	var axis_id := SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	var axis := sk.entity(axis_id) as SketchLine
	if axis == null:
		app._status_hint.text = "Mirror: click an axis line"
		return true
	if app.selection.is_empty():
		app._status_hint.text = "Mirror: select entities first, then the axis"
		return true
	_apply(sk, axis)
	return true


func _apply(sk: Sketch, axis: SketchLine) -> void:
	var a := sk.point(axis.p0).pos
	var b := sk.point(axis.p1).pos
	var d := (b - a).normalized()
	if d == Vector2.ZERO:
		return
	# Collect every source point (dedup) reachable from the selection.
	var src_points: Array[String] = []
	var src_entities: Array[String] = []
	for id in app.selection:
		var e := sk.entity(id)
		if e == null or id == axis.id:
			continue
		src_entities.append(id)
		if e.kind() == "point":
			if not src_points.has(id):
				src_points.append(id)
		for pid in e.point_refs():
			if not src_points.has(pid):
				src_points.append(pid)

	var mirror_of := {}
	var adds: Array = []
	var cons: Array = []
	for pid in src_points:
		var p := sk.point(pid)
		var v := p.pos - a
		var mirrored := a + d * v.dot(d) * 2.0 - v
		var np := SketchPoint.make(mirrored)
		np.id = sk.next_id()
		mirror_of[pid] = np.id
		adds.append(np)
		var ops: Array[String] = [pid, np.id, axis.id]
		cons.append(SketchConstraint.make(SketchConstraint.Type.SYMMETRY, ops))
	for id in src_entities:
		var e := sk.entity(id)
		match e.kind():
			"line":
				var l := e as SketchLine
				var nl := SketchLine.make(mirror_of[l.p0], mirror_of[l.p1])
				nl.id = sk.next_id()
				nl.construction = l.construction
				adds.append(nl)
			"circle":
				var ci := e as SketchCircle
				var nc := SketchCircle.make(mirror_of[ci.center], ci.radius)
				nc.id = sk.next_id()
				nc.construction = ci.construction
				adds.append(nc)
				var eops: Array[String] = [ci.id, nc.id]
				cons.append(SketchConstraint.make(SketchConstraint.Type.EQUAL, eops))
			"arc":
				var arc := e as SketchArc
				# Mirroring reverses winding.
				var na := SketchArc.make(mirror_of[arc.center],
					mirror_of[arc.start], mirror_of[arc.end], not arc.ccw)
				na.id = sk.next_id()
				na.construction = arc.construction
				adds.append(na)
	if adds.is_empty():
		return
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id, adds, cons))
	app.rebuild_snap_index()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	overlay.draw_circle(view().world_to_screen(_preview), 2.0,
		Color(1, 1, 1, 0.6))
