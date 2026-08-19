#!/usr/bin/env python3
"""M27 RPC test: projection toggle, look-at, fit, display unit, named views,
measure query."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, RpcError, near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Projection round trip, size-preserving.
    v0 = app.call("query.view")
    check(v0["ortho"] is False, "starts perspective")
    r = app.call("action.set_pref", {"ortho": True})
    check(r["ortho"] is True, "set_pref ortho engages")
    v1 = app.call("query.view")
    check(v1["ortho"] is True, "query.view reports ortho")
    check(near(v1["view_height_mm"], v0["view_height_mm"],
               v0["view_height_mm"] * 0.02), "apparent size preserved")
    app.call("action.set_pref", {"ortho": False})

    # Look At +Z: the view squares up (rotation about only Z remains).
    app.call("action.look_at", {"normal": [0, 0, 1]})
    rot = app.call("query.view")["camera_rotation"]
    check(abs(rot[0]) < 1e-3 and abs(rot[1]) < 1e-3,
          f"look_at +Z squared the camera (rot {rot})")
    try:
        app.call("action.look_at", {"normal": [0, 0, 0]})
        check(False, "zero normal refused")
    except RpcError:
        check(True, "zero normal refused")

    # Body, then fit centers it.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=5)
    app.click_world([40, 30], steps=5)

    # Measure the rect's first line through the query.
    lines = app.entities_of_kind("line")
    m = app.call("query.measure", {"ids": [lines[0]["id"]]})
    check(m["kind"] == "line_length" and m["text"] != "",
          f"measure line ({m.get('text', '')})")
    pts = app.entities_of_kind("point")
    m2 = app.call("query.measure", {"ids": [pts[0]["id"], pts[1]["id"]]})
    check(m2["kind"] == "point_distance", "measure two points")
    app.call("action.finish_sketch")

    app.call("action.extrude", {"sketch": sketch_id, "at": [20, 15],
                                "distance": 20.0})
    body = app.call("query.bodies")["bodies"][0]
    bx = body["aabb"]
    center = [bx[0] + bx[3] / 2, bx[1] + bx[4] / 2, bx[2] + bx[5] / 2]
    app.call("action.fit")
    tgt = app.call("query.view")["camera_target"]
    check(all(near(tgt[i], center[i], 1.0) for i in range(3)),
          f"fit centered the body (target {tgt} vs {center})")

    # Display unit: UI boundary only.
    r = app.call("action.set_display_unit", {"unit": "mm"})
    check(r["unit"] == "mm", "display unit set to mm")
    try:
        app.call("action.set_display_unit", {"unit": "furlong"})
        check(False, "bogus unit refused")
    except RpcError:
        check(True, "bogus unit refused")
    app.call("action.set_display_unit", {"unit": "in"})

    # Named views: save, disturb, apply, restored.
    app.call("action.look_at", {"normal": [0.5, -0.7, 0.5]})
    saved = app.call("query.view")["camera_rotation"]
    r = app.call("action.save_view", {"name": "qa-view"})
    check(r["count"] == 1 and r["view"]["name"] == "qa-view", "view saved")
    app.call("action.look_at", {"normal": [0, 0, 1]})
    app.call("action.apply_view", {"name": "qa-view"})
    rot2 = app.call("query.view")["camera_rotation"]
    check(all(abs(rot2[i] - saved[i]) < 1e-3 for i in range(3)),
          "named view restored the camera")
    try:
        app.call("action.apply_view", {"name": "nope"})
        check(False, "unknown view refused")
    except RpcError:
        check(True, "unknown view refused")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_VIEWING OK")


if __name__ == "__main__":
    main()
