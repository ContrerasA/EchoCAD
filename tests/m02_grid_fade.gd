extends SceneTree

# M2: the grid must CROSS-FADE between spacing levels as the view scales,
# rather than snapping. The spacing comes off a discrete 1/2/5 ladder, so
# drawing only the chosen rung makes every intermediate line appear or vanish
# on a single frame — the jarring pop this guards against. `step_levels`
# reports the rung, the next finer one, and how far the fade has progressed;
# both grids draw the finer level at that opacity underneath the settled one.

const UNIT := UnitConverter.Unit.IN


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m02_grid_fade: " + msg)
	return false


func _run() -> bool:
	# --- the ladder walks DOWN in exact 1/2/5 rungs and never drifts.
	var s := 127.0                                  # 5 in
	var want: Array[float] = [50.8, 25.4, 12.7, 5.08, 2.54, 1.27]
	for w in want:
		s = SketchView.step_below(UNIT, s)
		if absf(s - w) > 1e-6:
			return _fail("step_below gave %f, want %f" % [s, w])

	# --- blend is a real 0..1 ramp, and it RESETS exactly when the rung does.
	# Sweeping the target downward (zooming in) must never jump the blend
	# discontinuously WITHIN a rung: that discontinuity is the pop itself.
	var target := 60.0
	var prev_step := 0.0
	var prev_blend := 0.0
	var saw_reset := false
	while target > 2.0:
		var L := SketchView.step_levels(UNIT, target)
		var step: float = L["step"]
		var blend: float = L["blend"]
		if blend < -1e-6 or blend > 1.0 + 1e-6:
			return _fail("blend %f out of range at target %f" % [blend, target])
		# The finer rung must genuinely be finer, and the ratio must match.
		if float(L["finer"]) >= step:
			return _fail("finer rung %f is not below %f" % [L["finer"], step])
		if absf(float(L["ratio"]) - step / float(L["finer"])) > 1e-6:
			return _fail("ratio does not match the two rungs")
		if is_equal_approx(step, prev_step):
			# Same rung: the fade must be advancing, not jumping around.
			if blend < prev_blend - 1e-6:
				return _fail("blend went backwards within a rung (%f -> %f)"
					% [prev_blend, blend])
			if blend - prev_blend > 0.5:
				return _fail("blend jumped %f within a rung — that is a pop"
					% (blend - prev_blend))
		elif prev_step > 0.0:
			# Rung changed: the OLD level should have been nearly fully faded
			# in, and the new one starts near zero. That is what makes the
			# handover invisible — the finer level reaches full strength just
			# as it becomes the coarse level.
			saw_reset = true
			if prev_blend < 0.75:
				return _fail("rung changed while the finer level was only %f "
					% prev_blend + "faded in — the remaining %f pops in"
					% (1.0 - prev_blend))
			if blend > 0.35:
				return _fail("new rung started at blend %f, not near zero" % blend)
		prev_step = step
		prev_blend = blend
		target *= 0.93
	if not saw_reset:
		return _fail("sweep never crossed a rung boundary — test proves nothing")

	print("M02_GRID_FADE OK: ladder exact, blend ramps 0..1 and hands over "
		+ "without a jump")
	return true
