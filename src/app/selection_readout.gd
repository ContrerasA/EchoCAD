class_name SelectionReadout
extends RefCounted

## Identity readout for the status bar: WHICH entities the selection (or the
## hover, when nothing is selected) is made of — id, kind and index — so a
## shape on screen can be named out loud and found again in the .ecad JSON
## without opening the file. `Measure` says how big a selection is; this says
## who it is.
##
## Pure functions over a Sketch, same contract as Measure: the label shows
## exactly this string, so what is on screen is what a test asserts.

## Entities spelled out in full before the tail collapses to "+N more".
const MAX_ITEMS := 3


## One line for the status bar, or "" when there is nothing to name.
## `constraint_index` is AppRoot.selected_constraint (-1 = none); a selected
## constraint wins, because clicking a dimension label is a selection of its
## own channel and the entity selection is stale then.
static func describe(sk: Sketch, selection: Array, hover_id: String,
		constraint_index := -1) -> String:
	if sk == null:
		return ""
	if constraint_index >= 0 and constraint_index < sk.constraints.size():
		return _constraint_brief(sk, constraint_index)
	if selection.is_empty():
		if hover_id != "" and sk.has(hover_id):
			return "⌖ " + entity_brief(sk, hover_id, true)
		return ""
	if selection.size() == 1:
		return entity_brief(sk, String(selection[0]), true)
	var parts: Array[String] = []
	for i in mini(selection.size(), MAX_ITEMS):
		parts.append(entity_brief(sk, String(selection[i]), false))
	var out := "  ·  ".join(parts)
	if selection.size() > MAX_ITEMS:
		out += "  +%d more" % (selection.size() - MAX_ITEMS)
	return "%d sel:  %s" % [selection.size(), out]


## "e4 line #3  [e2→e3]" — `detail` adds the sub-entity ids (a line's
## endpoints, a circle's centre), which is what makes a constraint operand
## list readable at a glance.
static func entity_brief(sk: Sketch, id: String, detail: bool) -> String:
	var e := sk.entity(id)
	if e == null:
		return "%s (gone)" % id
	var out := "%s %s #%d" % [id, e.kind(), sk.index_of(id)]
	if e.construction:
		out += " constr"
	if sk.is_origin(id):
		out += " origin"
	if not detail:
		return out
	match e.kind():
		"point":
			# Canonical mm, spelled out as such: this slot names what is IN
			# the file, and the display-unit conversion belongs to the
			# measurement slot next door.
			out += "  [%.3f, %.3f] mm" % [(e as SketchPoint).pos.x,
				(e as SketchPoint).pos.y]
		"line":
			out += "  [%s→%s]" % [(e as SketchLine).p0, (e as SketchLine).p1]
		"circle":
			out += "  [c %s]" % (e as SketchCircle).center
		"arc":
			var a := e as SketchArc
			out += "  [c %s, %s→%s]" % [a.center, a.start, a.end]
	return out


## "c#9 MIDPOINT  [e1, e14]" — the index is the one `query.constraints` and
## `action.delete_constraint` speak, so the bar and automation agree.
static func _constraint_brief(sk: Sketch, index: int) -> String:
	var c := sk.constraints[index]
	var tname := String((SketchConstraint.Type.keys() as Array)[c.type])
	return "c#%d %s  [%s]" % [index, tname, ", ".join(c.operands)]
