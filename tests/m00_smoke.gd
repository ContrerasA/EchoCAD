extends SceneTree

# M0 smoke: both GDExtensions load headless, TVGCanvas renders a stroked line
# to a non-blank Image, GeometryOps performs a boolean union.


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _run() -> bool:
	if not ClassDB.class_exists("TVGCanvas"):
		push_error("m00_smoke: TVGCanvas class missing (thorvg extension not loaded)")
		return false
	if not ClassDB.class_exists("GeometryOps"):
		push_error("m00_smoke: GeometryOps class missing (geometry extension not loaded)")
		return false

	if not _check_thorvg():
		return false
	if not _check_geometry():
		return false

	print("M00_SMOKE OK: extensions load, ThorVG renders, GeometryOps booleans work")
	return true


func _check_thorvg() -> bool:
	var canvas := TVGCanvas.new()
	canvas.set_view_box(Rect2(0, 0, 64, 64))
	var cmds := PackedInt32Array([TVGCanvas.CMD_MOVE_TO, TVGCanvas.CMD_LINE_TO])
	var pts := PackedVector2Array([Vector2(8, 8), Vector2(56, 56)])
	var handle := canvas.add_path(cmds, pts)
	canvas.set_stroke(handle, 2.0, Color.WHITE, TVGCanvas.CAP_ROUND, TVGCanvas.JOIN_ROUND)

	var img: Image = canvas.render_to_image(64, 64)
	if img == null:
		push_error("m00_smoke: render_to_image returned null: " + canvas.get_last_error())
		return false
	if img.get_width() != 64 or img.get_height() != 64:
		push_error("m00_smoke: unexpected image size %dx%d" % [img.get_width(), img.get_height()])
		return false

	var painted := 0
	for y in range(64):
		for x in range(64):
			if img.get_pixel(x, y).a > 0.0:
				painted += 1
	if painted == 0:
		push_error("m00_smoke: rendered image is blank")
		return false
	return true


func _check_geometry() -> bool:
	var ops := GeometryOps.new()
	# Two overlapping unit squares; union must succeed and stay a valid stream.
	var rect_a := _rect_path(Vector2(0, 0), Vector2(10, 10))
	var rect_b := _rect_path(Vector2(5, 5), Vector2(15, 15))
	var out: Dictionary = ops.path_boolean(
		rect_a[0], rect_a[1], rect_b[0], rect_b[1],
		GeometryOps.OP_UNION, GeometryOps.RULE_NON_ZERO)
	if not out.get("ok", false):
		push_error("m00_smoke: path_boolean failed")
		return false
	if (out["commands"] as PackedInt32Array).is_empty():
		push_error("m00_smoke: path_boolean returned empty commands")
		return false
	return true


func _rect_path(a: Vector2, b: Vector2) -> Array:
	var cmds := PackedInt32Array([0, 1, 1, 1, 3])  # MOVE, LINE x3, CLOSE
	var pts := PackedVector2Array([a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)])
	return [cmds, pts]
