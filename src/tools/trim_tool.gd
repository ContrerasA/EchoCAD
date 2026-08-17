class_name TrimTool
extends SketchTool
## Trim (T): hover highlights the doomed span — the piece of the hovered
## curve between its nearest intersections with other geometry — and a
## click removes it. Lines split into remaining segments; circles become
## arcs; arcs shorten or split. One undo step; constraints referencing
## removed entities are pruned with it.

const HIT_PX := 6.0

var _hover_entity := ""
var _hover_span := {}     # see _span_at
var _hover := false
var _preview := Vector2.ZERO


func _init() -> void:
	id = "trim"
	title = "Trim"
	shortcut = KEY_T


func activate() -> void:
	_hover = false
	_hover_entity = ""


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	var sk := sketch()
	_hover_entity = SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	if _hover_entity != "" and sk.entity(_hover_entity).kind() == "point":
		_hover_entity = ""
	_hover_span = _span_at(sk, _hover_entity, world) if _hover_entity != "" else {}
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	pointer_move(world, _screen, null)
	if _hover_entity == "" or _hover_span.is_empty():
		return true
	_apply(sketch(), _hover_entity, _hover_span)
	_hover_entity = ""
	_hover_span = {}
	return true


## The span of `id` under the cursor, bounded by intersections.
## Line: {kind:"line", t0, t1, src0, src1} params in [0,1] (t0/t1 may be 0/1 =
##   endpoint; src0/src1 are the cutting entity ids, "" at a bare endpoint).
## Circle: {kind:"circle", a0, a1, src0, src1} world angles of the removed arc
##   (ccw from a0 to a1); requires >= 2 cuts (else {}).
## Arc: {kind:"arc", r0, r1, src0, src1} relative sweep offsets bounding the
##   removed piece (0..sweep).
func _span_at(sk: Sketch, id: String, world: Vector2) -> Dictionary:
	var e := sk.entity(id)
	var cuts := SketchGeometry.entity_intersections_ex(sk, id)
	cuts.append_array(_touch_cuts(sk, id))
	match e.kind():
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0).pos
			var b := sk.point(l.p1).pos
			var len2 := (b - a).length_squared()
			if len2 < 1e-12:
				return {}
			var tc := clampf((world - a).dot(b - a) / len2, 0.0, 1.0)
			var t0 := 0.0
			var t1 := 1.0
			var src0 := ""
			var src1 := ""
			for cut: Dictionary in cuts:
				var t := ((cut["pos"] as Vector2) - a).dot(b - a) / len2
				if t > t0 and t < tc:
					t0 = t
					src0 = String(cut["other"])
				if t < t1 and t > tc:
					t1 = t
					src1 = String(cut["other"])
			return {"kind": "line", "t0": t0, "t1": t1,
				"src0": src0, "src1": src1}
		"circle":
			if cuts.size() < 2:
				return {}
			var ci := e as SketchCircle
			var c := sk.point(ci.center).pos
			var ac := (world - c).angle()
			var best_before := INF
			var best_after := INF
			var a0 := 0.0
			var a1 := 0.0
			var csrc0 := ""
			var csrc1 := ""
			for cut: Dictionary in cuts:
				var ang := ((cut["pos"] as Vector2) - c).angle()
				var before := fposmod(ac - ang, TAU)   # cut ccw-before cursor
				var after := fposmod(ang - ac, TAU)
				if before < best_before:
					best_before = before
					a0 = ang
					csrc0 = String(cut["other"])
				if after < best_after:
					best_after = after
					a1 = ang
					csrc1 = String(cut["other"])
			return {"kind": "circle", "a0": a0, "a1": a1,
				"src0": csrc0, "src1": csrc1}
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center).pos
			var s := sk.point(arc.start).pos
			var sweep := SketchGeometry.arc_sweep(sk, arc)
			var base := (s - c).angle()
			var rel_of := func(p: Vector2) -> float:
				var ang := (p - c).angle()
				return fposmod(ang - base, TAU) if sweep >= 0.0 \
					else -fposmod(base - ang, TAU)
			var rc: float = rel_of.call(world)
			var r0 := 0.0
			var r1: float = sweep
			var asrc0 := ""
			var asrc1 := ""
			for cut: Dictionary in cuts:
				var rp: float = rel_of.call(cut["pos"])
				if sweep >= 0.0:
					if rp > r0 and rp < rc:
						r0 = rp
						asrc0 = String(cut["other"])
					if rp < r1 and rp > rc:
						r1 = rp
						asrc1 = String(cut["other"])
				else:
					if rp < r0 and rp > rc:
						r0 = rp
						asrc0 = String(cut["other"])
					if rp > r1 and rp < rc:
						r1 = rp
						asrc1 = String(cut["other"])
			return {"kind": "arc", "r0": r0, "r1": r1,
				"src0": asrc0, "src1": asrc1}
	return {}


