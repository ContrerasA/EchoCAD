class_name DimFields
extends RefCounted
## Fusion-style type-while-drawing dimension fields. No focus-stealing
## LineEdits: the active tool feeds key events here and draws the fields on
## the overlay, so the same path works windowed, headless, and over RPC.
## Tab cycles fields; typing replaces the live measurement for that field;
## Enter (handled by the tool) commits using value_mm() where typed.

## Characters a dimension field accepts.
##
## Digits and unit letters are not enough: dimensions take EXPRESSIONS
## ("width / 2", "2*1.25"), and the operators were missing from this list, so
## they were silently swallowed as you typed — "2*1.25" arrived as "21.25".
## Letters are all accepted rather than just the unit ones, because parameter
## names are arbitrary; whether the result means anything is the expression
## evaluator's judgement to make, not this filter's.
const ACCEPTED := "0123456789.,-+*/()^_ abcdefghijklmnopqrstuvwxyz" \
	+ "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

var labels: Array[String] = []
var texts: Array[String] = []
var active := 0


func _init(field_labels: Array[String]) -> void:
	labels = field_labels
	for l in labels:
		texts.append("")


func reset() -> void:
	for i in texts.size():
		texts[i] = ""
	active = 0


func has_text(i: int) -> bool:
	return i < texts.size() and texts[i].strip_edges() != ""


## Typed value in canonical mm (NAN when empty/invalid). Bare numbers read
## in `unit`; suffixes ("10mm") override.
func value_mm(i: int, unit: UnitConverter.Unit) -> float:
	if not has_text(i):
		return NAN
	var r := UnitConverter.parse(texts[i], unit)
	return float(r["mm"]) if r["ok"] else NAN


## Consume typing keys. Returns true when consumed.
func key_input(e: InputEventKey) -> bool:
	if e.keycode == KEY_TAB:
		active = (active + 1) % texts.size()
		return true
	if e.keycode == KEY_BACKSPACE:
		if texts[active].length() > 0:
			texts[active] = texts[active].left(texts[active].length() - 1)
		return true
	var ch := char(e.unicode) if e.unicode > 0 else ""
	if ch != "" and ACCEPTED.contains(ch):
		texts[active] += ch
		return true
	return false


## Draw the fields near `at` (screen px). `live` — current measured values
## in mm per field, shown greyed when nothing is typed.
func draw(overlay: Control, at: Vector2, unit: UnitConverter.Unit,
		live: Array) -> void:
	var font := ThemeDB.fallback_font
	var pos := at + Vector2(16, 16)
	for i in labels.size():
		var typed := has_text(i)
		var text: String = texts[i] if typed \
			else UnitConverter.format(float(live[i]) if i < live.size() else 0.0, unit)
		var label := "%s: %s" % [labels[i], text]
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		var rect := Rect2(pos - Vector2(3, 11), sz + Vector2(8, 6))
		overlay.draw_rect(rect, Color(0.10, 0.11, 0.13, 0.9))
		overlay.draw_rect(rect, Color(0.4, 0.7, 1.0, 0.9) if i == active
			else Color(1, 1, 1, 0.25), false, 1.0)
		overlay.draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(1, 1, 1) if typed else Color(1, 1, 1, 0.6))
		pos.y += 22.0
