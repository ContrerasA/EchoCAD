extends SceneTree

# M1: save -> load -> save is byte-identical; migration scaffold tolerates
# current version; loaded model equals source model structurally.


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m01_serializer: " + msg)
	return false


func _run() -> bool:
	var doc := CadDocument.new()
	doc.display_unit = UnitConverter.Unit.IN
	doc.parameters.append(CadParameter.make("width", "2.5", UnitConverter.Unit.IN, 63.5))
	doc.parameters.append(CadParameter.make("ratio", "0.5", CadParameter.UNIT_SCALAR, 0.5))

	var feat := SketchFeature.make("Sketch1", "XZ")
	feat.id = doc.next_feature_id()
	doc.features.append(feat)
	doc.timeline_marker = 1

	var sk := feat.sketch
	var a := SketchPoint.make(Vector2(0, 0)); a.id = sk.next_id(); sk.add(a)
	var b := SketchPoint.make(Vector2(63.5, 0)); b.id = sk.next_id(); sk.add(b)
	var c := SketchPoint.make(Vector2(31.75, 20)); c.id = sk.next_id(); sk.add(c)
	var line := SketchLine.make(a.id, b.id); line.id = sk.next_id(); sk.add(line)
	var arc := SketchArc.make(c.id, a.id, b.id, false); arc.id = sk.next_id(); sk.add(arc)
	var circle := SketchCircle.make(c.id, 12.7); circle.id = sk.next_id()
	circle.construction = true
	sk.add(circle)
	sk.constraints.append(SketchConstraint.make(
		SketchConstraint.Type.HORIZONTAL, [line.id]))
	var dim := SketchConstraint.make(
		SketchConstraint.Type.DISTANCE, [a.id, b.id], 63.5)
	dim.expr = "width"
	dim.expr_unit = UnitConverter.Unit.IN
	dim.label_offset = Vector2(0, -8)
	sk.constraints.append(dim)

	var path := "user://m01_roundtrip.ecad"
	if not Serializer.save(doc, path):
		return _fail("save failed")
	var loaded := Serializer.load_file(path)
	if loaded == null:
		return _fail("load failed")

	# Byte-identical re-save.
	var first := Serializer.to_json(doc)
	var second := Serializer.to_json(loaded)
	if first != second:
		return _fail("save -> load -> save not byte-identical")

	# Structural spot checks on the loaded copy.
	var lf := loaded.sketch_feature(feat.id)
	if lf == null or lf.plane != "XZ" or lf.name != "Sketch1":
		return _fail("feature fields lost")
	if lf.sketch.size() != 6 or lf.sketch.constraints.size() != 2:
		return _fail("sketch contents lost")
	if not (lf.sketch.entity(circle.id) as SketchCircle).construction:
		return _fail("construction flag lost")
	var ldim := lf.sketch.constraints[1]
	if ldim.expr != "width" or ldim.expr_unit != UnitConverter.Unit.IN \
			or ldim.label_offset != Vector2(0, -8):
		return _fail("dimension expression fields lost")
	# Id counter survives: next mint must not collide.
	var fresh_id := lf.sketch.next_id()
	if lf.sketch.has(fresh_id):
		return _fail("id counter did not survive round-trip")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("M01_SERIALIZER OK: byte-identical round-trip, fields and counters survive")
	return true