## T-joint cuts the segment intersector cannot see: another entity's ENDPOINT
## resting on this curve. The solver converges to ~0.0005 mm, so a trimmed or
## extended line "touching" this one usually stops a hair short of it — a
## 1e-9-tolerance segment intersection misses that, and trim would then treat
## the whole curve as uncut and delete all of it.
const TOUCH_TOL := 0.02   # mm

func _touch_cuts(sk: Sketch, id: String) -> Array:
	var e := sk.entity(id)
	if e == null:
		return []
	var out: Array = []
	for other in sk.entities():
		if other.id == id or other.kind() == "point":
			continue
		var ends: Array = []
		if other is SketchLine:
			ends = [(other as SketchLine).p0, (other as SketchLine).p1]
		elif other is SketchArc:
			ends = [(other as SketchArc).start, (other as SketchArc).end]
		for pid: String in ends:
			# The trimmed entity's own points do not cut it.
			if e.point_refs().has(pid):
				continue
			var p := sk.point(pid)
			if p != null and SketchGeometry.distance_to_entity(sk, e, p.pos) \
					<= TOUCH_TOL:
				out.append({"pos": p.pos, "other": other.id})
	return out


func _apply(sk: Sketch, id: String, span: Dictionary) -> void:
	var e := sk.entity(id)
	var batch := CmdMergeBatch.new("Trim", [])
	app.stack.push_no_merge(batch)
	var adds: Array = []
	var cons: Array = []
	# Tie a new cut endpoint onto the entity that cut it, so the joint stays a
	# joint under later edits (dragging the cutter drags the trimmed end too).
	var tie := func(pid: String, src: String) -> void:
		if src != "" and sk.has(src):
			cons.append(SketchConstraint.make(
				SketchConstraint.Type.POINT_ON, [pid, src]))
	match String(span["kind"]):
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0).pos
			var b := sk.point(l.p1).pos
			var t0: float = span["t0"]
			var t1: float = span["t1"]
			if t0 > 1e-9:          # keep [0, t0]
				var np := SketchPoint.make(a.lerp(b, t0))
				np.id = sk.next_id()
				var nl := SketchLine.make(l.p0, np.id)
				nl.id = sk.next_id()
				adds.append_array([np, nl])
				tie.call(np.id, String(span["src0"]))
			if t1 < 1.0 - 1e-9:    # keep [t1, 1]
				var np2 := SketchPoint.make(a.lerp(b, t1))
				np2.id = sk.next_id()
				var nl2 := SketchLine.make(np2.id, l.p1)
				nl2.id = sk.next_id()
				adds.append_array([np2, nl2])
				tie.call(np2.id, String(span["src1"]))
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center).pos
			# Remaining arc: ccw from a1 to a0 (the removed piece was a0->a1
			# around the cursor... keep the complement). The circle's own
			# center point is reused — deleting the circle leaves the point,
			# and minting a duplicate stranded the original as debris.
			var a0: float = span["a0"]
			var a1: float = span["a1"]
			var sp := SketchPoint.make(c + Vector2(cos(a1), sin(a1)) * ci.radius)
			var ep := SketchPoint.make(c + Vector2(cos(a0), sin(a0)) * ci.radius)
			for p: SketchPoint in [sp, ep]:
				p.id = sk.next_id()
			var na := SketchArc.make(ci.center, sp.id, ep.id, true)
			na.id = sk.next_id()
			adds.append_array([sp, ep, na])
			tie.call(sp.id, String(span["src1"]))
			tie.call(ep.id, String(span["src0"]))
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center).pos
			var s := sk.point(arc.start).pos
			var r := c.distance_to(s)
			var base := (s - c).angle()
			var sweep := SketchGeometry.arc_sweep(sk, arc)
			var r0: float = span["r0"]
			var r1: float = span["r1"]
			if absf(r0) > 1e-9:    # keep start..r0 (center point reused)
				var mp := SketchPoint.make(c
					+ Vector2(cos(base + r0), sin(base + r0)) * r)
				mp.id = sk.next_id()
				var na2 := SketchArc.make(arc.center, arc.start, mp.id, sweep >= 0.0)
				na2.id = sk.next_id()
				adds.append_array([mp, na2])
				tie.call(mp.id, String(span["src0"]))
			if absf(r1) < absf(sweep) - 1e-9:   # keep r1..end
				var mp3 := SketchPoint.make(c
					+ Vector2(cos(base + r1), sin(base + r1)) * r)
				mp3.id = sk.next_id()
				var na3 := SketchArc.make(arc.center, mp3.id, arc.end, sweep >= 0.0)
				na3.id = sk.next_id()
				adds.append_array([mp3, na3])
				tie.call(mp3.id, String(span["src1"]))
	if not adds.is_empty():
		app.stack.push(CmdAddEntities.new(app.active_sketch_id, adds, cons))
	# POINT_ONs that referenced the trimmed entity retarget onto whichever
	# kept piece the point actually lies on — deleting the entity would prune
	# them, silently unhooking joints made by EARLIER trims/extends.
	_retarget_point_ons(sk, id, adds)
	# Likewise the entity-level constraints (M19): a kept line piece is
	# collinear with its source, so directional constraints still hold; a
	# kept arc keeps its circle's radius, so radial ones do too.
	_retarget_entity_constraints(sk, id, adds)
	# Points of the trimmed entity that nothing references any more (a bare
	# endpoint whose span was removed) go with it — trim must not shed debris.
	var doomed: Array[String] = [id]
	app.stack.push(CmdDeleteEntities.new(app.active_sketch_id,
		app._with_orphaned_points(sk, doomed)))
	batch.seal()
	app.rebuild_snap_index()


