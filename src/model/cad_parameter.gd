class_name CadParameter
extends RefCounted
## A named, unit-tagged user parameter — the "parametric" half of the CAD
## story. Document data: serialized with the .ecad, mutated only through
## CmdSetParameters, and carrying NO evaluation logic (that is CadExpression's
## job). Ported from echo_vector's EVParameter with canonical mm instead of px.
##
## `expr` is the SOURCE TEXT the user typed ("100", "width / 2"). `value` is
## its last evaluated result in CANONICAL space — mm for a length unit, a raw
## number for UNIT_SCALAR. Both serialize: the text so an edit round-trips,
## the number so a file is readable without re-running the evaluator.
##
## An expression is evaluated entirely in its own unit's number space —
## referenced parameters are converted INTO that space first — so "width + 10"
## means "10 mm" in a mm parameter and "10 in" in an inch one.

## Unitless: ratios, counts, angles (degrees). Sentinel outside the Unit enum.
const UNIT_SCALAR := -1

var name: String = ""
var expr: String = "0"
var unit: int = UnitConverter.Unit.IN
## Last evaluated result, CANONICAL (mm for a length unit, raw for scalar).
var value: float = 0.0
## Free-text note (Fusion's "Comment" column).
var comment: String = ""


static func make(pname: String, pexpr: String, punit: int = UnitConverter.Unit.IN,
		pvalue := 0.0) -> CadParameter:
	var p := CadParameter.new()
	p.name = pname
	p.expr = pexpr
	p.unit = punit
	p.value = pvalue
	return p


func is_scalar() -> bool:
	return not is_length(unit)


static func is_length(u: int) -> bool:
	return u >= UnitConverter.Unit.MM and u <= UnitConverter.Unit.FT


func unit_label() -> String:
	return UnitConverter.suffix(unit) if is_length(unit) else ""


## A number typed in `u` -> canonical (mm for a length unit, unchanged otherwise).
static func to_canonical(v: float, u: int) -> float:
	return UnitConverter.to_mm(v, u) if is_length(u) else v


## Canonical -> a number displayed in `u`.
static func from_canonical(v: float, u: int) -> float:
	return UnitConverter.from_mm(v, u) if is_length(u) else v


func duplicate_parameter() -> CadParameter:
	var p := CadParameter.make(name, expr, unit, value)
	p.comment = comment
	return p


func to_dict() -> Dictionary:
	var d := {"name": name, "expr": expr, "value": value}
	if is_length(unit):
		d["unit"] = UnitConverter.unit_to_string(unit)
	if comment != "":
		d["comment"] = comment
	return d


static func from_dict(d: Dictionary) -> CadParameter:
	var p := CadParameter.new()
	p.name = String(d.get("name", ""))
	p.expr = String(d.get("expr", "0"))
	# A missing `unit` key means UNITLESS (how a scalar round-trips).
	p.unit = UnitConverter.unit_from_string(String(d["unit"])) if d.has("unit") \
		else UNIT_SCALAR
	p.value = float(d.get("value", 0.0))
	p.comment = String(d.get("comment", ""))
	return p
