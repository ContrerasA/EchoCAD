extends SceneTree

# M3: in-process server test over a real loopback socket — startup via env
# var, request/response framing, a query, an action, and an input gesture
# that spans frames.

const PORT := 47771

var _root: AppRoot = null
var _peer: StreamPeerTCP = null
var _buf := ""


func _init() -> void:
	OS.set_environment("ECHOCAD_AUTOMATION_PORT", str(PORT))
	var packed: PackedScene = load("res://ui/main.tscn")
	_root = packed.instantiate()
	get_root().add_child(_root)
	_root.ready.connect(_go, CONNECT_ONE_SHOT)


func _go() -> void:
	_run()


func _fail(msg: String) -> void:
	push_error("m03_server: " + msg)
	OS.set_environment("ECHOCAD_AUTOMATION_PORT", "")
	quit(1)


func _request(cmd: String, args := {}) -> Dictionary:
	var id := randi() % 100000
	_peer.put_data((JSON.stringify({"id": id, "cmd": cmd, "args": args})
		+ "\n").to_utf8_buffer())
	# Poll for the reply line across frames (gestures take many frames).
	for i in 600:
		await process_frame
		_peer.poll()
		var n := _peer.get_available_bytes()
		if n > 0:
			_buf += _peer.get_utf8_string(n)
		var nl := _buf.find("\n")
		if nl >= 0:
			var line := _buf.substr(0, nl)
			_buf = _buf.substr(nl + 1)
			return JSON.parse_string(line) as Dictionary
	return {}


func _run() -> void:
	await process_frame   # let AutomationServer start listening
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host("127.0.0.1", PORT) != OK:
		return _fail("cannot connect")
	for i in 120:
		await process_frame
		_peer.poll()
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return _fail("never connected")

	var r := await _request("app.info")
	if not r.get("ok", false) or r["result"]["app"] != "EchoCAD":
		return _fail("app.info wrong: %s" % str(r))
	if not r["result"]["headless"]:
		return _fail("expected headless=true in this test")

	r = await _request("query.mode")
	if r["result"]["mode"] != "model":
		return _fail("mode wrong")

	r = await _request("action.enter_sketch", {"plane": "XY"})
	var fid := String(r["result"]["feature"])
	r = await _request("query.mode")
	if r["result"]["mode"] != "sketch" or r["result"]["active_sketch"] != fid:
		return _fail("enter_sketch did not switch mode")

	# Frame-spanning gesture: the reply must arrive AND the pointer must have
	# traveled through the eased path (final position exact).
	r = await _request("input.move", {"to": [300, 200], "steps": 10})
	if not r.get("ok", false):
		return _fail("input.move failed")
	var ptr: Array = r["result"]["pointer"]
	if absf(float(ptr[0]) - 300.0) > 0.01 or absf(float(ptr[1]) - 200.0) > 0.01:
		return _fail("pointer did not land on target")

	# Unknown command errors without killing the connection.
	r = await _request("query.bogus")
	if r.get("ok", true) or r["error"]["code"] != "unknown_cmd":
		return _fail("unknown_cmd handling wrong")
	r = await _request("query.timeline")
	if (r["result"]["features"] as Array).size() != 1:
		return _fail("server dead after error")

	OS.set_environment("ECHOCAD_AUTOMATION_PORT", "")
	print("M03_SERVER OK: startup, framing, queries, gesture frames, errors")
	quit(0)
