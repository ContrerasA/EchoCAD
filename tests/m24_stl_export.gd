extends SceneTree

# M24: STL export — binary layout (header, count, facets, little-endian
# float32), volume of the parsed file matches the body, facet normals unit
# and consistent with their winding, ASCII variant parses, per-body filter,
# visibility filter, empty-document refusal.

var _root: AppRoot = null


func _init() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	quit(0 if _run() else 1)


func _fail(msg: String) -> bool:
	push_error("m24_stl_export: " + msg)
	return false


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


func _sketch_rect(a: Vector2, b: Vector2) -> String:
	var fid := _root.create_sketch("XY")
	_root.sketch_view.size = Vector2(1000, 700)
	_root.sketch_view.set_view(Vector2.ZERO, 4.0)
	_root.snap.grid_enabled = false
	_root.tools.set_active("rect")
	_click(a)
	_click(b)
	_root.finish_sketch()
	return fid


## Parse a binary STL -> {count, volume, normals_ok} (volume via divergence
## theorem over the facets as written).
func _parse_binary(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var header := f.get_buffer(80)
	if header.get_string_from_ascii().begins_with("solid"):
		return {}   # binary STL must not start with "solid"
	var count := f.get_32()
	var vol := 0.0
	var normals_ok := true
	for t in count:
		var n := Vector3(f.get_float(), f.get_float(), f.get_float())
		var a := Vector3(f.get_float(), f.get_float(), f.get_float())
		var b := Vector3(f.get_float(), f.get_float(), f.get_float())
		var c := Vector3(f.get_float(), f.get_float(), f.get_float())
		f.get_16()
		vol += a.cross(b).dot(c) / 6.0
		var want := (b - a).cross(c - a)
		if want.length_squared() > 1e-12:
			if absf(n.length() - 1.0) > 1e-4 \
					or n.dot(want.normalized()) < 0.999:
				normals_ok = false
	var at_end := f.get_position() == f.get_length()
	f.close()
	return {"count": count, "volume": absf(vol), "signed": vol,
		"normals_ok": normals_ok, "at_end": at_end}


func _run() -> bool:
	_root.size = Vector2(1280, 800)
	var dir := OS.get_cache_dir().path_join("echocad_m24")
	DirAccess.make_dir_recursive_absolute(dir)

	# Nothing to export yet.
	if _root.export_stl(dir.path_join("empty.stl")):
		return _fail("empty document export did not refuse")

	# One box body: 40 x 30 x 10 = 12000 mm^3.
	var s1 := _sketch_rect(Vector2(0, 0), Vector2(40, 30))
	var e1 := _root.extrude(s1, Vector2(20, 15), 10.0)
	var p_bin := dir.path_join("box.stl")
	if not _root.export_stl(p_bin):
		return _fail("binary export failed")
	var bin := _parse_binary(p_bin)
	if bin.is_empty():
		return _fail("binary STL malformed (header/open)")
	if not bool(bin["at_end"]):
		return _fail("binary STL has trailing bytes")
	var mesh := (_root.doc.feature_by_id(e1) as ExtrudeFeature) \
		.build_mesh(_root.doc)
	var want_count := StlExporter.mesh_triangles(mesh).size() / 3
	if int(bin["count"]) != want_count:
		return _fail("triangle count %d != mesh %d" % [bin["count"], want_count])
	if absf(float(bin["volume"]) - 12000.0) > 1.0:
		return _fail("parsed volume wrong: %f" % float(bin["volume"]))
	if float(bin["signed"]) < 0.0:
		return _fail("facets wound inward")
	if not bool(bin["normals_ok"]):
		return _fail("facet normals broken")

	# ASCII variant parses and agrees on the facet count.
	var p_asc := dir.path_join("box_ascii.stl")
	if not _root.export_stl(p_asc, "", true):
		return _fail("ascii export failed")
	var text := FileAccess.get_file_as_string(p_asc)
	if not text.begins_with("solid") or not text.contains("endsolid"):
		return _fail("ascii STL framing wrong")
	if text.count("facet normal") != want_count \
			or text.count("vertex") != want_count * 3:
		return _fail("ascii facet census wrong")

	# Second body far away; per-body filter exports only the named one.
	var s2 := _sketch_rect(Vector2(100, 0), Vector2(110, 10))
	var e2 := _root.extrude(s2, Vector2(105, 5), 5.0)
	var p_one := dir.path_join("one.stl")
	if not _root.export_stl(p_one, e2):
		return _fail("per-body export failed")
	var one := _parse_binary(p_one)
	if absf(float(one["volume"]) - 500.0) > 1.0:
		return _fail("per-body volume wrong: %f" % float(one["volume"]))

	# Visibility filter: hide body 2, export all -> body 1 only.
	_root.world.set_body_shown(e2, false)
	var p_vis := dir.path_join("visible.stl")
	if not _root.export_stl(p_vis):
		return _fail("visible-bodies export failed")
	var vis := _parse_binary(p_vis)
	if absf(float(vis["volume"]) - 12000.0) > 1.0:
		return _fail("hidden body leaked into export: %f" % float(vis["volume"]))
	_root.world.set_body_shown(e2, true)

	# Extension is appended when missing.
	if not _root.export_stl(dir.path_join("noext"), e2):
		return _fail("extension-less export failed")
	if not FileAccess.file_exists(dir.path_join("noext.stl")):
		return _fail(".stl extension not appended")

	print("M24_STL_EXPORT OK: binary layout + volume + normals, ascii "
		+ "variant, per-body and visibility filters, extension handling, "
		+ "empty refusal")
	return true
