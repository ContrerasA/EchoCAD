class_name CadExpression
extends RefCounted
## Expression evaluation (static + pure). ONE definition of "what does this
## text mean as a number", shared by parameters (CadParameter) and
## expression-valued dimensions. Ported from echo_vector's EVExpression with
## canonical mm and no dpi.
##
## Built on Godot's `Expression` with a WHITELIST in front: every identifier
## must be a known parameter name or one of the functions/constants below.
## That makes "unknown name: wdith" a real error instead of a silent 0, and
## keeps a document file from reaching anything but arithmetic.
##
## UNIT RULE: an expression is evaluated entirely in the number space of its
## OWN unit; referenced parameters are converted INTO that space first, and
## the result is converted back to canonical mm afterwards. Scalars pass
## through unconverted in both directions.

const FUNCS := ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqrt",
	"abs", "min", "max", "round", "floor", "ceil", "pow", "log", "exp", "fmod",
	"clamp", "sign", "snapped", "deg_to_rad", "rad_to_deg"]
const CONSTS := ["PI", "TAU"]
## Names a parameter may NOT take.
const RESERVED := ["true", "false", "null", "and", "or", "not", "in", "if",
	"else", "self", "INF", "NAN"]
## Resolution passes before declaring a cycle.
const MAX_PASSES := 64

static var _ident_re: RegEx = null


## Release engine resources held in statics before shutdown — statics
## outlive the servers and get reported as leaks otherwise (QA §M31).
static func drop_static_caches() -> void:
	_ident_re = null


## Every identifier token in `text`, in order, without duplicates.
static func identifiers(text: String) -> Array[String]:
	if _ident_re == null:
		_ident_re = RegEx.new()
		_ident_re.compile("[A-Za-z_][A-Za-z_0-9]*")
	var out: Array[String] = []
	for m in _ident_re.search_all(text):
		var s := m.get_string()
		if not out.has(s):
			out.append(s)
	return out


## A plain number (no references, no math). Such a dimension keeps NO
## expression: what the user typed is exactly its value.
## Is this a plain measurement rather than something to evaluate?
##
## A UNIT SUFFIX still counts as a literal: "10mm" and "1.5in" are values, not
## expressions. Accepting only a bare float sent them to the expression
## evaluator, which read the suffix as a variable name and refused the whole
## entry with "unknown name: mm" — so typed units simply did not work anywhere
## a dimension is entered.
static func is_literal(text: String) -> bool:
	var t := text.strip_edges()
	if t.is_valid_float():
		return true
	return UnitConverter.parse(t, UnitConverter.Unit.MM)["ok"]


## Can `n` be a parameter name?
static func valid_name(n: String) -> bool:
	var s := n.strip_edges()
	if s == "":
		return false
	var ids := identifiers(s)
	if ids.size() != 1 or ids[0] != s:
		return false
	return not (RESERVED.has(s) or FUNCS.has(s) or CONSTS.has(s))


## Evaluate `text` against `env` (name -> number, ALREADY in the caller's unit
## space). {"ok": bool, "value": float, "error": String} — never throws.
static func evaluate(text: String, env: Dictionary) -> Dictionary:
	var t := text.strip_edges()
	if t == "":
		return _err("empty expression")
	for id in identifiers(t):
		if env.has(id) or FUNCS.has(id) or CONSTS.has(id):
			continue
		return _err("unknown name: %s" % id)
	var names := PackedStringArray()
	var values: Array = []
	for k: String in env:
		names.append(k)
		values.append(float(env[k]))
	var e := Expression.new()
	if e.parse(t, names) != OK:
		return _err(e.get_error_text())
	var r: Variant = e.execute(values, null, false)
	if e.has_execute_failed():
		return _err(e.get_error_text())
	if not (r is float or r is int):
		return _err("not a number")
	var f := float(r)
	if not is_finite(f):
		return _err("not a finite number")
	return {"ok": true, "value": f, "error": ""}


## Resolve a whole parameter list: {"values": {name: CANONICAL mm number},
## "errors": {name: String}}. Order-independent; cycles and bad references
## land in `errors` with a 0 value, degrading exactly themselves and their
## dependents, never the whole document.
static func evaluate_params(params: Array) -> Dictionary:
	var known := {}
	for p: CadParameter in params:
		known[p.name] = true
	var values := {}
	var errors := {}
	var pending: Array = params.duplicate()
	var passes := 0
	while not pending.is_empty() and passes < MAX_PASSES:
		passes += 1
		var still: Array = []
		var progressed := false
		for p: CadParameter in pending:
			var ready := true
			for d: String in identifiers(p.expr):
				if known.has(d) and not values.has(d):
					ready = false
					break
			if not ready:
				still.append(p)
				continue
			progressed = true
			var r := evaluate(p.expr, env_for(params, values, p.unit))
			if bool(r["ok"]):
				values[p.name] = CadParameter.to_canonical(float(r["value"]), p.unit)
			else:
				values[p.name] = 0.0
				errors[p.name] = String(r["error"])
		pending = still
		if not progressed:
			break
	for p: CadParameter in pending:
		values[p.name] = 0.0
		errors[p.name] = "circular or unresolved reference"
	return {"values": values, "errors": errors}


## The evaluation environment for a consumer working in `unit`: every
## parameter's canonical value converted into that unit's number space
## (scalars pass through).
static func env_for(params: Array, values: Dictionary, unit: int) -> Dictionary:
	var env := {}
	for p: CadParameter in params:
		var v := float(values.get(p.name, 0.0))
		env[p.name] = v if p.is_scalar() else CadParameter.from_canonical(v, unit)
	return env


## Evaluate user text typed in `unit` against `params`, returning the
## CANONICAL result ({"ok", "value", "error"}). The one seam the UI calls.
static func eval_text(params: Array, text: String, unit: int) -> Dictionary:
	var resolved := evaluate_params(params)
	var r := evaluate(text, env_for(params, resolved["values"] as Dictionary, unit))
	if bool(r["ok"]):
		r["value"] = CadParameter.to_canonical(float(r["value"]), unit)
	return r


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "value": 0.0, "error": msg}
