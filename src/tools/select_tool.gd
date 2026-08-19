class_name SelectTool
extends SketchTool
## Minimal M4 select tool: click selects the topmost entity (Ctrl toggles),
## dragging a point moves it, dragging a line moves both endpoints. Moves
## merge into one undo step per drag. Constraint re-solve arrives with M6/M7.

const HIT_PX := 6.0
const DEADZONE_PX := 4.0

enum Drag { NONE, PENDING, MOVE }
## Marquee (rubber-band) selection state (M20): a press on EMPTY space arms
## it; dragging past the deadzone opens the band. Fusion semantics: dragging
## left-to-right is a WINDOW select (only entities entirely inside), right-
## to-left is a CROSSING select (touching counts).
enum Marq { NONE, ARMED, ACTIVE }

var _drag := Drag.NONE
var _marq := Marq.NONE
var _marq_start_screen := Vector2.ZERO
var _marq_start := Vector2.ZERO      # world
var _marq_cur := Vector2.ZERO        # world
var _marq_add := false               # Ctrl/Shift held at press: add to selection
var _down_world := Vector2.ZERO
var _down_screen := Vector2.ZERO
var _move_points: Array[String] = []   # point entity ids being dragged
var _start := {}                       # id -> Vector2 at drag start
var _batch: CmdMergeBatch = null       # one undo step: drag + re-solve
var _label_drag := -1                  # dimension index whose label is dragged
var _label_start := Vector2.ZERO       # label_offset at drag start
var _label_down := Vector2.ZERO        # world pos at drag start
## Spline tangent-handle drag (M28): entity id, fit-point index, and which
## control was grabbed (+1 = out, -1 = the mirrored in control).
var _handle_entity := ""
var _handle_index := -1
var _handle_sign := 1.0
## The UNGRABBED side's tangent at drag start — an Alt-drag (QA §M28.4)
## moves only the grabbed side and must hold this one where it was.
var _handle_other := Vector2.ZERO
var _dim_fields := DimFields.new(["Value"])   # edit box for selected dimension
## Coalesced drag state: pointer_move records where the drag wants to be and
## `tick` applies it once per frame. See pointer_move for why.
var _pending := false
var _pending_world := Vector2.ZERO
## Points the current drag actually moves (drag group + rail companions from
## DragFilter) — what the follower solve pins.
var _last_pinned: Array = []
## The "sliding on rails" hint fires once per gesture, not per frame.
var _rail_hinted := false


func _init() -> void:
	id = "select"
	title = "Select"
	shortcut = KEY_V


## Seal the drag's merge batch and drop it if it absorbed nothing. An OPEN
## batch left on the stack silently swallows every later command into one
## undo step (the "several Ctrl+Z to unwind one drag" of QA §M19.8), and a
## sealed-but-empty one is a phantom step; both end here, at every path out
## of a drag (pointer-up, Esc, tool switch).
func _end_batch() -> void:
	if _batch == null:
		return
	_batch.seal()
	app.stack.drop_if_noop(_batch)
	_batch = null


func deactivate() -> void:
	_drag = Drag.NONE
	_pending = false
	_marq = Marq.NONE
	if app != null:
		app.set_live_gesture(false)
		_end_batch()
	clear_hover()


func cancel() -> bool:
	if _marq != Marq.NONE:
		_marq = Marq.NONE
		app.overlay.queue_redraw()
		return true
	if _handle_entity != "":
		_handle_entity = ""
		_handle_index = -1
		_end_batch()
		return true
	if _drag != Drag.NONE:
		_drag = Drag.NONE
		app.set_live_gesture(false)
		_end_batch()
		return true
	if app.selected_constraint >= 0:
		app.selected_constraint = -1
		app.overlay.queue_redraw()
		return true
	if not app.selection.is_empty():
		app.set_selection([])
		return true
	return false


