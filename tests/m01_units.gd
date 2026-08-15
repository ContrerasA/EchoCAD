extends SceneTree

# M1: unit conversions (mm canonical), suffix parsing.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m01_units: " + msg)
	return false


func _near(a: float, b: float, tol := 1e-9) -> bool:
	return absf(a - b) <= tol


func _run() -> bool:
	if not _near(UnitConverter.to_mm(1.0, UnitConverter.Unit.IN), 25.4):
		return _fail("1in != 25.4mm")
	if not _near(UnitConverter.to_mm(2.0, UnitConverter.Unit.FT), 609.6):
		return _fail("2ft != 609.6mm")
	if not _near(UnitConverter.from_mm(25.4, UnitConverter.Unit.IN), 1.0):
		return _fail("25.4mm != 1in")
	if not _near(UnitConverter.from_mm(10.0, UnitConverter.Unit.CM), 1.0):
		return _fail("10mm != 1cm")

	for u: UnitConverter.Unit in [UnitConverter.Unit.MM, UnitConverter.Unit.CM,
			UnitConverter.Unit.IN, UnitConverter.Unit.FT]:
		if UnitConverter.unit_from_string(UnitConverter.unit_to_string(u)) != u:
			return _fail("unit string round-trip failed for %d" % u)
		if not _near(UnitConverter.from_mm(UnitConverter.to_mm(3.25, u), u), 3.25):
			return _fail("conversion round-trip failed for %d" % u)

	# parse(): bare number reads in the default unit; suffix overrides.
	var r := UnitConverter.parse("2.5", UnitConverter.Unit.IN)
	if not r["ok"] or not _near(r["mm"], 63.5):
		return _fail("parse bare inch failed")
	r = UnitConverter.parse("10 mm", UnitConverter.Unit.IN)
	if not r["ok"] or not _near(r["mm"], 10.0):
		return _fail("parse suffixed mm failed")
	r = UnitConverter.parse("1.5in", UnitConverter.Unit.MM)
	if not r["ok"] or not _near(r["mm"], 38.1):
		return _fail("parse suffixed inch failed")
	r = UnitConverter.parse("abc", UnitConverter.Unit.MM)
	if r["ok"]:
		return _fail("parse accepted garbage")
	r = UnitConverter.parse("", UnitConverter.Unit.MM)
	if r["ok"]:
		return _fail("parse accepted empty")

	if UnitConverter.format(63.5, UnitConverter.Unit.IN) != "2.500 in":
		return _fail("format wrong: %s" % UnitConverter.format(63.5, UnitConverter.Unit.IN))

	print("M01_UNITS OK: conversions, parsing, formatting")
	return true
