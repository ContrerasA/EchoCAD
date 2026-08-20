class_name AutomationServer
extends Node
## TCP JSON-RPC server that lets external test runners drive the real app
## like a human: inject input through the normal pipeline, query document and
## view state, run setup actions, capture screenshots. Line-delimited JSON:
## one request object per line in, one response per line out.
##
## Request:  {"id": 1, "cmd": "input.click", "args": {...}}
## Response: {"id": 1, "ok": true, "result": {...}}
##       or  {"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}
##
## Enabled only when the app is launched with --automation-port=<n> (or env
## ECHOCAD_AUTOMATION_PORT). Binds 127.0.0.1 only.
##
## Gestures (input.move / input.drag) interpolate over real frames with an
## ease-in/out profile so hover-dependent code (snap previews, inference
## glyphs) runs exactly as with a mouse; their response is sent when the
## gesture completes. Requests arriving mid-gesture queue up and run after.
## All positions are window pixels; geometry queries speak canonical mm.

const MAX_LINE := 1 << 20

var app: AppRoot = null

var _server: TCPServer = null
var _peers: Array[StreamPeerTCP] = []
var _buffers := {}                  # peer -> String
var _queue: Array = []              # [{peer, request}]
## Non-null while a multi-frame gesture runs: {peer, id, events: Array,
## per_frame: int, sent: int}
var _gesture = null


func start(port: int) -> bool:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("[AutomationServer] cannot listen on %d: %s"
			% [port, error_string(err)])
		return false
	print("[AutomationServer] listening on 127.0.0.1:%d" % port)
	return true


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var p := _server.take_connection()
		_peers.append(p)
		_buffers[p] = ""
	_pump_gesture()
	for p: StreamPeerTCP in _peers.duplicate():
		p.poll()
		var status: int = p.get_status()
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			_peers.erase(p)
			_buffers.erase(p)
			continue
		var avail: int = p.get_available_bytes()
		if avail > 0:
			var chunk: String = p.get_utf8_string(avail)
			_buffers[p] = String(_buffers[p]) + chunk
			if String(_buffers[p]).length() > MAX_LINE:
				_peers.erase(p)
				_buffers.erase(p)
				continue
			_drain_lines(p)
	# Serve queued requests unless a gesture still owns the frame loop.
	while _gesture == null and not _queue.is_empty():
		var item: Dictionary = _queue.pop_front()
		_serve(item["peer"], item["request"])


func _drain_lines(p: StreamPeerTCP) -> void:
	var buf := String(_buffers[p])
	while true:
		var nl := buf.find("\n")
		if nl < 0:
			break
		var line := buf.substr(0, nl).strip_edges()
		buf = buf.substr(nl + 1)
		if line == "":
			continue
		var req: Variant = JSON.parse_string(line)
		if not (req is Dictionary):
			_send(p, {"id": null, "ok": false, "error":
				{"code": "bad_json", "message": "unparseable request line"}})
			continue
		_queue.append({"peer": p, "request": req})
	_buffers[p] = buf


func _send(p: StreamPeerTCP, payload: Dictionary) -> void:
	if p.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		p.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())


func _reply(p: StreamPeerTCP, id: Variant, result: Dictionary) -> void:
	_send(p, {"id": id, "ok": true, "result": result})


func _reply_err(p: StreamPeerTCP, id: Variant, code: String, msg: String) -> void:
	_send(p, {"id": id, "ok": false, "error": {"code": code, "message": msg}})


## --- dispatch ----------------------------------------------------------------

func _serve(p: StreamPeerTCP, req: Dictionary) -> void:
	var id: Variant = req.get("id")
	var cmd := String(req.get("cmd", ""))
	var args: Dictionary = req.get("args", {}) if req.get("args") is Dictionary else {}
	var handler := "_cmd_" + cmd.replace(".", "_")
	if not has_method(handler):
		_reply_err(p, id, "unknown_cmd", "no such command: %s" % cmd)
		return
	var out: Variant = call(handler, args, p, id)
	# Handlers returning null have taken ownership of the reply (gestures).
	if out is Dictionary:
		_reply(p, id, out)


func _vec2(v: Variant) -> Vector2:
	var a := v as Array
	return Vector2(float(a[0]), float(a[1]))


## --- app.* -------------------------------------------------------------------

