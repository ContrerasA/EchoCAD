extends SceneTree

# Manual-QA fixes for M9-M12: trim/extend joints + debris, chain offset,
# origin-axis mirror, fillet radius drive, extrude shading mesh, save/open.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m10_qa_fixes: " + msg)
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


func _type(text: String) -> void:
	var tool := _root.tools.get_tool(_root.tools.active_id())
	for ch in text:
		var e := InputEventKey.new()
		e.unicode = ch.unicode_at(0)
		tool.key_input(e)


func _enter() -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_ENTER
	_root.tools.get_tool(_root.tools.active_id()).key_input(e)


## Document JSON with never-rolled-back id counters neutralized.
func _snap() -> String:
	var d: Dictionary = _root.doc.to_dict()
	d["feature_counter"] = 0
	for f: Dictionary in d["features"]:
		if f.has("sketch"):
			(f["sketch"] as Dictionary)["id_counter"] = 0
	return JSON.stringify(d)


func _line(sk: Sketch, a: Vector2, b: Vector2) -> SketchLine:
	var pa := SketchPoint.make(a)
	var pb := SketchPoint.make(b)
	pa.id = sk.next_id()
	pb.id = sk.next_id()
	var l := SketchLine.make(pa.id, pb.id)
	l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pa, pb, l]))
	return l


func _has_point_on(sk: Sketch, pid: String, target: String) -> bool:
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.POINT_ON \
				and c.operands[0] == pid and c.operands[1] == target:
			return true
	return false


func _point_near(sk: Sketch, at: Vector2, tol := 0.01) -> SketchPoint:
	for e in sk.entities():
		if e.kind() == "point" and (e as SketchPoint).pos.distance_to(at) <= tol:
			return e
	return null


## Standalone-doc rectangle extrude, for the winding sweep.
func _rect_mesh(plane: String, cw: bool, dist: float) -> ArrayMesh:
	var doc := CadDocument.new()
	var sf := SketchFeature.make("S", plane)
	sf.id = "f1"
	doc.features.append(sf)
	doc.timeline_marker = 1
	var s := sf.sketch
	var order: Array = [Vector2(0, 0), Vector2(30, 0), Vector2(30, 20), Vector2(0, 20)]
	if cw:
		order.reverse()
	var sps: Array = []
	for p: Vector2 in order:
		var sp := SketchPoint.make(p)
		sp.id = s.next_id()
		s.add(sp)
		sps.append(sp)
	for i in 4:
		var l := SketchLine.make((sps[i] as SketchPoint).id,
			(sps[(i + 1) % 4] as SketchPoint).id)
		l.id = s.next_id()
		s.add(l)
	return ExtrudeFeature.make("f1", Vector2(15, 10), dist).build_mesh(doc)


