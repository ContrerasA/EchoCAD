extends SceneTree

# M2: RenderBridge rasterizes typed entities — line/arc/circle land where the
# view math says they should; construction renders dashed (fewer painted
# pixels than solid); Y-up flip is correct (a point above origin paints in
# the upper image half).


func _init() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m02_render: " + msg)
	return false


func _painted(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.05:
				n += 1
	return n


func _run() -> bool:
	var bridge := RenderBridge.new()
	if not bridge.available():
		return _fail("TVGCanvas missing")

	var sk := Sketch.new()
	var a := SketchPoint.make(Vector2(-40, 0)); a.id = sk.next_id(); sk.add(a)
	var b := SketchPoint.make(Vector2(40, 0)); b.id = sk.next_id(); sk.add(b)
	var line := SketchLine.make(a.id, b.id); line.id = sk.next_id(); sk.add(line)

	# View: 100x100 mm centered on origin -> 200x200 px (zoom 2 px/mm).
	var view := Rect2(-50, -50, 100, 100)
	bridge.full_sync(sk, 2.0)
	var img: Image = bridge.render_image(view, 200, 200)
	if img == null:
		return _fail("render failed")

	# The horizontal line through y=0 paints the middle row band.
	var mid_painted := false
	for x in range(90, 110):
		if img.get_pixel(x, 100).a > 0.05 or img.get_pixel(x, 99).a > 0.05:
			mid_painted = true
			break
	if not mid_painted:
		return _fail("line missing at image center row")
	# Nothing paints in the top quarter (line is at y=0 only).
	for x in range(0, 200, 7):
		for y in range(0, 40, 7):
			if img.get_pixel(x, y).a > 0.05:
				return _fail("unexpected paint in empty top quarter")

	# Y-up: a marker line above origin (sketch y=+30) must paint in the UPPER
	# image half (y_img < 100).
	var c := SketchPoint.make(Vector2(-10, 30)); c.id = sk.next_id(); sk.add(c)
	var d := SketchPoint.make(Vector2(10, 30)); d.id = sk.next_id(); sk.add(d)
	var marker := SketchLine.make(c.id, d.id); marker.id = sk.next_id(); sk.add(marker)
	bridge.full_sync(sk, 2.0)
	img = bridge.render_image(view, 200, 200)
	var upper := false
	for x in range(80, 120):
		if img.get_pixel(x, 40).a > 0.05:   # sketch (x,30) -> pixel y = 100-60 = 40
			upper = true
			break
	if not upper:
		return _fail("Y-up flip wrong: +y line not in upper half")

	# Circle: rim paints at expected pixels, center does not.
	var circle := SketchCircle.make(a.id, 20.0); circle.id = sk.next_id()
	sk.add(circle)
	bridge.full_sync(sk, 2.0)
	img = bridge.render_image(view, 200, 200)
	# center (-40,0) -> px (20,100); rim right point (-20,0) -> px (60,100).
	var rim := false
	for x in range(57, 64):
		if img.get_pixel(x, 100).a > 0.05:
			rim = true
			break
	if not rim:
		return _fail("circle rim missing")

	# Arc: quarter arc from (0,-30) ccw to (30, 0)... center at origin.
	var e0 := SketchPoint.make(Vector2.ZERO); e0.id = sk.next_id(); sk.add(e0)
	var s0 := SketchPoint.make(Vector2(0, -30)); s0.id = sk.next_id(); sk.add(s0)
	var t0 := SketchPoint.make(Vector2(30, 0)); t0.id = sk.next_id(); sk.add(t0)
	var arc := SketchArc.make(e0.id, s0.id, t0.id, true); arc.id = sk.next_id()
	sk.add(arc)
	bridge.full_sync(sk, 2.0)
	img = bridge.render_image(view, 200, 200)
	# ccw from angle -90deg to 0deg passes through angle -45deg:
	# sketch (21.2, -21.2) -> px (142, 142). The OTHER way would pass (−21.2, 21.2).
	var on_arc := false
	for x in range(138, 148):
		for y in range(138, 148):
			if img.get_pixel(x, y).a > 0.05:
				on_arc = true
	if not on_arc:
		return _fail("ccw arc missing at 45deg midpoint")

	# Construction: dashed stroke paints fewer pixels than the same solid line.
	var solid_count := _painted(img)
	line.construction = true
	bridge.full_sync(sk, 2.0)
	var dashed_count := _painted(bridge.render_image(view, 200, 200))
	if dashed_count >= solid_count:
		return _fail("construction line did not render dashed (%d >= %d)"
			% [dashed_count, solid_count])

	print("M02_RENDER OK: line/circle/arc placement, Y-up, dashed construction")
	return true