func pointer_down(world: Vector2, screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	# Dimension labels and constraint badges sit above geometry.
	for h: Dictionary in app.dim_hits:
		if (h["rect"] as Rect2).has_point(screen):
			app.set_selection([])
			app.selected_constraint = int(h["index"])
			_dim_fields.reset()
			_label_drag = int(h["index"])
			_label_down = world
			_label_start = sketch().constraints[_label_drag].label_offset
			app.overlay.queue_redraw()
			return true
	for h: Dictionary in app.badge_hits:
		if (h["rect"] as Rect2).has_point(screen):
			app.set_selection([])
			app.selected_constraint = int(h["index"])
			app.overlay.queue_redraw()
			return true
	# Spline tangent handles of the selected spline sit above geometry (M28).
	var hh := _handle_hit(screen)
	if not hh.is_empty():
		_handle_entity = String(hh["entity"])
		_handle_index = int(hh["index"])
		_handle_sign = float(hh["sign"])
		var hsp := sketch().entity(_handle_entity) as SketchSpline
		_handle_other = Vector2.ZERO
		if hsp != null:
			_handle_other = hsp.in_tangent_at(sketch(), _handle_index) \
				if _handle_sign > 0.0 \
				else hsp.tangent_at(sketch(), _handle_index)
		_batch = CmdMergeBatch.new("Edit Handle", [])
		app.stack.push_no_merge(_batch)
		return true
	var sk := sketch()
	var hit := SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	if hit == "":
		# Arm a marquee; whether this was a band or a plain deselect-click is
		# decided by whether the pointer moves before it releases.
		_marq = Marq.ARMED
		_marq_start_screen = screen
		_marq_start = world
		_marq_cur = world
		_marq_add = e.ctrl_pressed or e.shift_pressed
		return true
	# Shift adds to the selection as well as Ctrl. Ctrl-click is the CAD
	# convention and Shift-click is the everything-else convention; users reach
	# for whichever their hands know, and there is no reason to accept only one.
	if e.ctrl_pressed or e.shift_pressed:
		var sel := app.selection.duplicate()
		if sel.has(hit):
			sel.erase(hit)
		else:
			sel.append(hit)
		app.set_selection(sel)
	elif not app.selection.has(hit):
		app.set_selection([hit])
	# Arm a potential drag with the points this hit controls. When the hit is
	# part of a MULTI-selection (a marquee-selected polygon, say), the whole
	# selection drags together — grabbing one edge of it and moving only that
	# edge is never what the gesture meant (QA §M29.6).
	_move_points.clear()
	_start.clear()
	var drag_ids: Array = [hit]
	if app.selection.size() > 1 and app.selection.has(hit):
		drag_ids = app.selection.duplicate()
	for did in drag_ids:
		var ent := sk.entity(String(did))
		if ent == null or sk.is_origin(String(did)):
			continue
		var refs: Array[String] = []
		if ent.kind() == "point":
			refs = [ent.id]
		else:
			refs = ent.point_refs()
		for pid in refs:
			var p := sk.point(pid)
			if p != null and not _start.has(pid):
				_move_points.append(pid)
				_start[pid] = p.pos
	_down_world = world
	_down_screen = screen
	# A FULLY CONSTRAINED point cannot be dragged — its position is already
	# determined, so there is nothing left for a drag to decide. Fusion refuses
	# the gesture outright, and it has to: allowing it means the drag and the
	# dimensions each demand a different position, the solver is handed a system
	# with no solution, and the sketch ends up mangled and reading "Conflicting
	# constraints" when the user did nothing wrong. Refusing keeps the drawing
	# intact and puts the reason in the status bar.
	if not _move_points.is_empty() and _all_constrained(_move_points):
		app.set_status_hint("Fully constrained — remove or edit a dimension to "
			+ "move this. (Drag refused so the sketch is not broken.)")
		_drag = Drag.NONE
		return true
	_drag = Drag.PENDING if not _move_points.is_empty() else Drag.NONE
	return true


## Are ALL of these points determined by the current constraints? Read from the
## DOF analysis the status bar already shows, so what blocks a drag is exactly
## what the user was told is fully constrained.
func _all_constrained(pids: Array) -> bool:
	var determined: Array = app.dof.get("constrained_points", [])
	if determined.is_empty():
		return false
	for pid in pids:
		if not determined.has(pid):
			return false
	return true


func pointer_move(world: Vector2, screen: Vector2, e: InputEventMouseMotion) -> bool:
	if _marq != Marq.NONE:
		if _marq == Marq.ARMED \
				and screen.distance_to(_marq_start_screen) > DEADZONE_PX:
			_marq = Marq.ACTIVE
		_marq_cur = world
		if _marq == Marq.ACTIVE:
			app.overlay.queue_redraw()
			return true
	# Pre-highlight what a click would pick, Fusion-style. Deliberately the
	# SAME hit test the click uses, so the highlight can never promise
	# something the click would not deliver. Skipped mid-drag, where the
	# cursor is committed to geometry it already grabbed.
	if _drag == Drag.NONE and _label_drag < 0:
		if update_hover(world, HIT_PX):
			app.overlay.queue_redraw()
	elif clear_hover():
		app.overlay.queue_redraw()
	if _handle_entity != "":
		var skh := sketch()
		var sp := skh.entity(_handle_entity) as SketchSpline
		if sp != null and _handle_index < sp.points.size():
			var fp := skh.point(sp.points[_handle_index])
			if fp != null:
				var t := (world - fp.pos) * 3.0 * _handle_sign
				# Plain drag: SYMMETRIC override (both sides mirror — also how
				# an Alt-kinked point is smoothed again). Alt-drag: only the
				# grabbed side moves; the other keeps its drag-start tangent.
				var to: Variant = t
				if e != null and e.alt_pressed:
					to = {"out": t, "in": _handle_other} if _handle_sign > 0.0 \
						else {"out": _handle_other, "in": (fp.pos - world) * 3.0}
				app.stack.push(CmdSetSplineHandle.new(app.active_sketch_id,
					_handle_entity, _handle_index, to))
				app.overlay.queue_redraw()
		return true
	if _label_drag >= 0:
		var sk := sketch()
		if _label_drag < sk.constraints.size():
			var edited := sk.constraints[_label_drag].duplicate_constraint()
			edited.label_offset = _label_start + (world - _label_down)
			var after: Array = sk.constraints.duplicate()
			after[_label_drag] = edited
			app.stack.push(CmdSetConstraints.new(app.active_sketch_id,
				sk.constraints, after))
		return true
	if _drag == Drag.PENDING \
			and screen.distance_to(_down_screen) > DEADZONE_PX:
		_drag = Drag.MOVE
		_rail_hinted = false
		_last_pinned = _move_points.duplicate()
		# Heavy derived work (DOF analysis, projection refresh) pauses for
		# the duration of the drag — it re-runs once at pointer_up.
		app.set_live_gesture(true)
		app.rebuild_snap_index(_moving_entity_ids())
		# The whole gesture — every move + every constraint re-solve — is
		# one sealed undo step.
		_batch = CmdMergeBatch.new("Drag", [])
		app.stack.push_no_merge(_batch)
	if _drag != Drag.MOVE:
		return false
	# Record the target and let _process apply it ONCE this frame. Motion
	# events arrive several times per displayed frame, and each one used to run
	# the whole pipeline: push a move command, which fires stack.changed, which
	# rebuilds the snap index, re-runs the DOF analysis and re-rasterizes the
	# canvas — then a full constraint solve (up to MAX_ROUNDS sweeps over every
	# constraint) on top. Everything but the last of those is overwritten
	# before it is ever seen, so it was pure heat: one core pegged and the CPU
	# ~20 °C hotter for a result identical to solving once per frame.
	_pending_world = world
	_pending = true
	return true


## Apply at most one drag update per frame — see `pointer_move`. The undo
## semantics are unchanged: every push still lands in the same sealed
## CmdMergeBatch, so the whole gesture remains one step.
func tick() -> void:
	if not _pending or _drag != Drag.MOVE:
		return
	_pending = false
	_apply_drag(_pending_world)


func _apply_drag(world: Vector2) -> void:
	var delta := world - _down_world
	# Snap the DRAGGED point (single-point drags) so moves land on targets.
	if _move_points.size() == 1:
		var tol := SnapEngine.TOL_PX / view().zoom()
		var grid := view().grid_step_mm() if app.snap.grid_enabled else 0.0
		var target: Vector2 = (_start[_move_points[0]] as Vector2) + delta
		delta = app.snap.snap_point(target, tol, grid)["pos"] \
			- (_start[_move_points[0]] as Vector2)
	# Per-DOF projection (M17): the cursor asks for `delta` from the drag's
	# start; what actually moves is that request projected onto the freedoms
	# the constraints leave open — so constrained geometry slides on rails
	# and geometry the user never touched is not yanked around.
	var sk := sketch()
	var desired := {}
	for pid in _move_points:
		desired[pid] = (_start[pid] as Vector2) + delta - sk.point(pid).pos
	var dplan := DragFilter.plan(sk, _move_points, desired)
	if not bool(dplan["allowed"]):
		app.set_status_hint("Held by constraints — no free direction to move "
			+ "this. Delete or edit a constraint/dimension first.")
		return
	if bool(dplan["restricted"]) and not _rail_hinted:
		app.set_status_hint("Sliding along the remaining freedom — "
			+ "constraints hold the other directions.")
		_rail_hinted = true
	var moved: Dictionary = dplan["moves"]
	if moved.is_empty():
		return
	var targets := {}
	for pid: String in moved:
		targets[pid] = sk.point(pid).pos + (moved[pid] as Vector2)
	app.stack.push(CmdMovePoints.new(app.active_sketch_id, targets))
	_last_pinned = targets.keys()
	# Mid-gesture, the DragFilter plan already moved every point that should
	# move — a free follower solve here would spread its microscopic residual
	# onto geometry the plan deliberately held still. So the mid-drag solve
	# pins ALL points and only lets radii adjust (a circle whose centre is
	# sliding under a tangency); it runs on the worker thread (M16). The
	# final exact solve happens synchronously in pointer_up before the batch
	# seals, with only the plan's movers pinned.
	var all_points: Array = []
	for e in sk.entities():
		if e.kind() == "point":
			all_points.append(e.id)
	app.solve_followers_async(all_points)


func pointer_up(_world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _marq == Marq.ACTIVE:
		_apply_marquee()
		_marq = Marq.NONE
		app.overlay.queue_redraw()
		return true
	if _marq == Marq.ARMED:
		# Never moved: this was a plain click on empty space — deselect
		# (unless it was an additive click, which just misses).
		if not _marq_add:
			app.set_selection([])
		_marq = Marq.NONE
		return true
	if _handle_entity != "":
		_handle_entity = ""
		_handle_index = -1
		_end_batch()
		return true
	if _label_drag >= 0:
		_label_drag = -1
		return true
	if _drag == Drag.MOVE:
		# Flush the last coalesced move BEFORE sealing, or the drag ends
		# wherever the final frame happened to land rather than where the
		# button came up.
		if _pending:
			_pending = false
			_apply_drag(_pending_world)
		# The gesture's LAST solve is synchronous: outstanding threaded work
		# is cancelled (its result would land after the batch seals) and the
		# final radius cleanup runs here, inside the batch. Points stay
		# pinned even now — the DragFilter plan placed every point, and a
		# free settle would smear its sub-micron residual onto geometry the
		# whole gesture was careful never to touch.
		if app.threaded_solver != null:
			app.threaded_solver.cancel()
		var sk_up := sketch()
		if sk_up != null:
			var all_pts: Array = []
			for e_up in sk_up.entities():
				if e_up.kind() == "point":
					all_pts.append(e_up.id)
			app.solve_followers(all_pts)
		_end_batch()
		app.rebuild_snap_index()
		app.set_live_gesture(false)
	_pending = false
	_drag = Drag.NONE
	return true


## Selected dimension: typing edits its value, Enter applies.
func key_input(e: InputEventKey) -> bool:
	var sk := sketch()
	if sk == null or app.selected_constraint < 0 \
			or app.selected_constraint >= sk.constraints.size():
		return false
	if not sk.constraints[app.selected_constraint].is_dimensional():
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		if _dim_fields.has_text(0):
			var batch := CmdMergeBatch.new("Edit Dimension", [])
			app.stack.push_no_merge(batch)
			app.set_dimension_value(app.selected_constraint, _dim_fields.texts[0])
			batch.seal()
			_dim_fields.reset()
		return true
	return _dim_fields.key_input(e)


## Select everything the band covers. Window (L->R): entirely inside;
## crossing (R->L): touching. The sketch origin is scaffolding, not
## geometry — a band never selects it.
func _apply_marquee() -> void:
	var sk := sketch()
	if sk == null:
		return
	var crossing := _marq_cur.x < _marq_start.x
	var lo := Vector2(minf(_marq_start.x, _marq_cur.x),
		minf(_marq_start.y, _marq_cur.y))
	var hi := Vector2(maxf(_marq_start.x, _marq_cur.x),
		maxf(_marq_start.y, _marq_cur.y))
	var rect := Rect2(lo, hi - lo)
	var sel: Array = app.selection.duplicate() if _marq_add else []
	for e in sk.entities():
		if e.id == sk.origin_id() or sel.has(e.id):
			continue
		if SketchGeometry.entity_in_rect(sk, e, rect, crossing):
			sel.append(e.id)
	app.set_selection(sel)


func draw_overlay(overlay: Control) -> void:
	if _marq == Marq.ACTIVE:
		var v := view()
		var a := v.world_to_screen(_marq_start)
		var b := v.world_to_screen(_marq_cur)
		var r := Rect2(a, b - a).abs()
		var crossing := _marq_cur.x < _marq_start.x
		# Fusion's cue: window select fills blue with a solid edge, crossing
		# select fills green with a dashed edge.
		var fill := Color(0.35, 0.55, 0.9, 0.12) if not crossing \
			else Color(0.4, 0.85, 0.5, 0.12)
		var edge := Color(0.55, 0.7, 1.0, 0.9) if not crossing \
			else Color(0.5, 0.9, 0.6, 0.9)
		overlay.draw_rect(r, fill)
		if crossing:
			for seg in _dashed_rect(r):
				overlay.draw_line(seg[0], seg[1], edge, 1.0)
		else:
			overlay.draw_rect(r, edge, false, 1.0)
	var sk := sketch()
	if sk == null:
		return
	# Tangent handles of the selected spline (M28): a thin bar through each
	# fit point with a square at each control. Dragging one overrides the
	# auto tangent (both sides mirror; Alt-drag moves one side only). With a
	# single FIT POINT selected, that point's handle shows too (QA §M28.4).
	var hsel := _spline_selection()
	if not hsel.is_empty():
		var sel_sp: SketchSpline = hsel["sp"]
		var only := int(hsel["only"])
		var v2 := view()
		var hcol := Color(0.9, 0.75, 0.35, 0.95)
		for i in sel_sp.points.size():
			if only >= 0 and i != only:
				continue
			var fp := sk.point(sel_sp.points[i])
			if fp == null:
				continue
			var t := sel_sp.tangent_at(sk, i)
			var tin := sel_sp.in_tangent_at(sk, i)
			if t.length() < 1e-9 and tin.length() < 1e-9:
				continue
			var a := v2.world_to_screen(fp.pos + t / 3.0)
			var b := v2.world_to_screen(fp.pos - tin / 3.0)
			var m := v2.world_to_screen(fp.pos)
			overlay.draw_line(b, m, Color(hcol.r, hcol.g, hcol.b, 0.5), 1.0)
			overlay.draw_line(m, a, Color(hcol.r, hcol.g, hcol.b, 0.5), 1.0)
			overlay.draw_rect(Rect2(a - Vector2(3, 3), Vector2(6, 6)), hcol)
			overlay.draw_rect(Rect2(b - Vector2(3, 3), Vector2(6, 6)), hcol)
	if app.selected_constraint < 0 or not _dim_fields.has_text(0):
		return
	if app.selected_constraint >= sk.constraints.size():
		return
	var c := sk.constraints[app.selected_constraint]
	if not c.is_dimensional():
		return
	var at := view().world_to_screen(
		ConstraintOverlay.anchor_of(sk, c) + c.label_offset) + Vector2(0, 20)
	_dim_fields.draw(overlay, at, app.doc.display_unit, [c.value])


## What spline the handle overlay serves: the single selected spline
## ({"sp": .., "only": -1}), or the spline owning the single selected FIT
## POINT ({"sp": .., "only": index}); {} otherwise.
func _spline_selection() -> Dictionary:
	if app.selection.size() != 1:
		return {}
	var sk := sketch()
	if sk == null:
		return {}
	var e := sk.entity(app.selection[0])
	if e is SketchSpline:
		return {"sp": e, "only": -1}
	if e != null and e.kind() == "point":
		for cand in sk.entities():
			if cand is SketchSpline:
				var idx := (cand as SketchSpline).points.find(e.id)
				if idx >= 0:
					return {"sp": cand, "only": idx}
	return {}


## Which handle square (of the selection's spline) is under `screen`, if
## any: {entity, index, sign} — sign +1 for the out control, -1 for the in.
func _handle_hit(screen: Vector2) -> Dictionary:
	var hsel := _spline_selection()
	if hsel.is_empty():
		return {}
	var sp: SketchSpline = hsel["sp"]
	var only := int(hsel["only"])
	var sk := sketch()
	var v := view()
	for i in sp.points.size():
		if only >= 0 and i != only:
			continue
		var fp := sk.point(sp.points[i])
		if fp == null:
			continue
		var t := sp.tangent_at(sk, i)
		var tin := sp.in_tangent_at(sk, i)
		if t.length() > 1e-9 \
				and v.world_to_screen(fp.pos + t / 3.0).distance_to(screen) <= 7.0:
			return {"entity": sp.id, "index": i, "sign": 1.0}
		if tin.length() > 1e-9 \
				and v.world_to_screen(fp.pos - tin / 3.0).distance_to(screen) <= 7.0:
			return {"entity": sp.id, "index": i, "sign": -1.0}
	return {}


## The four rect edges chopped into short dashes (screen px).
static func _dashed_rect(r: Rect2) -> Array:
	var corners: Array = [r.position, r.position + Vector2(r.size.x, 0),
		r.position + r.size, r.position + Vector2(0, r.size.y)]
	var out: Array = []
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var run := a.distance_to(b)
		if run < 1e-3:
			continue
		var dir := (b - a) / run
		var t := 0.0
		while t < run:
			var t2 := minf(t + 5.0, run)
			out.append([a + dir * t, a + dir * t2])
			t = t2 + 4.0
	return out


func _moving_entity_ids() -> Array:
	# Exclude dragged points AND entities owning them from snap targets.
	var out := _move_points.duplicate()
	var sk := sketch()
	for e in sk.entities():
		if e.kind() == "point":
			continue
		for pid in e.point_refs():
			if _move_points.has(pid):
				out.append(e.id)
				break
	return out
