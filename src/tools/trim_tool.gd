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
## Line: {kind:"line", t0, t1} params in [0,1] (t0/t1 may be 0/1 = endpoint).
## Circle: {kind:"circle", a0, a1} world angles of the removed arc (ccw
##   from a0 to a1); requires >= 2 cuts (else {}).
## Arc: {kind:"arc", r0, r1} relative sweep offsets bounding the removed
##   piece (0..sweep).
func _span_at(sk: Sketch, id: String, world: Vector2) -> Dictionary:
	var e := sk.entity(id)
	var cuts := SketchGeometry.entity_intersections(sk, id)
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
			for p: Vector2 in cuts:
				var t := (p - a).dot(b - a) / len2
				if t > t0 and t < tc:
					t0 = t
				if t < t1 and t > tc:
					t1 = t
			return {"kind": "line", "t0": t0, "t1": t1}
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
			for p: Vector2 in cuts:
				var ang := (p - c).angle()
				var before := fposmod(ac - ang, TAU)   # cut ccw-before cursor
				var after := fposmod(ang - ac, TAU)
				if before < best_before:
					best_before = before
					a0 = ang
				if after < best_after:
					best_after = after
					a1 = ang
			return {"kind": "circle", "a0": a0, "a1": a1}
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
			for p: Vector2 in cuts:
				var rp: float = rel_of.call(p)
				if sweep >= 0.0:
					if rp > r0 and rp < rc:
						r0 = rp
					if rp < r1 and rp > rc:
						r1 = rp
				else:
					if rp < r0 and rp > rc:
						r0 = rp
					if rp > r1 and rp < rc:
						r1 = rp
			return {"kind": "arc", "r0": r0, "r1": r1}
	return {}


func _apply(sk: Sketch, id: String, span: Dictionary) -> void:
	var e := sk.entity(id)
	var batch := CmdMergeBatch.new("Trim", [])
	app.stack.push_no_merge(batch)
	var adds: Array = []
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
			if t1 < 1.0 - 1e-9:    # keep [t1, 1]
				var np2 := SketchPoint.make(a.lerp(b, t1))
				np2.id = sk.next_id()
				var nl2 := SketchLine.make(np2.id, l.p1)
				nl2.id = sk.next_id()
				adds.append_array([np2, nl2])
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center).pos
			# Remaining arc: ccw from a1 to a0 (the removed piece was a0->a1
			# around the cursor... keep the complement).
			var a0: float = span["a0"]
			var a1: float = span["a1"]
			var sp := SketchPoint.make(c + Vector2(cos(a1), sin(a1)) * ci.radius)
			var ep := SketchPoint.make(c + Vector2(cos(a0), sin(a0)) * ci.radius)
			var cp := SketchPoint.make(c)
			for p: SketchPoint in [cp, sp, ep]:
				p.id = sk.next_id()
			var na := SketchArc.make(cp.id, sp.id, ep.id, true)
			na.id = sk.next_id()
			adds.append_array([cp, sp, ep, na])
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center).pos
			var s := sk.point(arc.start).pos
			var r := c.distance_to(s)
			var base := (s - c).angle()
			var sweep := SketchGeometry.arc_sweep(sk, arc)
			var r0: float = span["r0"]
			var r1: float = span["r1"]
			if absf(r0) > 1e-9:    # keep start..r0
				var mp := SketchPoint.make(c
					+ Vector2(cos(base + r0), sin(base + r0)) * r)
				var cp2 := SketchPoint.make(c)
				mp.id = sk.next_id()
				cp2.id = sk.next_id()
				var na2 := SketchArc.make(cp2.id, arc.start, mp.id, sweep >= 0.0)
				na2.id = sk.next_id()
				adds.append_array([mp, cp2, na2])
			if absf(r1) < absf(sweep) - 1e-9:   # keep r1..end
				var mp3 := SketchPoint.make(c
					+ Vector2(cos(base + r1), sin(base + r1)) * r)
				var cp3 := SketchPoint.make(c)
				mp3.id = sk.next_id()
				cp3.id = sk.next_id()
				var na3 := SketchArc.make(cp3.id, mp3.id, arc.end, sweep >= 0.0)
				na3.id = sk.next_id()
				adds.append_array([mp3, cp3, na3])
	if not adds.is_empty():
		app.stack.push(CmdAddEntities.new(app.active_sketch_id, adds))
	app.stack.push(CmdDeleteEntities.new(app.active_sketch_id, [id]))
	batch.seal()
	app.rebuild_snap_index()


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
