class_name OffsetTool
extends SketchTool
## Offset (O): click an entity (or select several with V first, then press O),
## move the cursor to choose side and distance — live preview — then click or
## type a distance + Enter for exactness. A single click picks the WHOLE
## connected chain, Fusion-style (M19): every element shifts the same
## distance to the same side, shared corners are re-intersected, tangent
## joints stay joined. The copies are CONSTRAINED to their sources: each
## offset line is PARALLEL to its source and one driving point-to-line
## dimension holds the gap; offset arcs/circles share their source's center
## point, so they are concentric by construction. One undo step.

var _targets: Array[String] = []
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
	_seed_from_selection()


func deactivate() -> void:
	_reset()


func _reset() -> void:
	_targets.clear()
	_hover = false
	_fields.reset()
	clear_hover()


## A selection made with Select before arming Offset becomes the target set —
## no pick click needed, the cursor immediately drives side/distance.
func _seed_from_selection() -> void:
	var sk := sketch()
	if sk == null:
		return
	for sel_id in app.selection:
		var e := sk.entity(sel_id)
		if e != null and e.kind() != "point":
			_targets.append(sel_id)
	if not _targets.is_empty():
		app.set_status_hint(
			"Offset: move to choose side and distance, click or type a value")


func cancel() -> bool:
	if not _targets.is_empty() or _hover:
		_reset()
		return true
	return false


func commit() -> bool:
	if _targets.is_empty():
		return false
	_apply()
	return true


func key_input(e: InputEventKey) -> bool:
	if _targets.is_empty():
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return commit()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	if _targets.is_empty():
		# Pre-highlight what a click would pick (curves only — offsetting a
		# point is meaningless, so a point must not light up as available).
		update_hover(world)
		var sk := sketch()
		if hover_id != "" and sk.entity(hover_id).kind() == "point":
			hover_id = ""
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	if _targets.is_empty():
		var hit := SketchGeometry.entity_at(sk, world, 6.0 / view().zoom())
		if hit != "" and sk.entity(hit).kind() != "point":
			# One click offsets the whole connected chain (Fusion behaviour):
			# picking one edge of a rectangle offsets the rectangle.
			_targets.append_array(_connected_chain(sk, hit))
			clear_hover()
		return true
	_preview = world
	_apply()
	return true


## --- geometry -----------------------------------------------------------------

## Every line/arc reachable from `seed` through shared endpoints or
## COINCIDENT welds between endpoints. Circles have no endpoints — a circle
## seed stays alone.
static func _connected_chain(sk: Sketch, seed: String) -> Array[String]:
	var out: Array[String] = [seed]
	var seed_e := sk.entity(seed)
	if seed_e == null or seed_e is SketchCircle:
		return out
	# Node = weld group: endpoint ids merged through COINCIDENT constraints.
	var group := {}       # pid -> group root
	var find := func(pid: String) -> String:
		var r := pid
		while group.get(r, r) != r:
			r = group[r]
		return r
	for e in sk.entities():
		for pid: String in _elem_ends(e):
			if not group.has(pid):
				group[pid] = pid
	for c in sk.constraints:
		if c.type != SketchConstraint.Type.COINCIDENT or c.operands.size() != 2:
			continue
		var a := String(c.operands[0])
		var b := String(c.operands[1])
		if group.has(a) and group.has(b):
			group[find.call(b)] = find.call(a)
	var by_node := {}     # group root -> [entity id]
	for e in sk.entities():
		if not (e is SketchLine or e is SketchArc):
			continue
		for pid: String in _elem_ends(e):
			var r: String = find.call(pid)
			if not by_node.has(r):
				by_node[r] = []
			(by_node[r] as Array).append(e.id)
	var queue: Array = [seed]
	var seen := {seed: true}
	while not queue.is_empty():
		var cur: String = queue.pop_back()
		var ce := sk.entity(cur)
		if ce == null:
			continue
		for pid: String in _elem_ends(ce):
			for nb: String in by_node.get(find.call(pid), []):
				if not seen.has(nb):
					seen[nb] = true
					out.append(nb)
					queue.append(nb)
	return out


static func _elem_ends(e: SketchEntity) -> Array:
	if e is SketchLine:
		return [(e as SketchLine).p0, (e as SketchLine).p1]
	if e is SketchArc:
		return [(e as SketchArc).start, (e as SketchArc).end]
	return []


