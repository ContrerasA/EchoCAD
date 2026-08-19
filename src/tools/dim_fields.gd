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
## Per-field kind, parallel to `labels`: "len" (a length — live value shown
## in the display unit), "int" (a unitless count — shown as a whole number),
## "deg" (an angle — shown with a ° suffix). Counts and angles were being
## run through the mm->display-unit conversion, so a circular pattern showed
## N=4 as "0.157 in" (QA §M29.4). Typed text always parses as the raw number
## for "int"/"deg" (value_num) and through the unit parser for "len".
var kinds: Array = []
## Parallel to `labels`: a disabled field is skipped by Tab and not drawn.
## Tools flip these live — a rectangular pattern with Rows=1 has no vertical
## spacing to ask for (QA §M29.1).
var enabled: Array = []


func _init(field_labels: Array[String], field_kinds: Array = []) -> void:
	labels = field_labels
	for i in labels.size():
		texts.append("")
		kinds.append(String(field_kinds[i]) if i < field_kinds.size() else "len")
		enabled.append(true)


## Enable/disable field `i`. Disabling the active field moves the cursor to
## the next enabled one so typing never lands in a hidden box.
func set_enabled(i: int, on: bool) -> void:
	if i >= enabled.size() or enabled[i] == bool(on):
		return
	enabled[i] = bool(on)
	if not on and active == i:
		_advance()


func _advance() -> void:
	for _k in texts.size():
		active = (active + 1) % texts.size()
		if enabled[active]:
			return


func reset() -> void:
	for i in texts.size():
		texts[i] = ""
	active = 0
	if not enabled.is_empty() and not enabled[0]:
		_advance()


func has_text(i: int) -> bool:
	return i < texts.size() and texts[i].strip_edges() != ""


## Typed value in canonical mm (NAN when empty/invalid). Bare numbers read
## in `unit`; suffixes ("10mm") override.
func value_mm(i: int, unit: UnitConverter.Unit) -> float:
	if not has_text(i):
		return NAN
	var r := UnitConverter.parse(texts[i], unit)
	return float(r["mm"]) if r["ok"] else NAN


## Typed value as a RAW number (counts, degrees) — no unit conversion.
func value_num(i: int) -> float:
	return value_mm(i, UnitConverter.Unit.MM)


## How field `i` displays a live (untyped) value — per the field's kind.
func format_live(i: int, live_val: float, unit: UnitConverter.Unit) -> String:
	match String(kinds[i]) if i < kinds.size() else "len":
		"int":
			return str(int(roundf(live_val)))
		"deg":
			if absf(live_val - roundf(live_val)) < 0.05:
				return "%d°" % int(roundf(live_val))
			return "%.1f°" % live_val
	return UnitConverter.format(live_val, unit)


## Consume typing keys. Returns true when consumed.
func key_input(e: InputEventKey) -> bool:
	if e.keycode == KEY_TAB:
		_advance()
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
		if not enabled[i]:
			continue
		var typed := has_text(i)
		var live_val := float(live[i]) if i < live.size() else 0.0
		var text: String = texts[i] if typed else format_live(i, live_val, unit)
		var label := "%s: %s" % [labels[i], text]
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		var rect := Rect2(pos - Vector2(3, 11), sz + Vector2(8, 6))
		# Theme-sourced chip + ink (M26): the hardcoded dark chip and white
		# text washed out under the light theme.
		var chip := ThemeService.col("panel")
		chip.a = 0.9
		var ink := ThemeService.col("text")
		overlay.draw_rect(rect, chip)
		overlay.draw_rect(rect, ThemeService.col("accent") if i == active
			else Color(ink.r, ink.g, ink.b, 0.25), false, 1.0)
		overlay.draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			ink if typed else Color(ink.r, ink.g, ink.b, 0.6))
		pos.y += 22.0
