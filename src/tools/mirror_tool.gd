class_name MirrorTool
extends SketchTool
## Mirror (M): with entities selected (Select tool first), activate Mirror
## and click the AXIS line. Mirrored copies are created with SYMMETRY
## constraints tying each original/copy point pair about the axis — the
## mirror stays live under edits, like Fusion. One undo step.

const HIT_PX := 6.0

var _hover := false
var _preview := Vector2.ZERO
## "x"/"y" while the cursor hovers an ORIGIN axis (and no line is closer).
var _hover_axis := ""


func _init() -> void:
	id = "mirror"
	title = "Mirror"
	shortcut = KEY_M


func activate() -> void:
	_hover = false
	_hover_axis = ""
	clear_hover()


## Nearest LINE within tol — entity_at would prefer points, which cannot be a
## mirror axis, so the pick (and its pre-highlight) searches lines directly.
func _line_at(sk: Sketch, world: Vector2) -> String:
	var best := HIT_PX / view().zoom()
	var best_id := ""
	for e in sk.entities():
		if e.kind() != "line":
			continue
		var dd := SketchGeometry.distance_to_entity(sk, e, world)
		if dd <= best:
			best = dd
			best_id = e.id
	return best_id


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	var sk := sketch()
	hover_id = _line_at(sk, world)
	_hover_axis = ""
	if hover_id == "":
		var tol := HIT_PX / view().zoom()
		if absf(world.y) <= tol:
			_hover_axis = "x"
		elif absf(world.x) <= tol:
			_hover_axis = "y"
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	pointer_move(world, _screen, null)
	var sk := sketch()
	if app.selection.is_empty():
		app.set_status_hint("Mirror: select entities first, then the axis")
		return true
	var axis := sk.entity(hover_id) as SketchLine
	if axis != null:
		_apply(sk, axis)
		return true
	if _hover_axis != "":
		_apply_origin_axis(sk, _hover_axis)
		return true
	app.set_status_hint("Mirror: click an axis line (or the X/Y origin axis)")
	return true


## Mirror about a sketch ORIGIN axis. The SYMMETRY constraint needs a real
## line entity as its axis, so one is created as pinned CONSTRUCTION geometry
## from the origin point outward — same undo step as the mirror itself.
func _apply_origin_axis(sk: Sketch, which: String) -> void:
	var reach := 50.0
	for sel_id in app.selection:
		var e := sk.entity(sel_id)
		if e == null:
			continue
		var pids := e.point_refs()
		if e.kind() == "point":
			pids = [e.id]
		for pid in pids:
			var p := sk.point(pid)
			if p != null:
				reach = maxf(reach, p.pos.length() * 1.5)
	var far := SketchPoint.make(
		Vector2(reach, 0.0) if which == "x" else Vector2(0.0, reach))
	far.id = sk.next_id()
	var axis := SketchLine.make(sk.origin_id(), far.id)
	axis.id = sk.next_id()
	axis.construction = true
	var fix_ops: Array[String] = [far.id]
	var cons: Array = [SketchConstraint.make(SketchConstraint.Type.FIX, fix_ops)]
	var batch := CmdMergeBatch.new("Mirror", [])
	app.stack.push_no_merge(batch)
	app.stack.push(CmdAddEntities.new(app.active_sketch_id, [far, axis], cons))
	_apply(sk, axis, true)
	batch.seal()


func _apply(sk: Sketch, axis: SketchLine, in_batch := false) -> void:
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
			"spline":
				# M28: fit points already mirrored above; explicit handle
				# overrides reflect across the axis, auto tangents follow
				# their (mirrored) neighbours on their own.
				var sp := e as SketchSpline
				var nids: Array = []
				for spid in sp.points:
					nids.append(mirror_of[spid])
				var nsp := SketchSpline.make(nids, sp.closed)
				for hi in sp.handles.size():
					if sp.handles[hi] is Vector2:
						var t: Vector2 = sp.handles[hi]
						nsp.handles[hi] = d * t.dot(d) * 2.0 - t
					elif sp.handles[hi] is Dictionary:
						var o: Vector2 = sp.handles[hi]["out"]
						var inn: Vector2 = sp.handles[hi]["in"]
						nsp.handles[hi] = {
							"out": d * o.dot(d) * 2.0 - o,
							"in": d * inn.dot(d) * 2.0 - inn}
				nsp.id = sk.next_id()
				nsp.construction = sp.construction
				adds.append(nsp)
	if adds.is_empty():
		return
	var cmd := CmdAddEntities.new(app.active_sketch_id, adds, cons)
	if in_batch:
		app.stack.push(cmd)
	else:
		app.stack.push_no_merge(cmd)
	app.rebuild_snap_index()


func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	if _hover_axis != "":
		# Origin-axis pre-highlight: the axis a click would mirror about.
		var col := Color(1.0, 0.85, 0.3, 0.5)
		var half := 100000.0
		var a := Vector2(-half, 0.0) if _hover_axis == "x" else Vector2(0.0, -half)
		overlay.draw_line(v.world_to_screen(a), v.world_to_screen(-a), col, 3.0)
	overlay.draw_circle(v.world_to_screen(_preview), 2.0,
		ghost(0.6))
