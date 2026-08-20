extends SceneTree

# QA volume 2 fixes (§M28–§M29):
# A. Asymmetric spline handles: {"out","in"} overrides drive the two bezier
#    sides independently; serialization + PatternLib transforms carry them.
# B. DragFilter never recruits a SYMMETRY axis: dragging a mirrored point
#    moves its partner, not the mirror line (§M28.8).
# C. DimFields kinds: counts show as whole numbers, angles in degrees — not
#    mm run through the inch converter (§M29.1/§M29.4).
# D. Select tool: handles show for a selected FIT POINT; Alt-drag moves one
#    handle side; a plain drag re-symmetrizes (§M28.4).
# E. Dragging an entity of a MULTI-selection moves the whole selection
#    (§M29.6 — the marquee-selected polygon).
# F. Wheel zoom works under the orthographic projection (§M27.4); the eye
#    keeps its standoff so the near plane cannot slice the grid (round 2).
# G. Deselecting a body keeps its per-body color (§M27 issue note).
# H. Rect Pattern hides the spacing field of a 1-count axis (§M29.1 rd 2).
# I. Ghost/preview ink and dialog backdrops follow the theme (§M26.5 rd 2).

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _idle() -> void:
	await process_frame
	await process_frame


func _fail(msg: String) -> bool:
	push_error("m29_qa_fixes: " + msg)
	return false


func _pt(sk: Sketch, p: Vector2) -> SketchPoint:
	var e := SketchPoint.make(p)
	e.id = sk.next_id()
	sk.add(e)
	return e


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


## LMB drag world a -> b through the tool manager, alt optionally held.
func _drag(a: Vector2, b: Vector2, alt := false) -> void:
	var v: SketchView = _root.sketch_view
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.alt_pressed = alt
	_root.tools.handle_pointer_down(a, v.world_to_screen(a), down)
	var mm := InputEventMouseMotion.new()
	mm.alt_pressed = alt
	# Two motions: the first leaves the deadzone, the second lands the target.
	var mid := a.lerp(b, 0.5)
	_root.tools.handle_pointer_move(mid, v.world_to_screen(mid), mm)
	_root.tools.handle_tick()
	_root.tools.handle_pointer_move(b, v.world_to_screen(b), mm)
	_root.tools.handle_tick()
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.alt_pressed = alt
	_root.tools.handle_pointer_up(b, v.world_to_screen(b), up)