## Offset solution for the current cursor/typed distance.
## {"ok": bool, "pts": {orig point id: Vector2 (offset position)},
##  "elems": [{"e": entity, "r2": float (arcs)}], "circles": [{e, c, r2}]}
func _compute(sk: Sketch) -> Dictionary:
	var chain_elems: Array = []
	var circles: Array = []
	for tid in _targets:
		var e := sk.entity(tid)
		if e == null:
			continue
		if e is SketchCircle:
			circles.append(e)
		elif e is SketchLine or e is SketchArc:
			chain_elems.append(e)
	if chain_elems.is_empty() and circles.is_empty():
		return {"ok": false}

	var typed := _fields.value_mm(0, app.doc.display_unit)
	# Distance from the cursor to the NEAREST target (its perpendicular gap).
	var cursor_d := INF
	for e in chain_elems + circles:
		if e is SketchCircle:
			var cc: Vector2 = sk.point((e as SketchCircle).center).pos
			cursor_d = minf(cursor_d, absf(
				cc.distance_to(_preview) - (e as SketchCircle).radius))
		else:
			cursor_d = minf(cursor_d, SketchGeometry.distance_to_entity(sk, e, _preview))
	var d := absf(typed) if not is_nan(typed) else cursor_d
	if not is_finite(d) or d < 1e-6:
		return {"ok": false}

	var pts := {}
	var elems: Array = []
	# Connectivity over the chainable elements.
	var deg := {}
	var by_pt := {}
	for e: SketchEntity in chain_elems:
		for pid: String in _elem_ends(e):
			deg[pid] = int(deg.get(pid, 0)) + 1
			if not by_pt.has(pid):
				by_pt[pid] = []
			(by_pt[pid] as Array).append(e)
	var branched := false
	for pid: String in deg:
		if int(deg[pid]) > 2:
			branched = true
	var seen := {}
	for e: SketchEntity in chain_elems:
		if seen.has(e.id):
			continue
		# Component members (flood fill), or the lone element when branched —
		# a T junction has no single consistent side, so branched selections
		# fall back to independent per-element offsets.
		var members: Array = [e]
		seen[e.id] = true
		if not branched:
			var queue: Array = [e]
			while not queue.is_empty():
				var cur: SketchEntity = queue.pop_back()
				for pid: String in _elem_ends(cur):
					for nb: SketchEntity in by_pt[pid]:
						if not seen.has(nb.id):
							seen[nb.id] = true
							members.append(nb)
							queue.append(nb)
		var comp := _offset_component(sk, members, deg, by_pt, d)
		if not bool(comp["ok"]):
			return {"ok": false}
		for pid: String in comp["pts"]:
			pts[pid] = comp["pts"][pid]
		elems.append_array(comp["elems"])

	var circ_out: Array = []
	for ci: SketchCircle in circles:
		var cc: Vector2 = sk.point(ci.center).pos
		var new_r := ci.radius + d if cc.distance_to(_preview) > ci.radius \
			else maxf(ci.radius - d, 0.01)
		circ_out.append({"e": ci, "c": cc, "r2": new_r})
	return {"ok": true, "pts": pts, "elems": elems, "circles": circ_out, "d": d}