## Move the trimmed entity's other constraints onto its kept pieces instead
## of letting the delete prune them (M19):
## - a trimmed LINE's pieces lie on the same infinite line, so HORIZONTAL /
##   VERTICAL / PARALLEL / PERPENDICULAR / COLLINEAR hold for EVERY piece —
##   the first piece takes the constraint, further pieces get copies;
## - a trimmed CIRCLE/ARC's pieces keep the radius, so CONCENTRIC / EQUAL /
##   RADIUS / DIAMETER move to the kept arc;
## - TANGENT moves to the piece that still touches the tangency (smallest
##   live residual); when the tangent span itself was cut away, the
##   constraint dies with the entity, which is the honest outcome.
## Length-type constraints on a line (EQUAL, dimensions) die: a piece is
## shorter than its source, so carrying them over would RESIZE the piece.
func _retarget_entity_constraints(sk: Sketch, doomed_id: String,
		adds: Array) -> void:
	var doomed := sk.entity(doomed_id)
	if doomed == null:
		return
	var line_pieces: Array = []
	var curve_pieces: Array = []
	for e in adds:
		if e is SketchLine:
			line_pieces.append(e)
		elif e is SketchArc or e is SketchCircle:
			curve_pieces.append(e)
	var T := SketchConstraint.Type
	var after: Array = []
	var extra: Array = []
	var changed := false

	var swap := func(c: SketchConstraint, to: String) -> SketchConstraint:
		var rc := c.duplicate_constraint()
		for i in rc.operands.size():
			if String(rc.operands[i]) == doomed_id:
				rc.operands[i] = to
		return rc

	for c in sk.constraints:
		if c.type == T.POINT_ON or not c.references(doomed_id):
			after.append(c)
			continue
		var handled := false
		if c.type == T.TANGENT:
			var best: SketchEntity = null
			var best_err := 0.05   # mm — beyond this no piece truly touches
			for piece: SketchEntity in line_pieces + curve_pieces:
				var err := ConstraintSolver.error_of(sk, swap.call(c, piece.id))
				if err < best_err:
					best_err = err
					best = piece
			if best != null:
				after.append(swap.call(c, best.id))
				changed = true
				handled = true
		elif doomed is SketchLine and c.type in [T.HORIZONTAL, T.VERTICAL,
				T.PARALLEL, T.PERPENDICULAR, T.COLLINEAR]:
			var first := true
			for piece: SketchEntity in line_pieces:
				var rc: SketchConstraint = swap.call(c, piece.id)
				if first:
					after.append(rc)
					first = false
				else:
					extra.append(rc)
				changed = true
				handled = true
		elif (doomed is SketchCircle or doomed is SketchArc) \
				and c.type in [T.CONCENTRIC, T.EQUAL, T.RADIUS, T.DIAMETER] \
				and not curve_pieces.is_empty():
			after.append(swap.call(c, (curve_pieces[0] as SketchEntity).id))
			changed = true
			handled = true
		if not handled:
			after.append(c)   # untouched (or dies with the entity on delete)
	if changed:
		after.append_array(extra)
		app.stack.push(CmdSetConstraints.new(app.active_sketch_id,
			sk.constraints, after))


