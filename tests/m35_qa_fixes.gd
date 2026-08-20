extends SceneTree

# QA fix round for volume-2 §M30–§M35 (2026-08-19):
#  A. M30.8  — renamed-garbage image refused by magic sniff (no decoder call).
#  B. M31.2/7 — all-curve closed SVG paths land CLOSED and extrude (svg.svg).
#  C. M31.1  — DPI override for unitless SVGs; physical sizes ignore it.
#  D. M32.5  — body copies inherit the source color, then take their own.
#  E. M34.1  — sweep re-anchors a far-away profile to its centroid (M34.ecad
#              layout: circle on XZ, spline path on XY, nowhere near it).
#  F. M35.1  — per-corner edge selection: pickable_edges census + a fillet
#              on ONE corner only removes exactly one corner's material.
#  G. ProfileFinder: an open spline looping back onto its start is a face.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	var ok := await _run()
	quit(0 if ok else 1)


func _fail(msg: String) -> bool:
	push_error("m35_qa_fixes: " + msg)
	return false


func _idle():
	await process_frame
	await process_frame


func _click(world: Vector2) -> void:
	var screen: Vector2 = _root.sketch_view.world_to_screen(world)
	_root.tools.handle_pointer_move(world, screen, InputEventMouseMotion.new())
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	_root.tools.handle_pointer_down(world, screen, down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	_root.tools.handle_pointer_up(world, screen, up)


func _write(fname: String, content: String) -> String:
	var path := OS.get_user_data_dir() + "/" + fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return path


func _span_x(sk: Sketch) -> float:
	var span := 0.0
	for e in sk.entities():
		if e.kind() == "point":
			span = maxf(span, (e as SketchPoint).pos.x)
	return span


func _col_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.03


func _body_color(bodies: Array, body_id: String) -> Color:
	for b: Dictionary in bodies:
		if String(b["id"]) == body_id:
			return b.get("color", Color(0, 0, 0, 0))
	return Color(-1, -1, -1, -1)


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	_root.sketch_view.size = Vector2(1000, 700)
	_root.snap.grid_enabled = false
	_root.prefs["inference"] = false
	await _idle()

	# --- A. garbage "image" refused via magic sniff (M30.8) ---------------
	var fake := _write("m35_fake.png", "definitely not an image, renamed")
	var nfeat := _root.doc.features.size()
	if _root.import_canvas(fake) != "":
		return _fail("A: renamed-text canvas accepted")
	if _root.doc.features.size() != nfeat:
		return _fail("A: refused canvas still touched the document")
	if CanvasFeature.sniff_format(FileAccess.get_file_as_bytes(
			"res://tests/wheel.jpg")) != "jpg":
		return _fail("A: JPEG magic not recognized")

	# --- B. all-curve closed SVG paths become closed, extrudable (M31.2/7)
	var fsvg := _root.import_svg("res://tests/svg.svg", "XY")
	if fsvg == "":
		return _fail("B: svg.svg import refused")
	var svg_sk := _root.doc.sketch_feature(fsvg).sketch
	var closed_splines := 0
	for e in svg_sk.entities():
		if e.kind() == "spline" and (e as SketchSpline).closed:
			closed_splines += 1
	if closed_splines != 2:
		return _fail("B: expected 2 closed splines (circle + blob), got %d"
			% closed_splines)
	var profs := ProfileFinder.profiles(svg_sk)
	if profs.size() != 3:
		return _fail("B: expected 3 profiles (square + 2 curve loops), got %d"
			% profs.size())
	# Extrude the bezier "circle" (source center (71.9149, 167.6925) user px,
	# 2.5004in over a 240.04 viewBox, Y-flipped).
	var s := 2.5004 * 25.4 / 240.04
	var anchor := Vector2(71.9149 * s, (240.04 - 167.6925) * s)
	if _root.extrude(fsvg, anchor, 5.0) == "":
		return _fail("B: extruding the imported bezier circle refused")
	_root.stack.undo()   # drop the extrude
	_root.stack.undo()   # drop the import

	# --- C. DPI override for unitless SVGs (M31.1) -------------------------
	var punit := _write("m35_px.svg", """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
  <rect x="0" y="0" width="96" height="96"/>
</svg>""")
	var f96 := _root.import_svg(punit, "XY", 0.0, 96.0)
	if absf(_span_x(_root.doc.sketch_feature(f96).sketch) - 25.4) > 1e-4:
		return _fail("C: dpi 96 should be the native read")
	var f48 := _root.import_svg(punit, "XY", 0.0, 48.0)
	if absf(_span_x(_root.doc.sketch_feature(f48).sketch) - 50.8) > 1e-4:
		return _fail("C: dpi 48 did not double the size")
	var pphys := _write("m35_mm.svg", """
<svg xmlns="http://www.w3.org/2000/svg" width="40mm" height="20mm"
     viewBox="0 0 40 20">
  <rect x="5" y="5" width="10" height="8"/>
</svg>""")
	var fphys := _root.import_svg(pphys, "XY", 0.0, 300.0)
	if absf(_span_x(_root.doc.sketch_feature(fphys).sketch) - 15.0) > 1e-4:
		return _fail("C: DPI must not rescale a physically-sized SVG")
	for _i in 3:
		_root.stack.undo()

	# --- box body shared by D and F ----------------------------------------
	var fbox := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(20, 15), 4.0)
	_root.tools.set_active("rect")
	_click(Vector2(0, 0))
	_click(Vector2(40, 30))
	_root.finish_sketch()
	await _idle()
	var box_id := _root.extrude(fbox, Vector2(20, 15), 10.0)
	await _idle()

	# --- D. copy color: inherit, then own (M32.5) ---------------------------
	var green := Color(0.2, 0.8, 0.3, 1.0)
	var red := Color(0.9, 0.2, 0.2, 1.0)
	if _root.set_body_color(box_id, green) != "":
		return _fail("D: coloring the source refused")
	var copy_id := _root.copy_body(box_id, Vector3(60, 0, 0))
	var bodies: Array = await BodyBuilder.build(_root.doc, _root)
	var inherited := _body_color(bodies, copy_id)
	if inherited.a <= 0.0 or not _col_close(inherited, green):
		return _fail("D: fresh copy did not inherit the source color")
	if _root.set_body_color(copy_id, red) != "":
		return _fail("D: coloring the copy refused")
	bodies = await BodyBuilder.build(_root.doc, _root)
	if not _col_close(_body_color(bodies, copy_id), red):
		return _fail("D: copy did not take its own color")
	if not _col_close(_body_color(bodies, box_id), green):
		return _fail("D: coloring the copy bled onto the source")
	var doc2 := CadDocument.from_dict(_root.doc.to_dict())
	var cf2 := doc2.feature_by_id(copy_id) as CopyBodyFeature
	if cf2 == null or not _col_close(cf2.color, red):
		return _fail("D: copy color lost in serialization")
	_root.stack.undo()   # copy color
	_root.stack.undo()   # copy
	_root.stack.undo()   # source color

	# --- F. per-corner fillet (M35.1) ---------------------------------------
	var root_ef := _root.doc.feature_by_id(box_id) as ExtrudeFeature
	var edges := EdgeTreatFeature.pickable_edges(_root.doc, root_ef)
	var corner_keys: Array = []
	var top_segs := 0
	var bottom_segs := 0
	for e: Dictionary in edges:
		var key := String(e["key"])
		if key.begins_with("corner:"):
			corner_keys.append(key)
		elif key.begins_with("top:"):
			top_segs += 1
		elif key.begins_with("bottom:"):
			bottom_segs += 1
	if corner_keys.size() != 4 or top_segs != 4 or bottom_segs != 4:
		return _fail("F: pickable_edges census wrong (%d corners, %d top, "
			% [corner_keys.size(), top_segs] + "%d bottom)" % bottom_segs)
	var one_corner := [int(String(corner_keys[0]).substr(7))]
	var fid := _root.edge_treat(box_id, EdgeTreatFeature.KIND_FILLET, 5.0,
		true, false, false, one_corner)
	if fid == "":
		return _fail("F: single-corner fillet refused")
	var want := 40.0 * 30.0 * 10.0 - (25.0 - PI * 25.0 / 4.0) * 10.0
	var got := -1.0
	bodies = await BodyBuilder.build(_root.doc, _root)
	for b: Dictionary in bodies:
		if String(b["id"]) == box_id:
			got = BodyBuilder.mesh_volume(b["mesh"])
	if absf(got - want) > want * 0.01:
		return _fail("F: single-corner fillet volume %f vs %f" % [got, want])
	var et2 := CadDocument.from_dict(_root.doc.to_dict()).feature_by_id(
		fid) as EdgeTreatFeature
	if et2 == null or et2.corners != one_corner:
		return _fail("F: corner selection lost in serialization")
	_root.stack.undo()

	# --- E. sweep with the profile far from the path start (M34.1) ---------
	# The M34.ecad layout: 6.35mm-dia circle on XZ at (12.7, 63.5); spline
	# path on XY through five points ~150mm away. Used to refuse as "bend
	# tighter than the profile".
	var fprof := _root.create_sketch("XZ")
	_root.sketch_view.set_view(Vector2(12.7, 63.5), 6.0)
	_root.tools.set_active("circle")
	_click(Vector2(12.7, 63.5))
	_click(Vector2(15.875, 63.5))
	_root.finish_sketch()
	await _idle()
	var fpath := _root.create_sketch("XY")
	_root.sketch_view.set_view(Vector2(90, 215), 1.3)
	_root.tools.set_active("spline")
	for p: Vector2 in [Vector2(50.8, 127), Vector2(50.8, 177.8),
			Vector2(152.4, 203.2), Vector2(152.4, 304.8),
			Vector2(25.4, 304.8)]:
		_click(p)
	if not _root.tools.handle_commit():
		return _fail("E: path spline did not commit")
	_root.finish_sketch()
	await _idle()
	var path_sk := _root.doc.sketch_feature(fpath).sketch
	var spline_id := ""
	for e in path_sk.entities():
		if e.kind() == "spline":
			spline_id = e.id
	var sid := _root.sweep(fprof, Vector2(12.7, 63.5), fpath, spline_id)
	if sid == "":
		return _fail("E: far-profile sweep still refused")
	var sw := _root.doc.feature_by_id(sid) as SweepFeature
	var vol := BodyBuilder.mesh_volume(sw.build_mesh(_root.doc))
	# Tube volume ~ pi r^2 x path length (~384mm chord length, spline a bit
	# longer). Loose bounds — the point is a sane solid, not a refusal.
	var area := PI * 3.175 * 3.175
	if vol < area * 300.0 or vol > area * 550.0:
		return _fail("E: swept tube volume %f implausible" % vol)

	# --- G. open spline looping onto its start is a face --------------------
	var sfl := SketchFeature.make("looptest", "XY")
	var skl: Sketch = sfl.sketch
	var ids: Array = []
	for p: Vector2 in [Vector2(10, 10), Vector2(30, 10), Vector2(30, 30),
			Vector2(10, 30), Vector2(10, 10)]:
		var np := SketchPoint.make(p)
		np.id = skl.next_id()
		skl.add(np)
		ids.append(np.id)
	var spl := SketchSpline.make(ids, false)
	spl.id = skl.next_id()
	skl.add(spl)
	var lprofs := ProfileFinder.profiles(skl)
	if lprofs.size() != 1:
		return _fail("G: welded-loop spline yielded %d faces" % lprofs.size())
	var larea := float(lprofs[0]["area"])
	if larea < 250.0 or larea > 700.0:
		return _fail("G: loop face area %f implausible" % larea)

	print("M35_QA_FIXES OK: image magic sniff, closed SVG curves extrude, ",
		"SVG DPI, copy colors, far-profile sweep, per-corner fillet, ",
		"loop-spline face")
	return true
