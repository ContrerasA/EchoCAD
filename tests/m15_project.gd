extends SceneTree

# M15: Project / reference geometry. Projected entities are real, linked
# entities: they follow their source, pin in the solver/DOF, break their link
# (with a message, not a crash) when the source dies, and survive save/load.

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
	push_error("m15_project: " + msg)
	return false


func _run() -> bool:
	_root.size = Vector2(1280, 800)

	# --- source sketch S1 on XY: a rectangle -------------------------------
	var sid1 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var sk1: Sketch = _root.doc.sketch_feature(sid1).sketch
	var corner_ids := _rect(sk1, Vector2(10, 10), Vector2(50, 40))
	_root.finish_sketch()

	# --- target sketch S2 on the same plane --------------------------------
	var sid2 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var sk2: Sketch = _root.doc.sketch_feature(sid2).sketch
	if _root.reference_features().size() != 1:
		return _fail("S1 should be S2's reference")

	# --- project S1's bottom line with the real tool -----------------------
	_root.tools.set_active("project")
	var tool: SketchTool = _root.tools.get_tool("project")
	var mid := Vector2(30, 10)   # on the bottom edge of the rect
	tool.pointer_move(mid, Vector2.ZERO, InputEventMouseMotion.new())
	var n_before := sk2.size()
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	tool.pointer_down(mid, Vector2.ZERO, mb)
	if sk2.size() != n_before + 3:
		return _fail("projecting a line should add 2 points + 1 line (got +%d)"
			% (sk2.size() - n_before))
	var plines := _projected_of_kind(sk2, "line")
	if plines.size() != 1:
		return _fail("no projected line found")
	var pl := plines[0] as SketchLine
	if not (sk2.point(pl.p0).is_projected() and sk2.point(pl.p1).is_projected()):
		return _fail("projected line endpoints are not linked")
	var a: Vector2 = sk2.point(pl.p0).pos
	var b: Vector2 = sk2.point(pl.p1).pos
	if minf(a.x, b.x) != 10.0 or maxf(a.x, b.x) != 50.0 or a.y != 10.0 or b.y != 10.0:
		return _fail("same-plane projection should be an identity copy, got %s-%s"
			% [str(a), str(b)])

	# --- an adjoining edge SHARES the projected corner ---------------------
	var side := Vector2(50, 25)   # right edge
	tool.pointer_move(side, Vector2.ZERO, InputEventMouseMotion.new())
	n_before = sk2.size()
	tool.pointer_down(side, Vector2.ZERO, mb)
	if sk2.size() != n_before + 2:
		return _fail("adjoining edge should reuse the shared corner (+2, got +%d)"
			% (sk2.size() - n_before))

	# --- projecting the same edge twice is refused -------------------------
	tool.pointer_move(mid, Vector2.ZERO, InputEventMouseMotion.new())
	n_before = sk2.size()
	tool.pointer_down(mid, Vector2.ZERO, mb)
	if sk2.size() != n_before:
		return _fail("duplicate projection was not refused")

	# --- projected points are pinned: 0 DOF, reported constrained ----------
	var dof := DofAnalyzer.analyze(sk2)
	if int(dof["dof"]) != 0 or not bool(dof["fully_constrained"]):
		return _fail("projected-only sketch should be fully constrained (dof=%d)"
			% int(dof["dof"]))
	for pid in [pl.p0, pl.p1]:
		if not (dof["constrained_points"] as Array).has(pid):
			return _fail("projected point %s not reported constrained" % pid)

	# --- moving the source re-solves the projection (and dependents) -------
	# A free point in S2 welded to a projected corner must follow the source.
	var free := SketchPoint.make(Vector2(0, 0))
	free.id = sk2.next_id()
	sk2.add(free)
	var corner_id := pl.p0 if sk2.point(pl.p0).pos == Vector2(10, 10) else pl.p1
	sk2.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.COINCIDENT, [free.id, corner_id]))
	# Move S1's (10,10) corner to (5, 8), then refresh.
	var src_corner: SketchPoint = null
	for cid in corner_ids:
		if sk1.point(cid).pos == Vector2(10, 10):
			src_corner = sk1.point(cid)
	src_corner.pos = Vector2(5, 8)
	var msgs := Projector.refresh(_root.doc)
	if not msgs.is_empty():
		return _fail("clean refresh produced messages: %s" % str(msgs))
	if sk2.point(corner_id).pos != Vector2(5, 8):
		return _fail("projected corner did not follow its source (got %s)"
			% str(sk2.point(corner_id).pos))
	if sk2.point(free.id).pos.distance_to(Vector2(5, 8)) > 0.01:
		return _fail("dependent of the projection did not re-solve (got %s)"
			% str(sk2.point(free.id).pos))

	# --- cross-plane rules --------------------------------------------------
	_root.finish_sketch()
	var sid3 := _root.create_sketch("XZ")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var feat3 := _root.doc.sketch_feature(sid3)
	var feat1 := _root.doc.sketch_feature(sid1)
	var r := Projector.build(feat3, feat1, pl.link_entity)
	if String(r["error"]) != "":
		return _fail("line should project XY->XZ, got: " + String(r["error"]))
	# A projected copy of the (5,8)-(50,10) edge: world (u, v, 0) onto XZ
	# (u = world.x, v = world.z = 0) — flattens onto the X axis.
	for e: SketchEntity in r["entities"]:
		if e.kind() == "point" and absf((e as SketchPoint).pos.y) > 1e-9:
			return _fail("XY->XZ projection should land on v=0")
	# Circles refuse non-parallel planes.
	var circ := SketchCircle.make("", 5.0)
	var cp := SketchPoint.make(Vector2(30, 30))
	cp.id = sk1.next_id()
	sk1.add(cp)
	circ.center = cp.id
	circ.id = sk1.next_id()
	sk1.add(circ)
	var rc := Projector.build(feat3, feat1, circ.id)
	if String(rc["error"]) == "":
		return _fail("circle XY->XZ should be refused (would be an ellipse)")
	_root.finish_sketch()

	# --- projected geometry forms profiles (extrudable) --------------------
	var sid4 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	var feat4 := _root.doc.sketch_feature(sid4)
	var sk4: Sketch = feat4.sketch
	for e in sk1.entities():
		if e.kind() == "line":
			var rr := Projector.build(feat4, feat1, e.id)
			if String(rr["error"]) != "":
				return _fail("projecting rect edge failed: " + String(rr["error"]))
			for ne: SketchEntity in rr["entities"]:
				sk4.add(ne)
	if ProfileFinder.profile_at(sk4, Vector2(30, 25)).is_empty():
		return _fail("projected rectangle does not form a profile")
	_root.finish_sketch()

	# --- deleting the source breaks the link with a message ----------------
	var src_line_id := pl.link_entity
	sk1.remove(src_line_id)
	var broken := Projector.refresh(_root.doc)
	if broken.is_empty():
		return _fail("no message reported for a dead projection source")
	if pl.is_projected():
		return _fail("dead source did not break the line's link")
	if sk2.point(pl.p0).is_projected():
		# Endpoints link to source POINTS which still exist — they stay linked.
		pass
	if not sk2.has(pl.id):
		return _fail("breaking a link must keep the geometry")

	# --- projections survive save/load -------------------------------------
	var path := "user://m15_roundtrip.ecad"
	if not Serializer.save(_root.doc, path):
		return _fail("save failed")
	var loaded := Serializer.load_file(path)
	if loaded == null:
		return _fail("load failed")
	var lsk2: Sketch = loaded.sketch_feature(sid2).sketch
	var lp := lsk2.entity(pl.p0)
	if lp == null or not lp.is_projected():
		return _fail("projected point link lost in save/load")
	if lp.link_feature != sid1:
		return _fail("link feature wrong after load: " + lp.link_feature)
	var d1 := JSON.stringify(_root.doc.to_dict())
	var d2 := JSON.stringify(loaded.to_dict())
	if d1 != d2:
		return _fail("save->load->save not identical")

	print("M15 OK: linked projection, source-follow, broken links, save/load, profiles")
	return true


func _projected_of_kind(sk: Sketch, k: String) -> Array:
	var out: Array = []
	for e in sk.entities():
		if e.kind() == k and e.is_projected():
			out.append(e)
	return out


func _rect(sk: Sketch, a: Vector2, b: Vector2) -> Array[String]:
	var ids: Array[String] = []
	for p: Vector2 in [a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)]:
		var pt := SketchPoint.make(p)
		pt.id = sk.next_id()
		sk.add(pt)
		ids.append(pt.id)
	for i in 4:
		var ln := SketchLine.make(ids[i], ids[(i + 1) % 4])
		ln.id = sk.next_id()
		sk.add(ln)
	return ids
