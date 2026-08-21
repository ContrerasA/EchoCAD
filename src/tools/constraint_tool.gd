class_name ConstraintTool
extends SketchTool
## Armed constraint placement (CHANGES #6): pressing a constraint button
## with nothing (or nothing valid) selected arms this tool for that
## constraint type; the user then clicks the operands — hover pre-highlighted
## — and the constraint applies the moment the picks validate. The tool stays
## armed for the next one (Fusion's behaviour) until Esc or another tool.
## With a valid selection already made the button applies at once instead
## (see AppRoot.arm_constraint), so select-first keeps working too.

var type: SketchConstraint.Type = SketchConstraint.Type.COINCIDENT
var type_title := "Constraint"


func _init() -> void:
	id = "constraint"
	title = "Constraint"
	hidden = true


## Operand count a type can take at most — past it a new pick starts over.
static func max_operands(t: SketchConstraint.Type) -> int:
	match t:
		SketchConstraint.Type.SYMMETRY:
			return 3
		SketchConstraint.Type.FIX, SketchConstraint.Type.RADIUS, \
				SketchConstraint.Type.DIAMETER:
			return 1
	return 2


func arm(p_type: SketchConstraint.Type, p_title: String) -> void:
	type = p_type
	type_title = p_title
	_say_needs()


func activate() -> void:
	clear_hover()
	app.set_selection([])
	_say_needs()


func deactivate() -> void:
	clear_hover()


## "Coincident: needs two points — click them" straight from the rules
## table, so the hint can never disagree with what validate() will accept.
func _say_needs() -> void:
	var sk := sketch()
	if sk == null:
		return
	var why := ConstraintRules.validate(sk, type, [])
	app.set_status_hint("%s: %s — click them (Esc to stop)" % [type_title, why])


func cancel() -> bool:
	if not app.selection.is_empty():
		app.set_selection([])
		_say_needs()
		return true
	return false


func pointer_move(world: Vector2, _screen: Vector2, _e: InputEventMouseMotion) -> bool:
	return update_hover(world, GATHER_HIT_PX)


func pointer_down(world: Vector2, _screen: Vector2, e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	var sk := sketch()
	var hit := SketchGeometry.entity_at(sk, world, GATHER_HIT_PX / view().zoom())
	if hit == "":
		return true
	var sel := app.selection.duplicate()
	if sel.has(hit):
		sel.erase(hit)
		app.set_selection(sel)
		return true
	if sel.size() >= max_operands(type):
		sel = []   # a full, still-invalid set: this pick starts a new one
	sel.append(hit)
	app.set_selection(sel)
	var ents: Array = []
	for sid in sel:
		ents.append(sk.entity(sid))
	var why := ConstraintRules.validate(sk, type, ents)
	if why == "":
		if app.apply_constraint(type) == "":
			app.set_status_hint("%s applied — pick the next, or Esc" % type_title)
		app.set_selection([])
		return true
	if sel.size() >= max_operands(type):
		app.set_status_hint("%s: %s" % [type_title, why])
	else:
		app.set_status_hint("%s: %s — %d picked" % [type_title, why, sel.size()])
	return true