func _signed_volume(mesh: ArrayMesh) -> float:
	var v := 0.0
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for t in range(0, verts.size(), 3):
			v += verts[t].cross(verts[t + 1]).dot(verts[t + 2]) / 6.0
	return v


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false

	# --- TRIM: no debris point at the removed end, and the new endpoint is
	# POINT_ON the cutter so the joint survives edits.
	var h := _line(sk, Vector2(-40, 0), Vector2(40, 0))
	var v := _line(sk, Vector2(0, -40), Vector2(0, 40))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	_click(Vector2(20, 0.5))       # remove the right half of h
	if _point_near(sk, Vector2(40, 0)) != null:
		return _fail("trim left a debris point at the removed end")
	# The kept segment's cut-side endpoint (the sketch origin also sits at
	# (0,0), so find it through the remaining horizontal line).
	var joint: SketchPoint = null
	for e in sk.entities():
		if e is SketchLine and (e as SketchLine).p0 == h.p0:
			joint = sk.point((e as SketchLine).p1)
	if joint == null or joint.pos.distance_to(Vector2.ZERO) > 0.01:
		return _fail("trim did not keep an endpoint at the cut")
	if not _has_point_on(sk, joint.id, v.id):
		return _fail("trimmed endpoint not constrained onto the cutter")
	# Drag the cutter sideways: the trimmed end must follow it.
	var batch := CmdMergeBatch.new("Drag", [])
	_root.stack.push_no_merge(batch)
	_root.stack.push(CmdMovePoints.new(_root.active_sketch_id,
		{v.p0: Vector2(5, -40), v.p1: Vector2(5, 40)}))
	_root.solve_followers([v.p0, v.p1])
	batch.seal()
	if absf(sk.point(joint.id).pos.x - 5.0) > 0.05:
		return _fail("trimmed endpoint did not follow the cutter: %s"
			% sk.point(joint.id).pos)

	# --- EXTEND: the moved tip is POINT_ON the entity it hit.
	var target := _line(sk, Vector2(60, -30), Vector2(60, 30))
	var short := _line(sk, Vector2(30, 10), Vector2(45, 10))
	_root.rebuild_snap_index()
	_root.tools.set_active("extend")
	_click(Vector2(44, 10.5))
	if absf(sk.point(short.p1).pos.x - 60.0) > 0.001:
		return _fail("extend missed: %s" % sk.point(short.p1).pos)
	if not _has_point_on(sk, short.p1, target.id):
		return _fail("extended tip not constrained onto the target")
	# Extending again at the same junction must NOT add a second POINT_ON —
	# that over-constrains it (badges flickering red/green under drags).
	_click(Vector2(59, 10.5))
	var ties := 0
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.POINT_ON \
				and c.operands[0] == short.p1 and c.operands[1] == target.id:
			ties += 1
	if ties != 1:
		return _fail("extend duplicated the junction constraint: %d ties" % ties)

	# --- TRIM at a T-joint: the toucher's endpoint sits a solver-tolerance
	# hair off the line, which a strict segment intersection misses — trim
	# must still see the junction as a cut, not delete the whole line.
	var tm := _line(sk, Vector2(200, 0), Vector2(240, 0))
	var tt := _line(sk, Vector2(220, 0.0003), Vector2(220, 40))
	_root.rebuild_snap_index()
	_root.tools.set_active("trim")
	_click(Vector2(230, 0.4))      # right of the T
	if not sk.has(tt.id):
		return _fail("T-joint trim deleted the toucher")
	if sk.has(tm.id):
		return _fail("T-joint trim did not cut at the touch point")
	var kept_left := false
	for e in sk.entities():
		if e is SketchLine and (e as SketchLine).p0 == tm.p0:
			kept_left = true
			if not _has_point_on(sk, (e as SketchLine).p1, tt.id):
				return _fail("T-joint trim did not tie the cut onto the toucher")
	if not kept_left:
		return _fail("T-joint trim removed the whole line instead of the span")

	# --- OFFSET a selected rectangle as a CHAIN: corners re-intersected.
	var q1 := SketchPoint.make(Vector2(-100, 40))
	var q2 := SketchPoint.make(Vector2(-70, 40))
	var q3 := SketchPoint.make(Vector2(-70, 60))
	var q4 := SketchPoint.make(Vector2(-100, 60))
	for p: SketchPoint in [q1, q2, q3, q4]:
		p.id = sk.next_id()
	var r1 := SketchLine.make(q1.id, q2.id)
	var r2 := SketchLine.make(q2.id, q3.id)
	var r3 := SketchLine.make(q3.id, q4.id)
	var r4 := SketchLine.make(q4.id, q1.id)
	for l: SketchLine in [r1, r2, r3, r4]:
		l.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[q1, q2, q3, q4, r1, r2, r3, r4]))
	_root.rebuild_snap_index()
	var pts_before := 0
	for e in sk.entities():
		if e.kind() == "point":
			pts_before += 1
	_root.set_selection([r1.id, r2.id, r3.id, r4.id])
	_root.tools.set_active("offset")
	_root.tools.handle_pointer_move(Vector2(-85, 50),
		_root.sketch_view.world_to_screen(Vector2(-85, 50)),
		InputEventMouseMotion.new())
	_type("0.1")                   # 2.54 mm, cursor inside -> inset
	_enter()
	for corner: Vector2 in [Vector2(-97.46, 42.54), Vector2(-72.54, 42.54),
			Vector2(-72.54, 57.46), Vector2(-97.46, 57.46)]:
		if _point_near(sk, corner) == null:
			return _fail("chain offset corner missing at %s" % corner)
	var pts_after := 0
	for e in sk.entities():
		if e.kind() == "point":
			pts_after += 1
	if pts_after != pts_before + 4:
		return _fail("chain offset should add exactly 4 shared corner points, "
			+ "added %d" % (pts_after - pts_before))

	# --- MIRROR about the ORIGIN X axis: pinned construction axis + live
	# symmetry, all one undo step.
	var src := _line(sk, Vector2(10, 8), Vector2(20, 8))
	_root.rebuild_snap_index()
	var json_before := _snap()
	_root.set_selection([src.id])
	_root.tools.set_active("mirror")
	_click(Vector2(15, 0.2))       # on the X axis, away from any line
	if _point_near(sk, Vector2(10, -8)) == null \
			or _point_near(sk, Vector2(20, -8)) == null:
		return _fail("origin-axis mirror did not place the mirrored line")
	var axis_line: SketchLine = null
	for e in sk.entities():
		if e is SketchLine and (e as SketchLine).construction \
				and ((e as SketchLine).p0 == sk.origin_id()
					or (e as SketchLine).p1 == sk.origin_id()):
			axis_line = e
	if axis_line == null:
		return _fail("origin-axis mirror created no construction axis")
	var syms := 0
	for c in sk.constraints:
		if c.type == SketchConstraint.Type.SYMMETRY:
			syms += 1
	if syms < 2:
		return _fail("origin-axis mirror symmetry constraints wrong: %d" % syms)
	_root.stack.undo()
	if _snap() != json_before:
		return _fail("origin-axis mirror not one undo step")
	_root.stack.redo()

	# --- FILLET, then DRIVE its radius: rims slide along the lines, the far
	# geometry stays put.
	var la := _line(sk, Vector2(100, 100), Vector2(140, 100))
	var pb2 := SketchPoint.make(Vector2(140, 140))
	pb2.id = sk.next_id()
	var lb := SketchLine.make(la.p1, pb2.id)
	lb.id = sk.next_id()
	_root.stack.push_no_merge(CmdAddEntities.new(_root.active_sketch_id,
		[pb2, lb]))
	_root.rebuild_snap_index()
	_root.tools.set_active("fillet")
	_type("0.25")
	_click(Vector2(140, 100))
	var fillet_arc: SketchArc = null
	for e in sk.entities():
		if e.kind() == "arc":
			fillet_arc = e
	if fillet_arc == null:
		return _fail("fillet arc missing")
	_root.add_constraint(SketchConstraint.make(SketchConstraint.Type.RADIUS,
		[fillet_arc.id] as Array[String], 10.0))
	var far_a: Vector2 = sk.point(la.p0).pos
	var far_b: Vector2 = sk.point(lb.p1).pos
	if far_a.distance_to(Vector2(100, 100)) > 0.05 \
			or far_b.distance_to(Vector2(140, 140)) > 0.05:
		return _fail("driving fillet radius moved far geometry: %s %s"
			% [far_a, far_b])
	var fc: Vector2 = sk.point(fillet_arc.center).pos
	if fc.distance_to(Vector2(130, 110)) > 0.1:
		return _fail("driven fillet center wrong: %s" % fc)
	var fr := fc.distance_to(sk.point(fillet_arc.start).pos)
	if absf(fr - 10.0) > 0.05:
		return _fail("driven fillet radius wrong: %f" % fr)
	# Drive it ABSURDLY large (5 in on 40 mm legs): the radius must stop at
	# what the lines can carry — never invert the lines or fling geometry.
	var ridx := -1
	for i in sk.constraints.size():
		if sk.constraints[i].type == SketchConstraint.Type.RADIUS:
			ridx = i
	if _root.set_dimension_value(ridx, "5") != "":
		return _fail("radius dim edit refused")
	if sk.point(la.p0).pos.distance_to(Vector2(100, 100)) > 0.5 \
			or sk.point(lb.p1).pos.distance_to(Vector2(140, 140)) > 0.5:
		return _fail("over-large fillet radius moved far geometry: %s %s"
			% [sk.point(la.p0).pos, sk.point(lb.p1).pos])
	var fr2 := sk.point(fillet_arc.center).pos.distance_to(
		sk.point(fillet_arc.start).pos)
	if not is_finite(fr2) or fr2 > 45.0:
		return _fail("over-large fillet radius ran away: %f" % fr2)

	# --- EXTRUDE mesh: shaded (normals) + edge-line surface, volume intact.
	var doc2 := CadDocument.new()
	var sf := SketchFeature.make("S", "XY")
	sf.id = "f1"
	doc2.features.append(sf)
	doc2.timeline_marker = 1
	var s2 := sf.sketch
	var w1 := SketchPoint.make(Vector2(0, 0))
	var w2 := SketchPoint.make(Vector2(30, 0))
	var w3 := SketchPoint.make(Vector2(30, 20))
	var w4 := SketchPoint.make(Vector2(0, 20))
	for p: SketchPoint in [w1, w2, w3, w4]:
		p.id = s2.next_id()
		s2.add(p)
	for pr: Array in [[w1, w2], [w2, w3], [w3, w4], [w4, w1]]:
		var wl := SketchLine.make((pr[0] as SketchPoint).id, (pr[1] as SketchPoint).id)
		wl.id = s2.next_id()
		s2.add(wl)
	var ef := ExtrudeFeature.make("f1", Vector2(15, 10), 10.0)
	var mesh := ef.build_mesh(doc2)
	if mesh == null or mesh.get_surface_count() != 2:
		return _fail("extrude mesh should have body + edge surfaces")
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if normals.size() != verts.size() or normals.is_empty():
		return _fail("extrude mesh has no normals — solid would shade flat")
	if mesh.surface_get_primitive_type(1) != Mesh.PRIMITIVE_LINES:
		return _fail("extrude edge surface is not lines")
	if absf(ExtrudeFeature.mesh_volume(mesh) - 30.0 * 20.0 * 10.0) > 0.01:
		return _fail("extrude volume wrong with edge surface present")
	# Every face must point OUTWARD on every plane, for both profile windings
	# and for a NEGATIVE distance — a CW profile (or downward extrude) once
	# turned all faces inward and the solid rendered as a see-through hollow
	# shell. Signed volume positive == consistently outward.
	for plane: String in ["XY", "XZ", "YZ"]:
		for dist: float in [10.0, -10.0]:
			for cw: bool in [false, true]:
				var m2 := _rect_mesh(plane, cw, dist)
				if m2 == null:
					return _fail("no mesh for %s cw=%s d=%f" % [plane, cw, dist])
				var sv := _signed_volume(m2)
				if absf(sv - 6000.0) > 0.01:
					return _fail("faces not outward on %s cw=%s d=%f (signed vol %f)"
						% [plane, cw, dist, sv])
				var vv: PackedVector3Array = \
					m2.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				var nn: PackedVector3Array = \
					m2.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
				for t in range(0, vv.size(), 3):
					var fn := (vv[t + 1] - vv[t]).cross(vv[t + 2] - vv[t])
					if fn.normalized().dot(nn[t]) < 0.9:
						return _fail("shading normal disagrees with winding on %s"
							% plane)

	# --- SAVE / OPEN round trip through the app.
	var path := "user://m10_qa_roundtrip.ecad"
	_root.finish_sketch()
	var saved_json := Serializer.to_json(_root.doc)
	if not _root.save_to(path):
		return _fail("save_to failed")
	if not _root.open_from(path):
		return _fail("open_from failed")
	if Serializer.to_json(_root.doc) != saved_json:
		return _fail("save/open round trip changed the document")

	print("M10_QA_FIXES OK: trim/extend joints, chain offset, axis mirror, "
		+ "fillet drive, extrude shading, save/open")
	return true
