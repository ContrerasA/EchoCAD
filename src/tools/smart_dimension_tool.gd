class_name SmartDimensionTool
extends SketchTool
## Fusion's Smart Dimension (D): the dimension type is inferred from what
## you pick — two points -> Distance; a line -> its length; two parallel
## lines -> gap; two angled lines -> Angle; circle -> Diameter; arc ->
## Radius; point + line -> point-line distance. After the pick(s), the
## label follows the cursor; a click PARKS it (label_offset) and creates
## the dimension at its measured value; typing then Enter drives it to the
## typed value/expression — pick, park, and type are ONE undo step.

const HIT_PX := 6.0

var _picks: Array[String] = []
var _pending := -1               # SketchConstraint.Type or -1
var _pending_ops: Array[String] = []
var _preview := Vector2.ZERO
var _hover := false
## Open batch between park and value-commit (typing joins the same step).
var _batch: CmdMergeBatch = null
var _parked_index := -1
## "x"/"y" while the cursor hovers an ORIGIN axis and no entity is closer.
## Clicking it materialises the axis as a pinned construction line (origin ->
## fixed far point) so the ordinary line/line and point/line dimensions apply
## — e.g. a part edge's distance from the Y axis. Created inside the
## dimension's own undo step and reused if one already exists.
var _hover_axis := ""
var _axis_created := false
var _fields := DimFields.new(["Value"])


func _init() -> void:
	id = "dimension"
	title = "Dimension"
	shortcut = KEY_D


func activate() -> void:
	_reset()


func deactivate() -> void:
	_seal()
	_reset()


func _reset() -> void:
	_picks.clear()
	_pending = -1
	_pending_ops.clear()
	_hover = false
	_hover_axis = ""
	_axis_created = false
	_parked_index = -1
	_fields.reset()


func _seal() -> void:
	if _batch != null:
		_batch.seal()
		_batch = null


func cancel() -> bool:
	if _parked_index >= 0 or not _picks.is_empty() or _hover:
		if _axis_created and _parked_index < 0 and _batch != null:
			# Axis line was minted for a dimension that never got parked —
			# take it back out rather than leaving stray construction.
			_batch.seal()
			_batch = null
			app.stack.undo()
		_seal()
		_reset()
		return true
	return false


func commit() -> bool:
	return _apply_typed()


func key_input(e: InputEventKey) -> bool:
	if _parked_index < 0:
		return false
	if e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
		return _apply_typed()
	return _fields.key_input(e)


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	_preview = world
	_hover = true
	# Pre-highlight what the next pick would take. Dimensioning is a picking
	# tool, so it needs the same feedback Select gives — without it you click to
	# find out what you hit, which is the wrong order for a measuring tool.
	# Suppressed once the label is parked: at that point clicks type a value
	# rather than pick geometry, so highlighting would promise the wrong thing.
	_hover_axis = ""
	if _parked_index >= 0:
		clear_hover()
	else:
		update_hover(world, HIT_PX)
		if hover_id == "" and _picks.size() < 2:
			var tol := HIT_PX / view().zoom()
			if absf(world.y) <= tol:
				_hover_axis = "x"
			elif absf(world.x) <= tol:
				_hover_axis = "y"
	return true


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	if _parked_index >= 0:
		# Clicking elsewhere finishes the typing session.
		_apply_typed()
		return true
	var hit := SketchGeometry.entity_at(sk, world, HIT_PX / view().zoom())
	if hit == "" and _picks.size() < 2:
		pointer_move(world, _screen, null)
		if _hover_axis != "":
			hit = _axis_line(sk, _hover_axis)
	if hit != "" and not _picks.has(hit) and _picks.size() < 2:
		# Picking another entity refines the inference (line -> line+line
		# becomes angle/gap); clicking empty space parks.
		_picks.append(hit)
		_infer(sk)
		return true
	if _pending >= 0:
		_park(world)
		return true
	return true


## Decide the dimension type from the picks so far (or wait for more).
func _infer(sk: Sketch) -> void:
	var T := SketchConstraint.Type
	var kinds: Array = []
	for id_ in _picks:
		kinds.append(sk.entity(id_).kind())
	_pending = -1
	_pending_ops.clear()
	if kinds == ["circle"]:
		_pending = T.DIAMETER
		_pending_ops = _picks.duplicate()
	elif kinds == ["arc"]:
		_pending = T.RADIUS
		_pending_ops = _picks.duplicate()
	elif kinds == ["line"]:
		# Wait: a second pick may turn this into angle/gap. The line's own
		# length dimension is chosen when the user parks directly.
		var l := sk.entity(_picks[0]) as SketchLine
		_pending = T.DISTANCE
		_pending_ops = [l.p0, l.p1]
	elif kinds == ["point", "point"]:
		_pending = T.DISTANCE
		_pending_ops = _picks.duplicate()
	elif kinds == ["line", "line"]:
		var d1 := _line_dir(sk, _picks[0])
		var d2 := _line_dir(sk, _picks[1])
		if absf(d1.cross(d2)) < 0.02:
			_pending = T.LINE_DIST
		else:
			_pending = T.ANGLE
		_pending_ops = _picks.duplicate()
	elif kinds.has("point") and kinds.has("line") and kinds.size() == 2:
		_pending = T.POINT_LINE_DIST
		_pending_ops.clear()
		for id_ in _picks:
			if sk.entity(id_).kind() == "point":
				_pending_ops.append(id_)
		for id_ in _picks:
			if sk.entity(id_).kind() == "line":
				_pending_ops.append(id_)
	elif kinds.size() >= 2:
		_reset()   # unsupported combo — start over