## Offset one connected run of lines/arcs by `d`, side chosen from the cursor.
func _offset_component(sk: Sketch, members: Array, deg: Dictionary,
		by_pt: Dictionary, d: float) -> Dictionary:
	# Order the run: start at a degree-1 endpoint (open chain) or anywhere
	# (closed loop), then walk shared points.
	var start: SketchEntity = members[0]
	var start_pid := ""
	for m: SketchEntity in members:
		for pid: String in _elem_ends(m):
			if int(deg.get(pid, 0)) == 1:
				start = m
				start_pid = pid
				break
		if start_pid != "":
			break
	if start_pid == "":
		start_pid = _elem_ends(start)[0]
	var ordered: Array = []   # [{e, a, b}] traversal a -> b
	var walked := {}
	var cur: SketchEntity = start
	var cur_in := start_pid
	while cur != null and not walked.has(cur.id):
		walked[cur.id] = true
		var ends := _elem_ends(cur)
		var b: String = ends[1] if String(ends[0]) == cur_in else ends[0]
		ordered.append({"e": cur, "a": cur_in, "b": b})
		var nxt: SketchEntity = null
		if by_pt.has(b):
			for nb: SketchEntity in by_pt[b]:
				if nb.id != cur.id and members.has(nb) and not walked.has(nb.id):
					nxt = nb
					break
		cur = nxt
		cur_in = b

	# Side sign from the member nearest the cursor: +1 = offset along the
	# traversal's RIGHT normal (`Vector2.orthogonal()` is a -90° rotation in
	# Y-up sketch coords), so one sign moves the whole chain coherently.
	var best_rec: Dictionary = ordered[0]
	var best_d := INF
	for rec: Dictionary in ordered:
		var dd := SketchGeometry.distance_to_entity(sk, rec["e"], _preview)
		if dd < best_d:
			best_d = dd
			best_rec = rec
	var s := 1.0
	var be: SketchEntity = best_rec["e"]
	if be is SketchLine:
		var a: Vector2 = sk.point(best_rec["a"]).pos
		var bpos: Vector2 = sk.point(best_rec["b"]).pos
		var n := (bpos - a).normalized().orthogonal()
		s = signf(n.dot(_preview - a))
		if s == 0.0:
			s = 1.0
	else:
		var arc := be as SketchArc
		var cc: Vector2 = sk.point(arc.center).pos
		var r := cc.distance_to(sk.point(arc.start).pos)
		var ccw_eff: bool = arc.ccw if String(best_rec["a"]) == arc.start \
			else not arc.ccw
		# CCW travel puts the center on the LEFT; cursor inside then means
		# offsetting against the right normal.
		s = -1.0 if (cc.distance_to(_preview) < r) == ccw_eff else 1.0
	var delta := s * d

	# Per-element offset endpoints (left normal / concentric radius change).
	for rec: Dictionary in ordered:
		var e: SketchEntity = rec["e"]
		var pa: Vector2 = sk.point(rec["a"]).pos
		var pb: Vector2 = sk.point(rec["b"]).pos
		if e is SketchLine:
			var n := (pb - pa).normalized().orthogonal()
			rec["off_a"] = pa + n * delta
			rec["off_b"] = pb + n * delta
		else:
			var arc := e as SketchArc
			var cc: Vector2 = sk.point(arc.center).pos
			var r := cc.distance_to(sk.point(arc.start).pos)
			var ccw_eff: bool = arc.ccw if String(rec["a"]) == arc.start \
				else not arc.ccw
			var r2 := maxf((r + delta) if ccw_eff else (r - delta), 0.01)
			rec["r2"] = r2
			var da := (pa - cc)
			var db := (pb - cc)
			if da.length() < 1e-9 or db.length() < 1e-9:
				return {"ok": false}
			rec["off_a"] = cc + da.normalized() * r2
			rec["off_b"] = cc + db.normalized() * r2

	# Joints: consecutive elements share a point and must share its offset.
	# Line-line corners re-intersect (the Fusion/Illustrator corner); tangent
	# joints already coincide, so anything else meets in the middle.
	var pts := {}
	var closed: bool = ordered.size() > 1 \
		and String((ordered[ordered.size() - 1] as Dictionary)["b"]) \
			== String((ordered[0] as Dictionary)["a"])
	var joints := ordered.size() - (0 if closed else 1)
	for i in joints:
		var r1: Dictionary = ordered[i]
		var r2: Dictionary = ordered[(i + 1) % ordered.size()]
		var pid := String(r1["b"])
		var e1: SketchEntity = r1["e"]
		var e2: SketchEntity = r2["e"]
		var merged: Vector2 = ((r1["off_b"] as Vector2) + (r2["off_a"] as Vector2)) * 0.5
		if e1 is SketchLine and e2 is SketchLine:
			var a1: Vector2 = r1["off_a"]
			var b1: Vector2 = r1["off_b"]
			var a2: Vector2 = r2["off_a"]
			var b2: Vector2 = r2["off_b"]
			var d1 := b1 - a1
			var d2 := b2 - a2
			var denom := d1.cross(d2)
			if absf(denom) > 1e-9:
				merged = a1 + d1 * ((a2 - a1).cross(d2) / denom)
		pts[pid] = merged
	# Free ends keep their own offset position.
	for rec: Dictionary in ordered:
		for key: Array in [["a", "off_a"], ["b", "off_b"]]:
			var pid := String(rec[key[0]])
			if not pts.has(pid):
				pts[pid] = rec[key[1]]
	var elems: Array = []
	for rec: Dictionary in ordered:
		elems.append({"e": rec["e"], "r2": rec.get("r2", 0.0)})
	return {"ok": true, "pts": pts, "elems": elems}