func _run() -> bool:
	var T := SketchConstraint.Type

	# --- A. asymmetric handle math + serialization + pattern transforms ----
	var msk := Sketch.new()
	var p0 := _pt(msk, Vector2(0, 0))
	var p1 := _pt(msk, Vector2(20, 10))
	var p2 := _pt(msk, Vector2(40, 0))
	var msp := SketchSpline.make([p0.id, p1.id, p2.id])
	msp.id = msk.next_id()
	msk.add(msp)
	msp.handles[1] = {"out": Vector2(12, 0), "in": Vector2(0, 12)}
	if msp.tangent_at(msk, 1) != Vector2(12, 0):
		return _fail("A: out tangent ignores the asymmetric override")
	if msp.in_tangent_at(msk, 1) != Vector2(0, 12):
		return _fail("A: in tangent ignores the asymmetric override")
	var s0 := msp.span(msk, 0)
	var s1 := msp.span(msk, 1)
	if (s0[2] as Vector2).distance_to(p1.pos - Vector2(0, 12) / 3.0) > 1e-9:
		return _fail("A: span 0 in-control not driven by the in tangent")
	if (s1[1] as Vector2).distance_to(p1.pos + Vector2(12, 0) / 3.0) > 1e-9:
		return _fail("A: span 1 out-control not driven by the out tangent")
	var rt := Sketch.from_dict(msk.to_dict())
	var rsp: SketchSpline = null
	for e in rt.entities():
		if e.kind() == "spline":
			rsp = e
	if rsp == null or not (rsp.handles[1] is Dictionary):
		return _fail("A: asymmetric override lost in serialization")
	if (rsp.handles[1]["out"] as Vector2).distance_to(Vector2(12, 0)) > 1e-9 \
			or (rsp.handles[1]["in"] as Vector2).distance_to(Vector2(0, 12)) > 1e-9:
		return _fail("A: asymmetric override corrupted in serialization")
	var rot := Transform2D(PI / 2.0, Vector2(5, 5))
	var dup := PatternLib.duplicate_transformed(msk, [msp.id], rot)
	var dsp: SketchSpline = null
	for e in dup["entities"]:
		if (e as SketchEntity).kind() == "spline":
			dsp = e
	if dsp == null or not (dsp.handles[1] is Dictionary):
		return _fail("A: pattern copy dropped the asymmetric override")
	if (dsp.handles[1]["out"] as Vector2).distance_to(
			rot.basis_xform(Vector2(12, 0))) > 1e-6:
		return _fail("A: pattern copy did not rotate the out tangent")

	# --- B. SYMMETRY axis is never dragged along ---------------------------
	var ssk := Sketch.new()
	var sp_ := _pt(ssk, Vector2(10, 5))
	var sq := _pt(ssk, Vector2(-10, 5))
	var aa := _pt(ssk, Vector2(0, -20))
	var ab := _pt(ssk, Vector2(0, 20))
	var axis := SketchLine.make(aa.id, ab.id)
	axis.id = ssk.next_id()
	axis.construction = true
	ssk.add(axis)
	var ops: Array[String] = [sp_.id, sq.id, axis.id]
	ssk.constraints.append(SketchConstraint.make(T.SYMMETRY, ops))
	var plan := DragFilter.plan(ssk, [sp_.id], {sp_.id: Vector2(5, 0)})
	if not bool(plan["allowed"]):
		return _fail("B: symmetric point drag refused")
	var moves: Dictionary = plan["moves"]
	for pid: String in moves:
		if (pid == aa.id or pid == ab.id) \
				and (moves[pid] as Vector2).length() > 1e-3:
			return _fail("B: the drag moved the mirror axis (%s by %s)"
				% [pid, str(moves[pid])])
	if not moves.has(sp_.id):
		return _fail("B: dragged point did not move")
	if not moves.has(sq.id) \
			or ((moves[sq.id] as Vector2) - Vector2(-5, 0)).length() > 0.5:
		return _fail("B: mirrored partner did not follow (moves: %s)"
			% str(moves))

	# --- C. DimFields kinds ------------------------------------------------
	var df := DimFields.new(["Count", "Angle", "Len"], ["int", "deg", "len"])
	if df.format_live(0, 4.0, UnitConverter.Unit.IN) != "4":
		return _fail("C: count field shows %s, not a whole number"
			% df.format_live(0, 4.0, UnitConverter.Unit.IN))
	if df.format_live(1, 360.0, UnitConverter.Unit.IN) != "360°":
		return _fail("C: angle field shows %s, not degrees"
			% df.format_live(1, 360.0, UnitConverter.Unit.IN))
	if not df.format_live(2, 25.4, UnitConverter.Unit.IN).contains("1"):
		return _fail("C: length field lost its unit conversion")
	df.texts[0] = "6"
	if absf(df.value_num(0) - 6.0) > 1e-9:
		return _fail("C: typed count does not parse as a raw number")

	# --- D. select tool: handles on a selected fit point; Alt-drag ---------
	_root.size = Vector2(1280, 800)
	_root.create_sketch("XY")
	var sk: Sketch = _root.active_sketch()
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	_root.tools.set_active("spline")
	var fits: Array = [Vector2(5, 3), Vector2(25, 21), Vector2(50, -2),
		Vector2(75, 13)]
	for f in fits:
		_click(f)
	if not _root.tools.handle_commit():
		return _fail("D: spline commit failed")
	var sp: SketchSpline = null
	for e in sk.entities():
		if e.kind() == "spline":
			sp = e
	if sp == null:
		return _fail("D: no spline drawn")
	var sel := _root.tools.get_tool("select") as SelectTool
	_root.tools.set_active("select")
	_root.set_selection([String(sp.points[1])])
	var hsel: Dictionary = sel._spline_selection()
	if hsel.is_empty() or hsel["sp"] != sp or int(hsel["only"]) != 1:
		return _fail("D: selecting a fit point does not surface its handles")
	var fp := sk.point(sp.points[1])
	var t_out := sp.tangent_at(sk, 1)
	var t_in0 := sp.in_tangent_at(sk, 1)
	# Alt-drag the OUT square: only the out side moves; in keeps its tangent.
	var grab := fp.pos + t_out / 3.0
	var target := fp.pos + Vector2(8, -6)
	_drag(grab, target, true)
	if not (sp.handles[1] is Dictionary):
		return _fail("D: Alt-drag did not store an asymmetric override")
	if (sp.handles[1]["out"] as Vector2).distance_to(
			(target - fp.pos) * 3.0) > 1e-6:
		return _fail("D: Alt-drag out tangent wrong")
	if (sp.handles[1]["in"] as Vector2).distance_to(t_in0) > 1e-6:
		return _fail("D: Alt-drag disturbed the untouched in side")
	# Plain drag the same square: back to one SYMMETRIC override.
	var grab2 := fp.pos + (sp.tangent_at(sk, 1)) / 3.0
	var target2 := fp.pos + Vector2(-9, 3)
	_drag(grab2, target2, false)
	if not (sp.handles[1] is Vector2):
		return _fail("D: plain drag did not re-symmetrize the handle")
	# One undo unwinds the whole gesture.
	_root.stack.undo()
	if not (sp.handles[1] is Dictionary):
		return _fail("D: handle drag was not one undo step")
	_root.set_selection([])

	# --- E. dragging one entity of a multi-selection moves all of it -------
	_root.tools.set_active("rect")
	_click(Vector2(-60, -40))
	_click(Vector2(-30, -20))
	var rect_pts: Array = []
	var rect_ids: Array = []
	for e in sk.entities():
		if sk.is_origin(e.id) or e.kind() == "spline":
			continue
		if sp.points.has(e.id):
			continue
		rect_ids.append(e.id)
		if e.kind() == "point":
			rect_pts.append(e.id)
	if rect_pts.size() != 4:
		return _fail("E: expected 4 rect corners, found %d" % rect_pts.size())
	var before := {}
	for pid in rect_pts:
		before[pid] = sk.point(String(pid)).pos
	_root.tools.set_active("select")
	_root.set_selection(rect_ids)
	var delta := Vector2(7, 5)
	_drag(Vector2(-60, -40), Vector2(-60, -40) + delta)
	for pid in rect_pts:
		var moved: Vector2 = sk.point(String(pid)).pos - (before[pid] as Vector2)
		if (moved - delta).length() > 0.5:
			return _fail("E: corner %s moved %s, wanted the whole selection "
				% [pid, str(moved)] + "to move %s" % str(delta))
	await _idle()

	# --- G. per-body color survives deselection ---------------------------
	var fid2 := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(100, 100))
	_click(Vector2(140, 130))
	_root.finish_sketch()
	await _idle()
	var eid := _root.extrude(fid2, Vector2(120, 115), 10.0)
	if eid == "":
		return _fail("G: extrude refused")
	await _idle()
	await _idle()
	if _root.set_body_color(eid, Color(0.9, 0.2, 0.2)) != "":
		return _fail("G: set_body_color refused")
	await _idle()
	await _idle()
	_root.world.set_selected_body(eid)
	_root.world.set_selected_body("")
	var mi: MeshInstance3D = _root.world._body_mesh(eid)
	if mi == null:
		return _fail("G: no body mesh after extrude")
	var mat := mi.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or mat.albedo_color.r < 0.85 or mat.albedo_color.g > 0.3:
		return _fail("G: deselecting wiped the per-body color (got %s)"
			% str(mat.albedo_color if mat != null else null))

	# --- F. ortho zoom actually zooms; the eye keeps its standoff ----------
	var rig: OrbitCamera = _root.rig
	rig.set_projection_ortho(true)
	var vh0 := rig.view_height_mm()
	rig.zoom(1.0 / 1.1)
	if absf(rig.view_height_mm() - vh0 / 1.1) > vh0 * 0.01:
		return _fail("F: ortho wheel zoom left the view height at %f (was %f)"
			% [rig.view_height_mm(), vh0])
	for k in 20:
		rig.zoom(1.0 / 1.1)   # zoom far in: distance must not collapse
	if rig.distance < rig.camera.size * OrbitCamera.ORTHO_STANDOFF * 0.99:
		return _fail("F: ortho eye crept in to %f (size %f) — near plane "
			% [rig.distance, rig.camera.size] + "would slice the grid")
	rig.set_projection_ortho(false)

	# --- H. rect pattern hides the spacing of a 1-count axis ---------------
	_root.create_sketch("XY")
	var sk_h: Sketch = _root.active_sketch()
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(200, 200))
	_click(Vector2(230, 220))
	var ids_h: Array = []
	for e in sk_h.entities():
		if not sk_h.is_origin(e.id):
			ids_h.append(e.id)
	var rp := _root.tools.get_tool("rect_pattern") as RectPatternTool
	_root.set_selection(ids_h)
	_root.tools.set_active("rect_pattern")
	rp._params()   # defaults: Cols=2, Rows=1
	if not bool(rp._fields.enabled[2]):
		return _fail("H: Spacing X hidden although Cols=2")
	if bool(rp._fields.enabled[3]):
		return _fail("H: Spacing Y offered although Rows=1")
	rp._fields.texts[1] = "3"
	rp._params()
	if not bool(rp._fields.enabled[3]):
		return _fail("H: Spacing Y still hidden after Rows=3")
	rp._fields.active = 3
	rp._fields.texts[1] = "1"
	rp._params()
	if bool(rp._fields.enabled[3]) or rp._fields.active == 3:
		return _fail("H: disabling did not move the cursor off Spacing Y")
	_root.tools.set_active("select")
	_root.set_selection([])
	_root.finish_sketch()
	await _idle()

	# --- I. ghost ink + dialog backdrops follow the theme ------------------
	# M36: ink comes from the theme file, so switch themes for real.
	var was_theme := ThemeService.theme_id
	_root.set_dark_theme(true)
	var g_dark := SketchTool.ghost(0.5)
	_root.set_dark_theme(false)
	var g_light := SketchTool.ghost(0.5)
	_root.set_theme_id(was_theme)
	if g_dark.get_luminance() < 0.5 or g_light.get_luminance() > 0.5:
		return _fail("I: ghost ink does not flip with the theme (dark %s / "
			% str(g_dark) + "light %s)" % str(g_light))
	if _root.get_node_or_null("Backdrop") == null:
		return _fail("I: no themed backdrop behind the shelf")
	_root._open_prefs_dialog()
	await _idle()
	var prefs: Window = _root.get_node("PrefsDialog")
	if prefs.get_node_or_null("ThemeBackdrop") == null:
		return _fail("I: prefs dialog has no themed backdrop")
	if prefs.get_child(0).name != "ThemeBackdrop":
		return _fail("I: dialog backdrop is not the bottom child")
	prefs.hide()

	print("M29_QA_FIXES OK: asymmetric handles, symmetry-axis hold, ",
		"field kinds, point-selected handles + Alt drag, group drag, ",
		"ortho zoom + standoff, body color, 1-count spacing, themed ghosts")
	return true