## Entity id of a construction line lying along the X or Y origin axis —
## reused when one exists (Mirror mints the same kind), otherwise created as
## origin -> FIXED far point inside the dimension's undo batch.
func _axis_line(sk: Sketch, which: String) -> String:
	var o := sk.origin_id()
	for e in sk.entities():
		var l := e as SketchLine
		if l == null or not l.construction:
			continue
		if l.p0 != o and l.p1 != o:
			continue
		var far := sk.point(l.p1 if l.p0 == o else l.p0)
		if far == null:
			continue
		var on_axis := absf(far.pos.y) < 1e-6 if which == "x" else absf(far.pos.x) < 1e-6
		if on_axis and far.pos.length() > 1e-6:
			return l.id
	var reach := 50.0
	for e in sk.entities():
		if e.kind() == "point":
			reach = maxf(reach, (e as SketchPoint).pos.length() * 1.5)
	var far := SketchPoint.make(
		Vector2(reach, 0.0) if which == "x" else Vector2(0.0, reach))
	far.id = sk.next_id()
	var axis := SketchLine.make(o, far.id)
	axis.id = sk.next_id()
	axis.construction = true
	var fix_ops: Array[String] = [far.id]
	var cons: Array = [SketchConstraint.make(SketchConstraint.Type.FIX, fix_ops)]
	if _batch == null:
		_batch = CmdMergeBatch.new("Dimension", [])
		app.stack.push_no_merge(_batch)
	app.stack.push(CmdAddEntities.new(app.active_sketch_id, [far, axis], cons))
	_axis_created = true
	return axis.id


func _line_dir(sk: Sketch, id_: String) -> Vector2:
	var l := sk.entity(id_) as SketchLine
	return (sk.point(l.p1).pos - sk.point(l.p0).pos).normalized()


## Second pick may re-infer before parking (line -> line+line).
func pointer_up(_world: Vector2, _screen: Vector2, _e: InputEventMouseButton) -> bool:
	return false


func _park(world: Vector2) -> void:
	var sk := sketch()
	var t := _pending as SketchConstraint.Type
	var c := SketchConstraint.make(t, _pending_ops)
	c.value = ConstraintRules.measured_value(sk, t, _pending_ops)
	c.label_offset = world - _anchor_world(sk, c)
	if _batch == null:   # an axis pick may already have opened it
		_batch = CmdMergeBatch.new("Dimension", [])
		app.stack.push_no_merge(_batch)
	var after: Array = sk.constraints.duplicate()
	after.append(c)
	app.stack.push(CmdSetConstraints.new(app.active_sketch_id,
		sk.constraints, after))
	app.solve_followers()
	_parked_index = sk.constraints.size() - 1
	_fields.reset()


func _anchor_world(sk: Sketch, c: SketchConstraint) -> Vector2:
	return DimensionOverlay.label_anchor(sk, c)


func _apply_typed() -> bool:
	if _parked_index < 0:
		return false
	if _fields.has_text(0):
		app.set_dimension_value(_parked_index, _fields.texts[0])
	_seal()
	_reset()
	return true


## While picking a line-line pair, the FIRST line pick must still allow a
## second entity pick instead of parking. Handled by: after one line pick,
## clicking ON another entity re-infers; clicking empty space parks.
func draw_overlay(overlay: Control) -> void:
	if not _hover:
		return
	var v := view()
	var sk := sketch()
	for id_ in _picks:
		var e := sk.entity(id_)
		if e == null:
			continue
		var rep := ConstraintOverlay.anchor_of(sk,
			SketchConstraint.make(SketchConstraint.Type.FIX, [id_]))
		overlay.draw_circle(v.world_to_screen(rep), 3.0, Color(1.0, 0.85, 0.3))
	if _parked_index >= 0:
		_fields.draw(overlay, v.world_to_screen(_preview) + Vector2(0, 24),
			app.doc.display_unit, [])
		return
	if _hover_axis != "":
		# Pre-highlight the origin axis a click would pick.
		var span := 1.0e5
		var a := Vector2(-span, 0.0) if _hover_axis == "x" else Vector2(0.0, -span)
		overlay.draw_line(v.world_to_screen(a), v.world_to_screen(-a),
			ThemeService.col("hover"), 2.0)
	if _pending >= 0:
		# Live preview: value follows the cursor until parked.
		var t := _pending as SketchConstraint.Type
		var c := SketchConstraint.make(t, _pending_ops)
		c.value = ConstraintRules.measured_value(sk, t, _pending_ops)
		c.label_offset = _preview - _anchor_world(sk, c)
		DimensionOverlay._draw_one(overlay, v, sk, c,
			ghost(0.8), app.doc.display_unit)
