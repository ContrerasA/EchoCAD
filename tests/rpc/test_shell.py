#!/usr/bin/env python3
"""M3 RPC test: drive the real app end-to-end through the automation API.

Covers: readiness, queries, entering a sketch via REAL UI clicks only
(Create Sketch button + plane click), camera orbit via drag, view math
round-trip, screenshot capture, malformed-request handling, undo via RPC.

Exit code 0 = pass. Run through tools/run_rpc_tests.sh (it launches the app).
"""

import json
import os
import socket
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, RpcError, near, vec_near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()

    info = app.call("app.info")
    check(info["app"] == "EchoCAD", "app.info identifies EchoCAD")
    headless = info["headless"]

    app.call("app.window", {"size": [1280, 800]})
    mode = app.call("query.mode")
    check(mode["mode"] == "model", "starts in model mode")

    # --- enter a sketch using ONLY real input: button click + plane click.
    app.click_control("CreateSketchBtn")
    check(app.call("query.mode")["picking_plane"], "create-sketch arms plane picking")
    # Ask the app WHERE the XY plane is rather than guessing a pixel. The
    # origin planes are quads with their corner ON the world origin, so the
    # middle of the window sits on their shared knife edge and hits one only
    # by luck -- which is exactly how this check broke before. Defaults to the
    # middle of the quad, well inside it.
    target = app.call("query.plane_point", {"plane": "XY"})
    check(target["visible"], "XY plane is on screen at the home camera")
    app.call("input.click", {"at": target["p"]})
    mode = app.call("query.mode")
    check(mode["mode"] == "sketch", "clicking a plane enters sketch mode")
    tl = app.call("query.timeline")
    check(len(tl["features"]) == 1 and tl["features"][0]["name"] == "Sketch1",
          "Sketch1 feature created")

    # --- view math round-trip through the RPC boundary.
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    s = app.world_to_screen([10, 5])
    w = app.call("query.screen_to_world", {"p": s})["p"]
    check(vec_near(w, [10, 5], 1e-3), "world<->screen round-trip")
    s_origin = app.world_to_screen([0, 0])
    s_up = app.world_to_screen([0, 10])
    check(s_up[1] < s_origin[1], "sketch view is Y-up through RPC")

    # --- sketch raster is readable (headless-safe path).
    img = app.call("app.sketch_image", {"width": 200, "height": 200})
    check(img["size"] == [200, 200], "sketch_image returns requested size")

    # --- finish, then orbit the 3D camera with a human-like MMB drag.
    app.click_control("FinishSketchBtn")
    check(app.call("query.mode")["mode"] == "model", "finish returns to model mode")
    rot0 = app.call("query.view")["camera_rotation"]
    app.call("input.drag", {"from": [640, 400], "to": [760, 460],
                            "button": "middle", "modifiers": ["shift"],
                            "steps": 20})
    rot1 = app.call("query.view")["camera_rotation"]
    check(not vec_near(rot0, rot1, 1e-4), "shift+MMB drag orbits the camera")

    # --- windowed only: real screenshot is non-blank.
    if not headless:
        shot = app.call("app.screenshot")
        check(len(shot["png_base64"]) > 1000, "screenshot captured (non-trivial png)")

    # --- undo/redo over RPC.
    r = app.call("action.undo")
    check(len(app.call("query.timeline")["features"]) == 0, "undo removes sketch")
    check(r["can_redo"], "undo reports redo available")
    app.call("action.redo")
    check(len(app.call("query.timeline")["features"]) == 1, "redo restores sketch")

    # --- save / open round-trip.
    path = os.path.join(tempfile.gettempdir(), "echocad_rpc_roundtrip.ecad")
    app.call("action.save", {"path": path})
    app.call("action.new_document")
    check(len(app.call("query.timeline")["features"]) == 0, "new document empty")
    app.call("action.open", {"path": path})
    check(len(app.call("query.timeline")["features"]) == 1, "open restores document")
    os.unlink(path)

    # --- error handling: unknown command, malformed line, bad args.
    try:
        app.call("query.nonsense")
        check(False, "unknown command raises")
    except RpcError as e:
        check(e.code == "unknown_cmd", "unknown command error code")
    raw = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    raw.sendall(b"this is not json\n")
    resp = json.loads(raw.makefile().readline())
    check(resp["ok"] is False and resp["error"]["code"] == "bad_json",
          "malformed line answered, not crashed")
    raw.close()
    try:
        app.call("query.entities", {"sketch": "f999"})
        check(False, "bad sketch id raises")
    except RpcError:
        check(True, "bad sketch id raises")
    check(app.call("query.mode")["mode"] == "model", "server alive after errors")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
