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
	}


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
		out.append(e.to_dict())
	return {"entities": out}


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
	}


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


## Global rect of a named control under AppRoot (for driving real UI).
func _cmd_query_control(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var node := app.find_child(String(a.get("name", "")), true, false) as Control
	if node == null:
		_reply_err(p, id, "not_found", "no control named %s" % a.get("name"))
		return null
	var r := node.get_global_rect()
	return {"rect": [r.position.x, r.position.y, r.size.x, r.size.y],
		"visible": node.is_visible_in_tree(),
		"disabled": node.disabled if node is BaseButton else false}


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
	return {"selection": Array(app.selection)}


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
			"vertex_count": (prof["polygon"] as PackedVector2Array).size()})
	return {"profiles": out}


func _cmd_action_extrude(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var fid := String(a.get("sketch", ""))
	var at := _vec2(a.get("at", [0, 0]))
	var dist := float(a.get("distance", 10.0))
	var eid := app.extrude(fid, at, dist)
	if eid == "":
		_reply_err(p, id, "invalid", "no closed profile at that point")
		return null
	var f := app.doc.feature_by_id(eid) as ExtrudeFeature
	var mesh := f.build_mesh(app.doc)
	return {"feature": eid, "name": f.name,
		"volume": ExtrudeFeature.mesh_volume(mesh) if mesh != null else 0.0}


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
	return {"inference": app.prefs["inference"],
		"grid_snap": app.snap.grid_enabled,
		"entity_snap": app.snap.entity_snap_enabled}

func _cmd_action_enter_sketch(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var plane := String(a.get("plane", "XY"))
	if not SketchFeature.PLANES.has(plane):
		_reply_err(p, id, "bad_args", "unknown plane %s" % plane)
		return null
	var fid := app.create_sketch(plane)
	return {"feature": fid}


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


func _cmd_action_open(a: Dictionary, p: StreamPeerTCP, id: Variant) -> Variant:
	var doc := Serializer.load_file(String(a.get("path", "")))
	if doc == null:
		_reply_err(p, id, "io", "load failed")
		return null
	app.load_document(doc)
	return {"features": doc.features.size()}


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
