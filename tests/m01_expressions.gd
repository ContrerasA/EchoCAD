extends SceneTree

# M1: expression whitelist, parameter resolution (order-independent, cycles
# fail gracefully), cross-unit rule.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m01_expressions: " + msg)
	return false


func _near(a: float, b: float, tol := 1e-6) -> bool:
	return absf(a - b) <= tol


func _run() -> bool:
	# Whitelist: unknown names are real errors, not silent zeros.
	var r := CadExpression.evaluate("wdith * 2", {"width": 4.0})
	if r["ok"] or String(r["error"]).find("wdith") < 0:
		return _fail("unknown name not reported")
	r = CadExpression.evaluate("OS.get_name()", {})
	if r["ok"]:
		return _fail("member access not rejected")
	r = CadExpression.evaluate("min(width, 10) + sqrt(4)", {"width": 4.0})
	if not r["ok"] or not _near(r["value"], 6.0):
		return _fail("math eval wrong")

	if CadExpression.valid_name("width2") != true \
			or CadExpression.valid_name("sin") != false \
			or CadExpression.valid_name("2width") != false \
			or CadExpression.valid_name("PI") != false:
		return _fail("valid_name wrong")

	# Order-independent resolution + canonical mm results.
	var params: Array = [
		CadParameter.make("total", "width * count", UnitConverter.Unit.IN),
		CadParameter.make("count", "4", CadParameter.UNIT_SCALAR),
		CadParameter.make("width", "2", UnitConverter.Unit.IN),
	]
	var res := CadExpression.evaluate_params(params)
	var vals: Dictionary = res["values"]
	if not (res["errors"] as Dictionary).is_empty():
		return _fail("unexpected errors: %s" % str(res["errors"]))
	if not _near(vals["width"], 50.8):
		return _fail("width canonical wrong: %f" % float(vals["width"]))
	if not _near(vals["count"], 4.0):
		return _fail("scalar wrong")
	if not _near(vals["total"], 203.2):     # 8 in
		return _fail("dependent wrong: %f" % float(vals["total"]))

	# Cross-unit: a mm parameter reading an inch parameter converts INTO mm
	# space first — "width + 10" in a mm param means +10 MILLIMETRES.
	params.append(CadParameter.make("gap", "width + 10", UnitConverter.Unit.MM))
	res = CadExpression.evaluate_params(params)
	if not _near((res["values"] as Dictionary)["gap"], 60.8):
		return _fail("cross-unit wrong: %f" % float(res["values"]["gap"]))

	# Cycle: exactly the cycle members fail, the rest still resolve.
	var cyc: Array = [
		CadParameter.make("a", "b + 1", CadParameter.UNIT_SCALAR),
		CadParameter.make("b", "a + 1", CadParameter.UNIT_SCALAR),
		CadParameter.make("ok_one", "7", CadParameter.UNIT_SCALAR),
	]
	res = CadExpression.evaluate_params(cyc)
	var errs: Dictionary = res["errors"]
	if not (errs.has("a") and errs.has("b")) or errs.has("ok_one"):
		return _fail("cycle detection wrong: %s" % str(errs))
	if not _near((res["values"] as Dictionary)["ok_one"], 7.0):
		return _fail("cycle broke unrelated parameter")

	# eval_text: user typing in the display unit gets canonical mm back.
	var t := CadExpression.eval_text(params, "width / 2", UnitConverter.Unit.IN)
	if not t["ok"] or not _near(t["value"], 25.4):
		return _fail("eval_text wrong: %s" % str(t))

	print("M01_EXPRESSIONS OK: whitelist, resolution, cross-unit, cycles")
	return true
