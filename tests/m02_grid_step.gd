extends SceneTree

# M2 QA step 20 root cause: `SketchView.step_for` overshot its target by up to
# 8.5x, so the grid was far coarser than asked for. At the default camera
# distance it chose a 254 mm (10 inch) minor spacing — wider than the viewport —
# so near the origin only the MAJOR lines were ever on screen and the grid
# looked like it was dropping lines. Two earlier fixes chased the symptom
# (alpha, mesh symmetry) without touching this.
#
# The old code scaled a value up until it EXCEEDED the target and only then
# consulted the 1/2/5 ladder, which made `mult = 1.0` always win and left 2 and
# 5 unreachable. These assertions pin the contract so it cannot regress.

const MAX_OVERSHOOT := 2.0   # a step may never be worse than 2x the target


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m02_grid_step: " + msg)
	return false


func _run() -> bool:
	for unit: UnitConverter.Unit in [UnitConverter.Unit.MM, UnitConverter.Unit.IN]:
		var unit_mm := UnitConverter.to_mm(1.0, unit)
		for target: float in [0.4, 1.0, 5.0, 12.0, 25.0, 48.0, 100.0, 300.0,
				1000.0, 5000.0]:
			var step := SketchView.step_for(unit, target)
			# Covers the target: a step under it would pack lines too densely.
			if step < target - 1e-6:
				return _fail("step %f is finer than target %f (unit %f)"
					% [step, target, unit_mm])
			# ...but never wildly over it. This is the assertion that fails on
			# the old implementation, by as much as 8.5x.
			if step > target * MAX_OVERSHOOT:
				return _fail("step %f overshoots target %f by %.1fx (unit %f)"
					% [step, target, step / target, unit_mm])
			# Lands on the 1/2/5 ladder in the unit's own terms, so the grid
			# reads as round numbers rather than arbitrary spacings.
			var units := step / unit_mm
			var decade: float = pow(10.0, roundf(log(units / 5.0) / log(10.0)))
			var ok := false
			for mult: float in [1.0, 2.0, 5.0]:
				for exp_i in range(-6, 7):
					if absf(units - mult * pow(10.0, exp_i)) < 1e-6:
						ok = true
			if not ok:
				return _fail("step %f (= %f units) is off the 1/2/5 ladder"
					% [step, units])
			if decade <= 0.0:
				return _fail("bad decade")

	# The specific case from the QA report: inch grid, default camera distance.
	# 800 mm * GRID_TARGET_FRAC(0.06) = 48 mm target -> 2 in, not 10 in.
	var home := SketchView.step_for(UnitConverter.Unit.IN, 800.0 * 0.06)
	if absf(home - 50.8) > 1e-6:
		return _fail("home-view step is %f mm, want 50.8 (2 in)" % home)

	print("M02_GRID_STEP OK: ladder covers the target without overshooting, "
		+ "home view is 2 in not 10 in")
	return true
