extends SceneTree

# M1: command undo/redo round-trips the model to identical JSON; move merge;
# merge-batch absorb + seal; delete restores order + constraints.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m01_commands: " + msg)
	return false


func _snap(doc: CadDocument) -> String:
	return JSON.stringify(doc.to_dict())


func _run() -> bool:
	var doc := CadDocument.new()
	var stack := CommandStack.new(doc)
	var empty_snap := _snap(doc)

	# Feature + entities via commands.
	var feat := SketchFeature.make(doc.auto_name("Sketch"))
	feat.id = doc.next_feature_id()
	stack.push_no_merge(CmdAddFeature.new(feat))
	if doc.features.size() != 1 or doc.timeline_marker != 1:
		return _fail("add feature state wrong")

	var sk := feat.sketch
	var a := SketchPoint.make(Vector2(0, 0)); a.id = sk.next_id()
	var b := SketchPoint.make(Vector2(50.8, 0)); b.id = sk.next_id()
	var line := SketchLine.make(a.id, b.id); line.id = sk.next_id()
	var h := SketchConstraint.make(SketchConstraint.Type.HORIZONTAL, [line.id])
	stack.push_no_merge(CmdAddEntities.new(feat.id, [a, b, line], [h]))
	if sk.size() != 3 or sk.constraints.size() != 1:
		return _fail("add entities state wrong")

	# Continuous drag: three merged pushes = ONE undo step.
	var steps_before := 3   # feature, entities, upcoming move
	stack.push_no_merge(CmdMovePoints.new(feat.id, {b.id: Vector2(60.0, 0)}))
	stack.push(CmdMovePoints.new(feat.id, {b.id: Vector2(70.0, 5.0)}))
	stack.push(CmdMovePoints.new(feat.id, {b.id: Vector2(76.2, 0)}))
	if sk.point(b.id).pos != Vector2(76.2, 0):
		return _fail("move result wrong")
	var full_snap := _snap(doc)
	stack.undo()
	if sk.point(b.id).pos != Vector2(50.8, 0):
		return _fail("merged drag did not undo as one step")
	stack.redo()
	if _snap(doc) != full_snap:
		return _fail("redo after merged drag mismatch")

	# Merge batch: move + constraint change absorbed into one undo step.
	var batch := CmdMergeBatch.new("Drag", [])
	stack.push_no_merge(batch)
	stack.push(CmdMovePoints.new(feat.id, {a.id: Vector2(0, 10)}))
	var after_cons: Array = sk.constraints.duplicate()
	after_cons.append(SketchConstraint.make(
		SketchConstraint.Type.FIX, [a.id]))
	stack.push(CmdSetConstraints.new(feat.id, sk.constraints, after_cons))
	stack.push(CmdMovePoints.new(feat.id, {a.id: Vector2(0, 12)}))
	batch.seal()
	stack.push_no_merge(CmdSetParameters.new(doc.parameters,
		[CadParameter.make("width", "3", UnitConverter.Unit.IN, 76.2)]))
	if sk.constraints.size() != 2 or doc.parameters.size() != 1:
		return _fail("batch/parameters state wrong")
	var final_snap := _snap(doc)
	stack.undo()   # parameters
	stack.undo()   # whole sealed batch (move + constraints + move)
	if sk.constraints.size() != 1 or sk.point(a.id).pos != Vector2(0, 0):
		return _fail("sealed batch did not undo as one step")

	# Undo everything -> byte-identical to the empty document...
	while stack.can_undo():
		stack.undo()
	# ...except minted counters, which by design never roll back.
	var undone: Dictionary = doc.to_dict()
	undone["feature_counter"] = 0
	if JSON.stringify(undone) != empty_snap:
		return _fail("full undo does not match empty document")
	# ...and redo everything -> byte-identical to the final state.
	while stack.can_redo():
		stack.redo()
	if _snap(doc) != final_snap:
		return _fail("full redo does not match final state")

	# Delete with constraint capture: order and constraints restored.
	var before_delete := _snap(doc)
	# b is no constraint's operand (h targets the line, FIX targets a), so
	# both constraints survive; only the point goes.
	stack.push_no_merge(CmdDeleteEntities.new(feat.id, [b.id]))
	if sk.has(b.id) or sk.constraints.size() != 2:
		return _fail("delete state wrong")
	stack.undo()
	if _snap(doc) != before_delete:
		return _fail("delete undo mismatch")

	# Feature delete + marker restore.
	stack.push_no_merge(CmdDeleteFeature.new(feat.id))
	if doc.features.size() != 0 or doc.timeline_marker != 0:
		return _fail("feature delete state wrong")
	stack.undo()
	if _snap(doc) != before_delete:
		return _fail("feature delete undo mismatch")

	print("M01_COMMANDS OK: undo/redo round-trips, drag merge, sealed merge batch, delete capture")
	return true