func _cmd_app_info(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	return {
		"app": "EchoCAD",
		"godot": Engine.get_version_info()["string"],
		"platform": OS.get_name(),
		"headless": DisplayServer.get_name() == "headless",
		"schema": CadDocument.SCHEMA_VERSION,
	}


func _cmd_app_window(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	if a.has("size"):
		get_window().size = Vector2i(_vec2(a["size"]))
	return {"size": [get_window().size.x, get_window().size.y]}


func _cmd_app_screenshot(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_reply_err(p, id, "no_image", "viewport has no readable texture (headless?)")
		return null
	if a.has("path"):
		var err := img.save_png(String(a["path"]))
		if err != OK:
			_reply_err(p, id, "io", "save_png failed: %s" % error_string(err))
			return null
		return {"path": String(a["path"]), "size": [img.get_width(), img.get_height()]}
	return {"png_base64": Marshalls.raw_to_base64(img.save_png_to_buffer()),
		"size": [img.get_width(), img.get_height()]}


## Reliable in headless too: rasterize the active sketch through the bridge.
func _cmd_app_sketch_image(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if app.mode != AppRoot.Mode.SKETCH:
		_reply_err(p, id, "bad_state", "not in sketch mode")
		return null
	var sv := app.sketch_view
	var w := int(a.get("width", int(sv.size.x)))
	var h := int(a.get("height", int(sv.size.y)))
	var img := app.bridge.render_image(sv.view_rect(), w, h)
	if img == null:
		_reply_err(p, id, "no_image", "bridge render failed")
		return null
	if a.has("path"):
		img.save_png(String(a["path"]))
		return {"path": String(a["path"]), "size": [w, h]}
	return {"png_base64": Marshalls.raw_to_base64(img.save_png_to_buffer()),
		"size": [w, h]}


func _cmd_app_quit(_a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	_reply(p, id, {"quitting": true})
	# Let the reply flush this frame; quit next frame.
	get_tree().quit.call_deferred(0)
	return null


## --- query.* -----------------------------------------------------------------

func _cmd_query_mode(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	return {
		"mode": "sketch" if app.mode == AppRoot.Mode.SKETCH else "model",
		"active_sketch": app.active_sketch_id,
		"picking_plane": app.picking_plane,
		"sketch_orbit": app.sketch_orbit,
	}


## Where a view-cube face sits on screen, for aiming real clicks at it.
## args: {"plane": "XY"} or {"normal": [x,y,z]} -> {ok, x, y}; `ok` is false
## when that face is turned away from the cube camera.
func _cmd_query_cube_face(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var n: Vector3
	if a.has("plane"):
		n = SketchFeature.plane_basis(String(a["plane"])).z
	elif a.has("normal"):
		var arr: Array = a["normal"]
		n = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	else:
		_reply_err(p, id, "invalid", "need plane or normal")
		return null
	return app.view_cube.face_screen_px(n)


func _cmd_query_document(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	return app.doc.to_dict()


func _sketch_for(a: Dictionary) -> Sketch:
	var fid := String(a.get("sketch", app.active_sketch_id))
	var f := app.doc.sketch_feature(fid)
	return f.sketch if f != null else null


func _cmd_query_entities(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := _sketch_for(a)
	if sk == null:
		_reply_err(p, id, "bad_args", "no such sketch")
		return null
	var out: Array = []
	for e in sk.entities():
		var d := e.to_dict()
		# Flag the sketch's origin point. It is a real entity (snappable,
		# dimensionable) but it is scaffolding every sketch has rather than
		# something a tool drew, so callers counting authored geometry need to
		# be able to tell it apart.
		if sk.is_origin(e.id):
			d["origin"] = true
		out.append(d)
	return {"entities": out, "origin": sk.origin_id()}


func _cmd_query_constraints(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := _sketch_for(a)
	if sk == null:
		_reply_err(p, id, "bad_args", "no such sketch")
		return null
	var out: Array = []
	for i in sk.constraints.size():
		var c := sk.constraints[i]
		var d := c.to_dict()
		d["index"] = i
		d["satisfied"] = ConstraintSolver.error_of(sk, c) <= 0.01
		out.append(d)
	return {"constraints": out}


func _cmd_action_select(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.set_selection(a.get("ids", []))
	return {"selection": Array(app.selection)}


func _cmd_action_add_constraint(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := app.active_sketch()
	if sk == null:
		_reply_err(p, id, "bad_state", "not in a sketch")
		return null
	var tname := String(a.get("type", ""))
	var tidx := (SketchConstraint.Type.keys() as Array).find(tname)
	if tidx < 0:
		_reply_err(p, id, "bad_args", "unknown constraint type %s" % tname)
		return null
	if a.has("operands"):
		app.set_selection(a["operands"])
	var value := float(a["value"]) if a.has("value") else NAN
	var why := app.apply_constraint(tidx as SketchConstraint.Type, value)
	if why != "":
		_reply_err(p, id, "invalid", why)
		return null
	return {"index": sk.constraints.size() - 1,
		"dof": DofAnalyzer.summary(sk)}


func _cmd_query_parameters(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var out: Array = []
	for prm in app.doc.parameters:
		out.append(prm.to_dict())
	return {"parameters": out}


## Create or update a named parameter: {name, expr, unit?("mm"/"in"/...,
## omit = scalar)}. Re-values dependent dimensions + re-solves (one step).
func _cmd_action_set_parameter(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var pname := String(a.get("name", ""))
	if not CadExpression.valid_name(pname):
		_reply_err(p, id, "bad_args", "invalid parameter name %s" % pname)
		return null
	var unit: int = CadParameter.UNIT_SCALAR
	if a.has("unit"):
		unit = UnitConverter.unit_from_string(String(a["unit"]))
	var new_list: Array = []
	var found := false
	for prm in app.doc.parameters:
		if prm.name == pname:
			var np := prm.duplicate_parameter()
			np.expr = String(a.get("expr", prm.expr))
			np.unit = unit if a.has("unit") else prm.unit
			new_list.append(np)
			found = true
		else:
			new_list.append(prm)
	if not found:
		new_list.append(CadParameter.make(pname, String(a.get("expr", "0")), unit))
	var resolved := CadExpression.evaluate_params(new_list)
	for prm: CadParameter in new_list:
		prm.value = float((resolved["values"] as Dictionary).get(prm.name, 0.0))
	app.set_parameters(new_list)
	return {"values": resolved["values"], "errors": resolved["errors"]}


## Delete a parameter (refused while referenced — same rule as the dialog).
func _cmd_action_delete_parameter(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var why := app.remove_parameter(String(a.get("name", "")))
	if why != "":
		_reply_err(p, id, "invalid", why)
		return null
	return {"count": app.doc.parameters.size()}


func _cmd_action_set_dimension(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var index := int(a.get("index", -1))
	var batch := CmdMergeBatch.new("Edit Dimension", [])
	app.stack.push_no_merge(batch)
	var why := app.set_dimension_value(index, String(a.get("text", "")))
	batch.seal()
	if why != "":
		_reply_err(p, id, "invalid", why)
		return null
	var sk := app.active_sketch()
	return {"value": sk.constraints[index].value,
		"expr": sk.constraints[index].expr}


func _cmd_action_set_driven(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.set_dimension_driven(int(a.get("index", -1)), bool(a.get("driven", true)))
	return {}


func _cmd_action_delete_constraint(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := app.active_sketch()
	if sk == null:
		_reply_err(p, id, "bad_state", "not in a sketch")
		return null
	var index := int(a.get("index", -1))
	if index < 0 or index >= sk.constraints.size():
		_reply_err(p, id, "bad_args", "no constraint %d" % index)
		return null
	app.delete_constraint(index)
	return {"count": sk.constraints.size()}


func _cmd_query_timeline(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var feats: Array = []
	for f in app.doc.features:
		feats.append({"id": f.id, "kind": f.kind(), "name": f.name,
			"suppressed": f.suppressed})
	return {"features": feats, "marker": app.doc.timeline_marker}


func _cmd_query_view(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var sv := app.sketch_view
	return {
		"zoom": sv.zoom(),
		"pan": [sv.pan().x, sv.pan().y],
		"size": [sv.size.x, sv.size.y],
		"camera_rotation": [app.rig.rotation.x, app.rig.rotation.y,
			app.rig.rotation.z],
		"camera_distance": app.rig.distance,
		"ortho": app.rig.is_orthographic(),
		"view_height_mm": app.rig.view_height_mm(),
		"camera_target": [app.rig.target.x, app.rig.target.y,
			app.rig.target.z],
	}


## --- M27 viewing -------------------------------------------------------------

func _cmd_action_look_at(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not a.has("normal"):
		_reply_err(p, id, "bad_args", "normal required")
		return null
	var n := a["normal"] as Array
	var normal := Vector3(float(n[0]), float(n[1]), float(n[2]))
	if normal.length() < 1e-9:
		_reply_err(p, id, "bad_args", "normal is zero")
		return null
	var up := Vector3(0, 0, 1)
	if a.has("up"):
		var u := a["up"] as Array
		up = Vector3(float(u[0]), float(u[1]), float(u[2]))
	app.look_at_normal(normal.normalized(), up)
	return {"ok": true}


func _cmd_action_fit(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.fit_view()
	return {"view_height_mm": app.rig.view_height_mm()}


func _cmd_action_set_display_unit(a: Dictionary, p: StreamPeerTCP,
		id: Variant) -> Variant:
	var s := String(a.get("unit", ""))
	var u := UnitConverter.unit_from_string(s, UnitConverter.Unit.MM)
	if UnitConverter.unit_to_string(u) != s:
		_reply_err(p, id, "bad_args", "unknown unit %s" % s)
		return null
	app.set_display_unit(u)
	return {"unit": UnitConverter.unit_to_string(app.doc.display_unit)}


func _cmd_action_save_view(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var d := app.save_named_view(String(a.get("name", "")))
	return {"view": d, "count": app.doc.named_views.size()}


func _cmd_action_apply_view(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var view_name := String(a.get("name", ""))
	for v in app.doc.named_views:
		if String((v as Dictionary).get("name", "")) == view_name:
			app.apply_named_view(v)
			return {"ok": true}
	_reply_err(p, id, "not_found", "no view named %s" % view_name)
	return null


## --- M35 3D fillet / chamfer -------------------------------------------------

func _cmd_action_fillet_edges(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	return _edge_treat(a, p, id, EdgeTreatFeature.KIND_FILLET)


func _cmd_action_chamfer_edges(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	return _edge_treat(a, p, id, EdgeTreatFeature.KIND_CHAMFER)


func _edge_treat(a: Dictionary, p: StreamPeerTCP, id: Variant,
		treat_kind: String) -> Variant:
	var fid := app.edge_treat(String(a.get("body", "")), treat_kind,
		float(a.get("size", 3.0)), bool(a.get("lateral", true)),
		bool(a.get("top", true)), bool(a.get("bottom", false)),
		a.get("corners", []) as Array,
		a.get("top_segs", []) as Array,
		a.get("bottom_segs", []) as Array)
	if fid == "":
		_reply_err(p, id, "bad_args", "edge treatment refused (see status)")
		return null
	return {"feature": fid}


## --- M34 sweep + loft --------------------------------------------------------

func _cmd_action_sweep(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := app.sweep(String(a.get("sketch", "")), _vec2(a.get("at", [0, 0])),
		String(a.get("path_sketch", "")), String(a.get("path_entity", "")),
		String(a.get("op", SolidFeature.OP_NEW_BODY)))
	if fid == "":
		_reply_err(p, id, "bad_args", "sweep refused (see status hint)")
		return null
	var f := app.doc.feature_by_id(fid) as SweepFeature
	var mesh := f.build_mesh(app.doc)
	return {"feature": fid,
		"volume": BodyBuilder.mesh_volume(mesh) if mesh != null else 0.0}


func _cmd_action_loft(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sections: Array = []
	for sec in a.get("sections", []):
		sections.append({"sketch": String((sec as Dictionary).get("sketch", "")),
			"at": _vec2((sec as Dictionary).get("at", [0, 0]))})
	var fid := app.loft(sections, String(a.get("op", SolidFeature.OP_NEW_BODY)))
	if fid == "":
		_reply_err(p, id, "bad_args", "loft refused (see status hint)")
		return null
	var f := app.doc.feature_by_id(fid) as LoftFeature
	var mesh := f.build_mesh(app.doc)
	return {"feature": fid,
		"volume": BodyBuilder.mesh_volume(mesh) if mesh != null else 0.0}


## --- M33 solid mirror + patterns ---------------------------------------------

func _cmd_action_mirror_body(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := app.mirror_body(String(a.get("body", "")),
		String(a.get("plane", "XY")))
	if fid == "":
		_reply_err(p, id, "bad_args", "mirror failed (see status hint)")
		return null
	return {"feature": fid}


func _cmd_action_pattern_body(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var props := {}
	if a.has("mode"):
		props["mode"] = String(a["mode"])
	for k in ["count1", "count2"]:
		if a.has(k):
			props[k] = int(a[k])
	for k in ["offset1", "offset2", "axis_origin", "axis_dir"]:
		if a.has(k):
			var v: Array = a[k]
			props[k] = Vector3(float(v[0]), float(v[1]), float(v[2]))
	if a.has("total_deg"):
		props["total_deg"] = float(a["total_deg"])
	var fid := app.pattern_body(String(a.get("body", "")), props)
	if fid == "":
		_reply_err(p, id, "bad_args", "pattern refused (see status hint)")
		return null
	return {"feature": fid}


## --- M32 move / copy bodies + appearance -------------------------------------

func _cmd_action_move_body(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var body := String(a.get("body", ""))
	var t: Array = a.get("translation", [0, 0, 0])
	var axis: Array = a.get("axis", [0, 0, 1])
	var fid := app.move_body(body,
		Vector3(float(t[0]), float(t[1]), float(t[2])),
		Vector3(float(axis[0]), float(axis[1]), float(axis[2])),
		float(a.get("angle", 0.0)))
	if fid == "":
		_reply_err(p, id, "bad_args", "zero move refused")
		return null
	return {"feature": fid}


func _cmd_action_copy_body(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var t: Array = a.get("translation", [0, 0, 0])
	var fid := app.copy_body(String(a.get("body", "")),
		Vector3(float(t[0]), float(t[1]), float(t[2])))
	return {"feature": fid}


func _cmd_action_set_body_color(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var c: Array = a.get("color", [0.5, 0.5, 0.5])
	var err := app.set_body_color(String(a.get("body", "")),
		Color(float(c[0]), float(c[1]), float(c[2])))
	if err != "":
		_reply_err(p, id, "bad_args", err)
		return null
	return {"ok": true}


## --- M31 SVG import ----------------------------------------------------------

func _cmd_action_import_svg(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := app.import_svg(String(a.get("path", "")),
		String(a.get("plane", "XY")), float(a.get("width", 0.0)))
	if fid == "":
		_reply_err(p, id, "bad_args", "svg import failed (see status hint)")
		return null
	var sf := app.doc.sketch_feature(fid)
	var census := {"lines": 0, "arcs": 0, "circles": 0, "splines": 0,
		"points": 0}
	for e in sf.sketch.entities():
		var k := e.kind() + "s"
		if census.has(k):
			census[k] += 1
	census["feature"] = fid
	census["name"] = sf.name
	return census


## --- M30 canvases ------------------------------------------------------------

func _cmd_action_import_canvas(a: Dictionary, p: StreamPeerTCP,
		id: Variant) -> Variant:
	var fid := app.import_canvas(String(a.get("path", "")),
		String(a.get("plane", "")), float(a.get("width", 0.0)))
	if fid == "":
		_reply_err(p, id, "bad_args", "canvas import failed (see status)")
		return null
	return _canvas_info(fid)


func _cmd_action_set_canvas(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("feature", ""))
	if app.doc.feature_by_id(fid) as CanvasFeature == null:
		_reply_err(p, id, "not_found", "no canvas %s" % fid)
		return null
	var props := {}
	if a.has("center"):
		props["center"] = _vec2(a["center"])
	for k in ["width_mm", "rotation", "opacity"]:
		if a.has(k):
			props[k] = float(a[k])
	if a.has("locked"):
		props["locked"] = bool(a["locked"])
	app.stack.push_no_merge(CmdSetCanvasProps.new(fid, props))
	return _canvas_info(fid)


func _cmd_action_calibrate_canvas(a: Dictionary, p: StreamPeerTCP,
		id: Variant) -> Variant:
	var err := app.apply_canvas_calibration(String(a.get("feature", "")),
		_vec2(a.get("a", [0, 0])), _vec2(a.get("b", [0, 0])),
		float(a.get("distance", 0.0)))
	if err != "":
		_reply_err(p, id, "bad_args", err)
		return null
	return _canvas_info(String(a.get("feature", "")))


func _cmd_query_canvas(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("feature", ""))
	if app.doc.feature_by_id(fid) as CanvasFeature == null:
		_reply_err(p, id, "not_found", "no canvas %s" % fid)
		return null
	return _canvas_info(fid)


func _canvas_info(fid: String) -> Dictionary:
	var cf := app.doc.feature_by_id(fid) as CanvasFeature
	return {"feature": cf.id, "name": cf.name, "plane": cf.plane,
		"center": [cf.center.x, cf.center.y], "width_mm": cf.width_mm,
		"height_mm": cf.height_mm(), "rotation": cf.rotation,
		"opacity": cf.opacity, "locked": cf.locked}


## Measurement of a selection (or explicit ids) — same numbers the status
## readout formats. args: {ids?: [..]} (defaults to the live selection).
func _cmd_query_measure(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := app.active_sketch()
	if sk == null:
		_reply_err(p, id, "bad_state", "not in a sketch")
		return null
	var ids: Array = a.get("ids", app.selection)
	var m := Measure.analyze(sk, ids)
	m["text"] = Measure.describe(sk, ids, app.doc.display_unit)
	return m


## Sketch mm -> WINDOW pixels (what input.* takes).
func _cmd_query_world_to_screen(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not a.has("p"):
		_reply_err(p, id, "bad_args", "missing p")
		return null
	var s := app.sketch_view.world_to_screen(_vec2(a["p"])) \
		+ app.sketch_view.get_global_rect().position
	return {"p": [s.x, s.y]}


func _cmd_query_screen_to_world(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not a.has("p"):
		_reply_err(p, id, "bad_args", "missing p")
		return null
	var w := app.sketch_view.screen_to_world(
		_vec2(a["p"]) - app.sketch_view.get_global_rect().position)
	return {"p": [w.x, w.y]}


## Project a point ON a named origin plane to screen pixels, so automation can
## CLICK that plane without hardcoding a pixel.
##
## `plane` is "XY"/"XZ"/"YZ"; `uv` is millimetres along that plane's own two
## axes, defaulting to the middle of its quad. The origin planes are quads
## running from the origin out along +u/+v, so the world origin is their shared
## CORNER — the middle of the window (the obvious-looking click target) lands
## exactly on that knife edge and hits a plane only by luck. Asking for a point
## in the plane's own terms keeps a test correct across changes to the camera
## home view or the quad size.
##
## Returns {"p": [x, y], "visible": bool} — `visible` is false when the point
## is behind the camera or off-window, which a caller should treat as "do not
## click there" rather than clicking anyway.
func _cmd_query_plane_point(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var plane := String(a.get("plane", "XY"))
	if not SketchFeature.PLANES.has(plane):
		_reply_err(p, id, "bad_args", "unknown plane '%s'" % plane)
		return null
	var half := CadWorld.PLANE_SIDE * 0.5
	var uv := _vec2(a["uv"]) if a.has("uv") else Vector2(half, half)
	var basis := SketchFeature.plane_basis(plane)
	var world: Vector3 = basis.x * uv.x + basis.y * uv.y
	var cam := app.rig.camera
	var behind := cam.is_position_behind(world)
	# unproject_position is in the SubViewport's pixels; the same offset the
	# sketch-view queries apply puts it in window pixels, which is what the
	# input commands take.
	var rect := app.viewport_rect()
	var s := cam.unproject_position(world) + rect.position
	var on_screen := not behind and rect.has_point(s)
	return {"p": [s.x, s.y], "visible": on_screen}


## Global rect of a named control under AppRoot (for driving real UI).
func _cmd_query_control(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var node := app.find_child(String(a.get("name", "")), true, false) as Control
	if node == null:
		_reply_err(p, id, "not_found", "no control named %s" % a.get("name"))
		return null
	var r := node.get_global_rect()
	# Controls inside an embedded sub-window (popups, dialogs) report rects in
	# that window's own space — shift them into main-window pixels so a click
	# aimed at the rect lands.
	var w := node.get_window()
	if w != null and w != get_window() and w.is_embedded():
		r.position += Vector2(w.position)
	var out := {"rect": [r.position.x, r.position.y, r.size.x, r.size.y],
		"visible": node.is_visible_in_tree(),
		"disabled": node.disabled if node is BaseButton else false}
	# What the control SAYS, so a client can assert the status bar / a button
	# face without screenshotting and reading pixels.
	if node is Label:
		out["text"] = (node as Label).text
	elif node is BaseButton and node is Button:
		out["text"] = (node as Button).text
	# Buttons inside a ribbon flyout (M36 stacks) are only visible while the
	# flyout is open — name the stack button that opens it so a client can
	# right-click it first and then click the real control.
	var p2: Node = node.get_parent()
	while p2 != null and not (p2 is PopupPanel):
		p2 = p2.get_parent()
	if p2 != null and p2.name == "Flyout" and p2.get_parent() is Button:
		out["flyout_owner"] = String(p2.get_parent().name)
	return out


func _cmd_query_dof(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var sk := _sketch_for(a)
	if sk == null:
		_reply_err(p, id, "bad_args", "no such sketch")
		return null
	var r := DofAnalyzer.analyze(sk)
	r["summary"] = DofAnalyzer.summary(sk)
	return r


func _cmd_query_undo_stack(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var undo_names: Array = []
	for c: Command in app.stack._undo:
		undo_names.append(c.name)
	return {"undo": undo_names, "can_redo": app.stack.can_redo()}


func _cmd_query_active_tool(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	return {"tool": app.tools.active_id(), "tools": app.tools.tool_ids()}


func _cmd_query_selection(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	# `selected_constraint` is a separate selection channel from `selection`
	# (entities): clicking a dimension label selects the CONSTRAINT, which is
	# what makes typing edit its value. Reporting only the entity list made a
	# label click look like it had selected nothing at all.
	return {"selection": Array(app.selection),
		"constraint": app.selected_constraint,
		"dim_hits": app.dim_hits.size()}


## --- action.* ----------------------------------------------------------------


func _cmd_action_activate_tool(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var tid := String(a.get("tool", ""))
	if app.tools.get_tool(tid) == null:
		_reply_err(p, id, "not_found", "no tool %s" % tid)
		return null
	app.tools.set_active(tid)
	return {"tool": app.tools.active_id()}


func _cmd_query_profiles(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("sketch", app.active_sketch_id))
	var sf := app.doc.sketch_feature(fid)
	if sf == null:
		_reply_err(p, id, "bad_args", "no such sketch")
		return null
	var out: Array = []
	for prof: Dictionary in ProfileFinder.profiles(sf.sketch):
		out.append({"area": prof["area"],
			"entities": prof["entities"],
			"vertex_count": (prof["polygon"] as PackedVector2Array).size(),
			"holes": (prof.get("holes", []) as Array).size()})
	return {"profiles": out}


func _cmd_action_extrude(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("sketch", ""))
	var at := _vec2(a.get("at", [0, 0]))
	var dist := float(a.get("distance", 10.0))
	var op := String(a.get("operation", ExtrudeFeature.OP_NEW_BODY))
	if not op in [ExtrudeFeature.OP_NEW_BODY, ExtrudeFeature.OP_JOIN,
			ExtrudeFeature.OP_CUT]:
		_reply_err(p, id, "bad_args", "unknown operation %s" % op)
		return null
	var eid := app.extrude(fid, at, dist, op)
	if eid == "":
		_reply_err(p, id, "invalid", "no closed profile at that point")
		return null
	var f := app.doc.feature_by_id(eid) as ExtrudeFeature
	var mesh := f.build_mesh(app.doc)
	# `volume` is the feature's own prism (pre-boolean, compatible with the
	# M12 contract); `body_volume` is the boolean result of the body this
	# feature landed in ({} of a cut that touched nothing -> 0).
	var body_volume := 0.0
	for b: Dictionary in await BodyBuilder.build(app.doc, app):
		if (b["feature_ids"] as Array).has(eid):
			body_volume = BodyBuilder.mesh_volume(b["mesh"])
			break
	_reply(p, id, {"feature": eid, "name": f.name, "operation": op,
		"volume": ExtrudeFeature.mesh_volume(mesh) if mesh != null else 0.0,
		"body_volume": body_volume})
	return null


## Revolve a region (M23). args: {sketch, at:[u,v], axis: "x"|"y"|line id,
## angle (deg, default 360), operation}. Same response contract as extrude.
func _cmd_action_revolve(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("sketch", ""))
	var at := _vec2(a.get("at", [0, 0]))
	var axis := String(a.get("axis", "x"))
	var angle := float(a.get("angle", 360.0))
	var op := String(a.get("operation", SolidFeature.OP_NEW_BODY))
	if not op in [SolidFeature.OP_NEW_BODY, SolidFeature.OP_JOIN,
			SolidFeature.OP_CUT]:
		_reply_err(p, id, "bad_args", "unknown operation %s" % op)
		return null
	var rid := app.revolve(fid, at, axis, angle, op)
	if rid == "":
		_reply_err(p, id, "invalid",
			"no region/axis there, or the region straddles the axis")
		return null
	var f := app.doc.feature_by_id(rid) as RevolveFeature
	var mesh := f.build_mesh(app.doc)
	var body_volume := 0.0
	for b: Dictionary in await BodyBuilder.build(app.doc, app):
		if (b["feature_ids"] as Array).has(rid):
			body_volume = BodyBuilder.mesh_volume(b["mesh"])
			break
	_reply(p, id, {"feature": rid, "name": f.name, "operation": op,
		"volume": BodyBuilder.mesh_volume(mesh) if mesh != null else 0.0,
		"body_volume": body_volume})
	return null


## Boolean-resolved solid bodies (M18): id/name/features/volume/aabb each.
func _cmd_query_bodies(_a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var out: Array = []
	for b: Dictionary in await BodyBuilder.build(app.doc, app):
		var mesh: ArrayMesh = b["mesh"]
		var box := mesh.get_aabb()
		out.append({"id": b["id"], "name": b["name"],
			"features": b["feature_ids"],
			"volume": BodyBuilder.mesh_volume(mesh),
			"aabb": [box.position.x, box.position.y, box.position.z,
				box.size.x, box.size.y, box.size.z]})
	_reply(p, id, {"bodies": out})
	return null


func _cmd_action_set_marker(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var to := clampi(int(a.get("marker", app.doc.features.size())),
		0, app.doc.features.size())
	var cmd := CmdSetMarker.new(app.doc.timeline_marker, to)
	cmd.open = false
	app.stack.push_no_merge(cmd)
	return {"marker": app.doc.timeline_marker}


func _cmd_action_suppress(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("feature", ""))
	var f := app.doc.feature_by_id(fid)
	if f == null:
		_reply_err(p, id, "not_found", "no feature %s" % fid)
		return null
	app.stack.push_no_merge(CmdSetFeatureFlag.new(fid, "suppressed",
		bool(a.get("suppressed", true))))
	return {"suppressed": f.suppressed}


func _cmd_action_set_pref(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	if a.has("inference"):
		app.prefs["inference"] = bool(a["inference"])
	if a.has("grid_snap"):
		app.snap.grid_enabled = bool(a["grid_snap"])
	if a.has("entity_snap"):
		app.snap.entity_snap_enabled = bool(a["entity_snap"])
	if a.has("dark_theme"):
		app.set_dark_theme(bool(a["dark_theme"]))
	if a.has("ortho"):
		app.set_model_projection(bool(a["ortho"]))
	if a.has("tool_names"):
		app.set_show_tool_names(bool(a["tool_names"]))
	# The toolbar checkboxes show this same state — refresh them, or the hand
	# path and the RPC path would disagree about what is on.
	app.sync_pref_checks()
	return {"inference": app.prefs["inference"],
		"grid_snap": app.snap.grid_enabled,
		"entity_snap": app.snap.entity_snap_enabled,
		"dark_theme": ThemeService.dark,
		"tool_names": ThemeService.show_tool_names,
		"ortho": app.rig.is_orthographic()}

func _cmd_action_enter_sketch(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	# An origin-plane name or a construction plane's feature id (M22).
	var plane := String(a.get("plane", "XY"))
	if not SketchFeature.PLANES.has(plane) \
			and app.doc.plane_feature(plane) == null:
		_reply_err(p, id, "bad_args", "unknown plane %s" % plane)
		return null
	var fid := app.create_sketch(plane)
	return {"feature": fid}


## Create an offset construction plane (M22). args: {base, offset} — base an
## origin-plane name or plane feature id, offset in mm.
func _cmd_action_create_offset_plane(a: Dictionary, p: StreamPeerTCP,
		id: Variant) -> Variant:
	var base := String(a.get("base", "XY"))
	var fid := app.create_offset_plane(base, float(a.get("offset", 0.0)))
	if fid == "":
		_reply_err(p, id, "bad_args", "unknown base plane %s" % base)
		return null
	var pf := app.doc.plane_feature(fid)
	return {"feature": fid, "name": pf.name}


## Edit an offset plane's distance (M22). args: {plane, offset(mm)}.
func _cmd_action_set_plane_offset(a: Dictionary, p: StreamPeerTCP,
		id: Variant) -> Variant:
	var fid := String(a.get("plane", ""))
	var pf := app.doc.plane_feature(fid)
	if pf == null or pf.plane_kind != PlaneFeature.KIND_OFFSET:
		_reply_err(p, id, "bad_args", "no offset plane %s" % fid)
		return null
	app.stack.push_no_merge(CmdSetPlaneOffset.new(fid, float(a.get("offset", 0.0))))
	return {"feature": fid, "offset": pf.offset}


## Resolved world transform of any plane ref (origin name or feature id).
func _cmd_query_plane_transform(a: Dictionary, _p: StreamPeerTCP,
		_id: Variant) -> Dictionary:
	var xf: Transform3D = app.doc.plane_transform(String(a.get("plane", "XY")))
	return {"basis": [xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
		xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
		xf.basis.z.x, xf.basis.z.y, xf.basis.z.z],
		"origin": [xf.origin.x, xf.origin.y, xf.origin.z]}


func _cmd_action_edit_sketch(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("feature", ""))
	if app.doc.sketch_feature(fid) == null:
		_reply_err(p, id, "not_found", "no sketch feature %s" % fid)
		return null
	app.edit_sketch(fid)
	return {"feature": fid}


func _cmd_action_finish_sketch(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.finish_sketch()
	return {}


func _cmd_action_undo(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.stack.undo()
	return {"can_undo": app.stack.can_undo(), "can_redo": app.stack.can_redo()}


func _cmd_action_redo(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.stack.redo()
	return {"can_undo": app.stack.can_undo(), "can_redo": app.stack.can_redo()}


func _cmd_action_save(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not a.has("path"):
		_reply_err(p, id, "bad_args", "missing path")
		return null
	if not Serializer.save(app.doc, String(a["path"])):
		_reply_err(p, id, "io", "save failed")
		return null
	app.stack.mark_saved()
	return {"path": String(a["path"])}


## Switch the UI theme by id (M36). args: {theme}. Replies with the id that
## actually loaded (unknown ids fall back to the default) and the catalog.
func _cmd_action_set_theme(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var loaded := app.set_theme_id(String(a.get("theme", "")))
	return {"theme": loaded, "dark": ThemeService.dark}


func _cmd_query_theme(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var ids: Array = []
	for t: Dictionary in ThemeService.available_themes():
		ids.append({"id": t["id"], "name": t["name"], "builtin": t["builtin"],
			"appearance": t["appearance"]})
	return {"theme": ThemeService.theme_id, "dark": ThemeService.dark,
		"available": ids, "user_dir": ThemeService.user_theme_dir()}


func _cmd_action_open(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var doc := Serializer.load_file(String(a.get("path", "")))
	if doc == null:
		_reply_err(p, id, "io", "load failed")
		return null
	app.load_document(doc)
	return {"features": doc.features.size()}


## Export one sketch as DXF R12: {path, sketch? (default: the app's
## unambiguous target — active sketch, or the document's only one)}.
## Export bodies to STL (M24). args: {path, body?: feature id, ascii?}.
## Bodies come from a fresh BodyBuilder pass (not the display cache), so the
## result always matches the current document.
func _cmd_action_export_stl(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var path := String(a.get("path", ""))
	if path == "":
		_reply_err(p, id, "bad_args", "missing path")
		return null
	var body := String(a.get("body", ""))
	var wanted: Array = []
	for b: Dictionary in await BodyBuilder.build(app.doc, app):
		if body != "" and String(b["id"]) != body:
			continue
		wanted.append(b)
	if not path.to_lower().ends_with(".stl"):
		path += ".stl"
	var res := StlExporter.write(wanted, path, bool(a.get("ascii", false)))
	if not bool(res["ok"]):
		_reply_err(p, id, "invalid", String(res["error"]))
		return null
	_reply(p, id, {"path": path, "triangles": int(res["triangles"]),
		"bodies": wanted.size()})
	return null


## Import a DXF as a new sketch (M25). args: {path, plane?}.
func _cmd_action_import_dxf(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var path := String(a.get("path", ""))
	if path == "":
		_reply_err(p, id, "bad_args", "missing path")
		return null
	var fid := app.import_dxf(path, String(a.get("plane", "XY")))
	if fid == "":
		_reply_err(p, id, "invalid", "import failed (see status hint)")
		return null
	var sf := app.doc.sketch_feature(fid)
	var census := {"lines": 0, "arcs": 0, "circles": 0, "points": 0}
	for e in sf.sketch.entities():
		match e.kind():
			"line":
				census["lines"] += 1
			"arc":
				census["arcs"] += 1
			"circle":
				census["circles"] += 1
	return {"feature": fid, "name": sf.name, "lines": census["lines"],
		"arcs": census["arcs"], "circles": census["circles"]}


func _cmd_action_export_dxf(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var path := String(a.get("path", ""))
	if path == "":
		_reply_err(p, id, "bad_args", "missing path")
		return null
	var sk: Sketch = null
	if a.has("sketch"):
		var sf := app.doc.sketch_feature(String(a["sketch"]))
		if sf == null:
			_reply_err(p, id, "bad_args", "no such sketch")
			return null
		sk = sf.sketch
	else:
		sk = app._dxf_target_sketch()
		if sk == null:
			_reply_err(p, id, "bad_state", "no unambiguous sketch to export")
			return null
	if not path.to_lower().ends_with(".dxf"):
		path += ".dxf"
	var why := DxfExporter.save(sk, path, bool(a.get("construction", true)))
	if why != "":
		_reply_err(p, id, "io", why)
		return null
	return {"path": path}


func _cmd_action_new_document(_a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	app.load_document(CadDocument.new())
	return {}


func _cmd_action_set_view(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	if a.has("pan") and a.has("zoom"):
		app.sketch_view.set_view(_vec2(a["pan"]), float(a["zoom"]))
	return {"zoom": app.sketch_view.zoom(),
		"pan": [app.sketch_view.pan().x, app.sketch_view.pan().y]}


## --- input.* -----------------------------------------------------------------

const BUTTONS := {"left": MOUSE_BUTTON_LEFT, "middle": MOUSE_BUTTON_MIDDLE,
	"right": MOUSE_BUTTON_RIGHT, "wheel_up": MOUSE_BUTTON_WHEEL_UP,
	"wheel_down": MOUSE_BUTTON_WHEEL_DOWN}

var _pointer := Vector2.ZERO
var _button_mask := 0
var _modifiers := {"shift": false, "ctrl": false, "alt": false}


func _apply_mods(ev: InputEventWithModifiers, a: Dictionary) -> void:
	var mods: Array = a.get("modifiers", [])
	ev.shift_pressed = _modifiers["shift"] or mods.has("shift")
	ev.ctrl_pressed = _modifiers["ctrl"] or mods.has("ctrl")
	ev.alt_pressed = _modifiers["alt"] or mods.has("alt")


func _motion_event(to: Vector2, a: Dictionary) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = to
	ev.global_position = to
	ev.relative = to - _pointer
	ev.button_mask = _button_mask
	_apply_mods(ev, a)
	_pointer = to
	return ev


func _button_event(pressed: bool, button: int, a: Dictionary) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.position = _pointer
	ev.global_position = _pointer
	ev.button_index = button
	ev.pressed = pressed
	if button < MOUSE_BUTTON_WHEEL_UP:
		if pressed:
			_button_mask |= 1 << (button - 1)
		else:
			_button_mask &= ~(1 << (button - 1))
	ev.button_mask = _button_mask
	_apply_mods(ev, a)
	return ev


## Build the eased path for a move/drag: returns Array[InputEvent].
func _path_events(from: Vector2, to: Vector2, steps: int, a: Dictionary) -> Array:
	var out: Array = []
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var eased := t * t * (3.0 - 2.0 * t)    # smoothstep ease-in/out
		out.append(_motion_event(from.lerp(to, eased), a))
	return out


## Start a multi-frame gesture; the reply is sent when it finishes.
func _start_gesture(p: StreamPeerTCP, id: Variant, events: Array,
		per_frame := 1) -> void:
	_gesture = {"peer": p, "id": id, "events": events,
		"per_frame": maxi(1, per_frame), "sent": 0}


func _pump_gesture() -> void:
	if _gesture == null:
		return
	var g: Dictionary = _gesture
	var events: Array = g["events"]
	var n := 0
	while g["sent"] < events.size() and n < int(g["per_frame"]):
		Input.parse_input_event(events[g["sent"]])
		g["sent"] = int(g["sent"]) + 1
		n += 1
	if g["sent"] >= events.size():
		_gesture = null
		_reply(g["peer"], g["id"], {"pointer": [_pointer.x, _pointer.y]})


func _cmd_input_move(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not a.has("to"):
		_reply_err(p, id, "bad_args", "missing to")
		return null
	var steps := int(a.get("steps", 12))
	_start_gesture(p, id, _path_events(_pointer, _vec2(a["to"]), steps, a))
	return null


func _cmd_input_down(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	Input.parse_input_event(_button_event(true,
		BUTTONS.get(String(a.get("button", "left")), MOUSE_BUTTON_LEFT), a))
	return {}


func _cmd_input_up(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	Input.parse_input_event(_button_event(false,
		BUTTONS.get(String(a.get("button", "left")), MOUSE_BUTTON_LEFT), a))
	return {}


func _cmd_input_click(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var button: int = BUTTONS.get(String(a.get("button", "left")), MOUSE_BUTTON_LEFT)
	var events: Array = []
	if a.has("at"):
		events = _path_events(_pointer, _vec2(a["at"]), int(a.get("steps", 8)), a)
	events.append(_button_event(true, button, a))
	events.append(_button_event(false, button, a))
	_start_gesture(p, id, events)
	return null


func _cmd_input_drag(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	if not (a.has("from") and a.has("to")):
		_reply_err(p, id, "bad_args", "missing from/to")
		return null
	var button: int = BUTTONS.get(String(a.get("button", "left")), MOUSE_BUTTON_LEFT)
	var steps := int(a.get("steps", 16))
	var events: Array = []
	events.append_array(_path_events(_pointer, _vec2(a["from"]),
		maxi(4, steps / 2), a))
	events.append(_button_event(true, button, a))
	events.append_array(_path_events(_vec2(a["from"]), _vec2(a["to"]), steps, a))
	events.append(_button_event(false, button, a))
	_start_gesture(p, id, events)
	return null


func _cmd_input_scroll(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	var dir := "wheel_up" if float(a.get("amount", 1)) > 0 else "wheel_down"
	var n := absi(int(a.get("amount", 1)))
	for i in n:
		Input.parse_input_event(_button_event(true, BUTTONS[dir], a))
		Input.parse_input_event(_button_event(false, BUTTONS[dir], a))
	return {}


const KEYS := {"escape": KEY_ESCAPE, "enter": KEY_ENTER, "tab": KEY_TAB,
	"delete": KEY_DELETE, "backspace": KEY_BACKSPACE, "z": KEY_Z, "d": KEY_D,
	"x": KEY_X, "c": KEY_C, "l": KEY_L, "r": KEY_R, "a": KEY_A, "s": KEY_S}


func _cmd_input_key(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var key_name := String(a.get("key", "")).to_lower()
	var code: int = KEYS.get(key_name, 0)
	if code == 0 and key_name.length() == 1:
		code = OS.find_keycode_from_string(key_name)
	if code == 0:
		_reply_err(p, id, "bad_args", "unknown key %s" % key_name)
		return null
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code as Key
		ev.physical_keycode = code as Key
		ev.pressed = pressed
		_apply_mods(ev, a)
		Input.parse_input_event(ev)
	return {}


func _cmd_input_type(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	for ch in String(a.get("text", "")):
		var ev := InputEventKey.new()
		ev.unicode = ch.unicode_at(0)
		ev.keycode = OS.find_keycode_from_string(ch) as Key
		ev.pressed = true
		Input.parse_input_event(ev)
		var up := InputEventKey.new()
		up.keycode = ev.keycode
		up.pressed = false
		Input.parse_input_event(up)
	return {}


func _cmd_input_modifiers(a: Dictionary, _p: StreamPeerTCP, _id: Variant) -> Dictionary:
	for k in ["shift", "ctrl", "alt"]:
		if a.has(k):
			_modifiers[k] = bool(a[k])
	return _modifiers.duplicate()
