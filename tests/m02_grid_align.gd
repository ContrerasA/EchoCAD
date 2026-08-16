extends SceneTree

# M2: the two cross-faded grid levels must OVERLAY, never interleave.
#
# The grid draws a coarse level plus the next finer one at partial opacity, so
# spacing changes fade instead of popping. That only works if the fine level
# divides the coarse one EXACTLY: every fine line then sits either on a coarse
# line or evenly between them. Walking the 1/2/5 ladder does NOT guarantee it —
# the 5 -> 2 rung has a ratio of 2.5, which put a 127 mm coarse level against a
# 50.8 mm fine level: lines at 127/254/381 against 50.8/101.6/152.4, so 101.6
# and 127 landed 25.4 mm apart and the grid drew visible close pairs.

const UNIT := UnitConverter.Unit.IN


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m02_grid_align: " + msg)
	return false


## Distance from `p` to the nearest line of spacing `sp` — the same quantity
## the shader's `line_cover` measures.
func _dist_to_line(p: float, sp: float) -> float:
	return absf(fposmod(p / sp - 0.5, 1.0) - 0.5) * sp


func _run() -> bool:
	var target := 400.0
	var checked := 0
	while target > 1.0:
		var L := SketchView.step_levels(UNIT, target)
		var step: float = L["step"]
		var fine: float = L["finer"]
		var ratio: float = L["ratio"]

		# 1. The ratio is a whole number > 1, so the levels nest.
		if ratio < 1.5 or absf(ratio - roundf(ratio)) > 1e-6:
			return _fail("ratio %f is not a whole number (target %f)"
				% [ratio, target])
		# 2. ...and it really is step/fine, not a number carried separately.
		if absf(step / fine - ratio) > 1e-6:
			return _fail("ratio %f does not match step/fine %f"
				% [ratio, step / fine])

		# 3. THE POINT: every coarse line must have a fine line exactly on it.
		# An interleaved pair fails here, because a coarse line then falls
		# between two fine ones instead of on one.
		for k in range(-4, 5):
			var p := float(k) * step
			if _dist_to_line(p, fine) > step * 1e-6:
				return _fail(("coarse line at %f mm has no fine line on it "
					+ "(step %f, fine %f) — the two levels interleave")
					% [p, step, fine])

		# 4. The fine level is itself a spacing the ladder would choose, so the
		# fading lines read as a real measurement rather than an odd fraction.
		if absf(fine - SketchView.step_for(UNIT, fine)) > 1e-6:
			return _fail("fine level %f mm is off the 1/2/5 ladder" % fine)

		checked += 1
		target *= 0.87
	if checked < 20:
		return _fail("sweep only covered %d steps" % checked)

	print("M02_GRID_ALIGN OK: levels nest exactly, no interleaving, fine level "
		+ "stays on the ladder")
	return true