func _apply() -> void:
	var sk := sketch()
	var spec := _compute(sk)
	if not bool(spec.get("ok", false)):
		app.set_status_hint("Offset: nothing to offset here")
		_reset()
		return
	var adds: Array = []
	var cons: Array = []
	var pid_map := {}
	for pid: String in spec["pts"]:
		var np := SketchPoint.make(spec["pts"][pid])
		np.id = sk.next_id()
		pid_map[pid] = np.id
		adds.append(np)
	# The copies are tied to their sources (M19): PARALLEL per line, and ONE
	# driving point-to-line gap dimension on the first offset line, so the
	# offset follows its source through later edits. Arcs/circles reuse the
	# source's center point — concentric by construction, no constraint needed.
	var gap_done := false
	for rec: Dictionary in spec["elems"]:
		var e: SketchEntity = rec["e"]
		if e is SketchLine:
			var l := e as SketchLine
			var nl := SketchLine.make(pid_map[l.p0], pid_map[l.p1])
			nl.id = sk.next_id()
			nl.construction = l.construction
			adds.append(nl)
			cons.append(SketchConstraint.make(
				SketchConstraint.Type.PARALLEL, [nl.id, l.id]))
			if not gap_done:
				var gap := SketchConstraint.make(
					SketchConstraint.Type.POINT_LINE_DIST,
					[pid_map[l.p0], l.id], float(spec["d"]))
				cons.append(gap)
				gap_done = true
		else:
			var arc := e as SketchArc
			# The source's center point is REUSED: the offset arc is concentric
			# by construction, and a duplicate center would be loose debris.
			var na := SketchArc.make(arc.center, pid_map[arc.start],
				pid_map[arc.end], arc.ccw)
			na.id = sk.next_id()
			na.construction = arc.construction
			adds.append(na)
	for rec: Dictionary in spec["circles"]:
		var ci: SketchCircle = rec["e"]
		var nc := SketchCircle.make(ci.center, rec["r2"])
		nc.id = sk.next_id()
		nc.construction = ci.construction
		adds.append(nc)
	if adds.is_empty():
		_reset()
		return
	app.stack.push_no_merge(CmdAddEntities.new(app.active_sketch_id, adds, cons))
	app.rebuild_snap_index()
	_reset()


func draw_overlay(overlay: Control) -> void:
	if not _hover or _targets.is_empty():
		return
	var sk := sketch()
	var v := view()
	var spec := _compute(sk)
	if not bool(spec.get("ok", false)):
		return
	var col := Color(1, 1, 1, 0.8)
	for rec: Dictionary in spec["elems"]:
		var e: SketchEntity = rec["e"]
		if e is SketchLine:
			var l := e as SketchLine
			overlay.draw_line(v.world_to_screen(spec["pts"][l.p0]),
				v.world_to_screen(spec["pts"][l.p1]), col, 1.0)
		else:
			var arc := e as SketchArc
			var cc: Vector2 = sk.point(arc.center).pos
			var sp: Vector2 = spec["pts"][arc.start]
			var ep: Vector2 = spec["pts"][arc.end]
			var a0 := (sp - cc).angle()
			var sweep := (ep - cc).angle() - a0
			if arc.ccw and sweep < 0.0:
				sweep += TAU
			elif not arc.ccw and sweep > 0.0:
				sweep -= TAU
			# Screen space is Y-down: angles negate.
			overlay.draw_arc(v.world_to_screen(cc),
				float(rec["r2"]) * v.zoom(), -a0, -(a0 + sweep), 48, col, 1.0)
	for rec: Dictionary in spec["circles"]:
		overlay.draw_arc(v.world_to_screen(rec["c"]),
			float(rec["r2"]) * v.zoom(), 0, TAU, 64, col, 1.0)
	_fields.draw(overlay, v.world_to_screen(_preview),
		app.doc.display_unit, [float(spec.get("d", 0.0))])