## Rewrite POINT_ON [p, doomed] to [p, kept piece under p] where such a piece
## exists (constraints that cannot be retargeted die with the entity).
func _retarget_point_ons(sk: Sketch, doomed_id: String, adds: Array) -> void:
	var pieces: Array = []
	for e in adds:
		if (e as SketchEntity).kind() != "point":
			pieces.append(e)
	if pieces.is_empty():
		return
	var after: Array = []
	var changed := false
	for c in sk.constraints:
		if c.type != SketchConstraint.Type.POINT_ON \
				or c.operands[1] != doomed_id:
			after.append(c)
			continue
		var p := sk.point(c.operands[0])
		var new_target := ""
		if p != null:
			for piece: SketchEntity in pieces:
				if SketchGeometry.distance_to_entity(sk, piece, p.pos) < 0.05:
					new_target = piece.id
					break
		if new_target == "":
			after.append(c)   # off every kept piece; the delete prunes it
			continue
		var rc := c.duplicate_constraint()
		rc.operands[1] = new_target
		after.append(rc)
		changed = true
	if changed:
		app.stack.push(CmdSetConstraints.new(app.active_sketch_id,
			sk.constraints, after))


func draw_overlay(overlay: Control) -> void:
	if not _hover or _hover_entity == "" or _hover_span.is_empty():
		return
	var sk := sketch()
	var v := view()
	var doom := Color(0.95, 0.35, 0.35, 0.95)
	var e := sk.entity(_hover_entity)
	match String(_hover_span["kind"]):
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0).pos
			var b := sk.point(l.p1).pos
			overlay.draw_line(
				v.world_to_screen(a.lerp(b, _hover_span["t0"])),
				v.world_to_screen(a.lerp(b, _hover_span["t1"])), doom, 3.0)
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center).pos
			var a0: float = _hover_span["a0"]
			var a1: float = _hover_span["a1"]
			var sweep := fposmod(a1 - a0, TAU)
			overlay.draw_arc(v.world_to_screen(c), ci.radius * v.zoom(),
				-a0, -(a0 + sweep), 48, doom, 3.0)
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center).pos
			var s := sk.point(arc.start).pos
			var base := (s - c).angle()
			overlay.draw_arc(v.world_to_screen(c),
				c.distance_to(s) * v.zoom(),
				-(base + float(_hover_span["r0"])),
				-(base + float(_hover_span["r1"])), 48, doom, 3.0)
