class_name UnitConverter
extends RefCounted
## Unit conversion at the UI boundary. The model, solver, commands, and RPC
## queries always speak CANONICAL MILLIMETRES; `Unit` is only the space the
## user types and reads in. Nothing outside the UI/serialization boundary may
## convert.

enum Unit { MM, CM, IN, FT }

const _MM_PER := {
	Unit.MM: 1.0,
	Unit.CM: 10.0,
	Unit.IN: 25.4,
	Unit.FT: 304.8,
}

const _SUFFIX := {
	Unit.MM: "mm",
	Unit.CM: "cm",
	Unit.IN: "in",
	Unit.FT: "ft",
}

## Display decimals per unit (coarser units need more places).
const _DECIMALS := {
	Unit.MM: 2,
	Unit.CM: 3,
	Unit.IN: 3,
	Unit.FT: 4,
}


static func to_mm(v: float, u: Unit) -> float:
	return v * _MM_PER[u]


static func from_mm(v: float, u: Unit) -> float:
	return v / _MM_PER[u]


static func suffix(u: Unit) -> String:
	return _SUFFIX[u]


static func decimals(u: Unit) -> int:
	return _DECIMALS[u]


static func format(mm: float, u: Unit) -> String:
	return ("%." + str(decimals(u)) + "f %s") % [from_mm(mm, u), suffix(u)]


## M40: value for an EDIT field — enough digits to round-trip (a 10 mm
## extrude shown as "0.394 in" would commit as 10.0076 mm when the dialog
## is confirmed untouched). Up to 6 decimals, trailing zeros trimmed.
static func format_exact(mm: float, u: Unit) -> String:
	var v := from_mm(mm, u)
	var txt := "%.6f" % v
	if txt.contains("."):
		txt = txt.rstrip("0").rstrip(".")
	if txt == "-0":
		txt = "0"
	return "%s %s" % [txt, suffix(u)]


static func unit_to_string(u: Unit) -> String:
	return _SUFFIX[u]


static func unit_from_string(s: String, fallback := Unit.MM) -> Unit:
	for u: Unit in _SUFFIX:
		if _SUFFIX[u] == s:
			return u
	return fallback


## Parse user text like "2.5", "2.5in", "10 mm" into canonical mm, reading a
## bare number in `default_unit`. {"ok": bool, "mm": float, "error": String}.
static func parse(text: String, default_unit: Unit) -> Dictionary:
	var t := text.strip_edges().to_lower()
	if t == "":
		return {"ok": false, "mm": 0.0, "error": "empty"}
	var unit := default_unit
	for u: Unit in _SUFFIX:
		var sfx: String = _SUFFIX[u]
		if t.ends_with(sfx):
			unit = u
			t = t.left(t.length() - sfx.length()).strip_edges()
			break
	if not t.is_valid_float():
		return {"ok": false, "mm": 0.0, "error": "not a number: %s" % text}
	return {"ok": true, "mm": to_mm(t.to_float(), unit), "error": ""}
