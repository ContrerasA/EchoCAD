#!/usr/bin/env python3
"""M34 RPC test: sweep + loft through the automation API."""

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


def draw_rect(app, a, b):
    app.click_control("RectToolBtn")
    app.click_world(a, steps=3)
    app.click_world(b, steps=3)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Profile: 8x6 rect on XZ.
    app.call("action.enter_sketch", {"plane": "XZ"})
    app.call("action.set_view", {"pan": [0, 5], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    profile = app.call("query.mode")["active_sketch"]
    draw_rect(app, [-4, 2], [4, 8])
    app.call("action.finish_sketch")

    # Path: straight 40mm line on XY.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 20], "zoom": 4.0})
    path = app.call("query.mode")["active_sketch"]
    app.click_control("LineToolBtn")
    app.click_world([0, 0], steps=3)
    app.click_world([0, 40], steps=3)
    app.call("input.key", {"key": "escape"})
    line_id = app.entities_of_kind("line", sketch=path)[0]["id"]
    app.call("action.finish_sketch")

    r = app.call("action.sweep", {"sketch": profile, "at": [0, 5],
                                  "path_sketch": path,
                                  "path_entity": line_id})
    check(near(r["volume"], 48 * 40.0, 48 * 40 * 0.01),
          f"straight sweep volume ({r['volume']:.0f})")
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 1, "sweep body built")

    # Bad path entity refused.
    try:
        app.call("action.sweep", {"sketch": profile, "at": [0, 5],
                                  "path_sketch": path, "path_entity": "nope"})
        check(False, "bogus path refused")
    except RpcError:
        check(True, "bogus path refused")

    # Loft: circles 20 -> 10, 30mm apart.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [80, 0], "zoom": 3.0})
    c1 = app.call("query.mode")["active_sketch"]
    app.click_control("CircleToolBtn")
    app.click_world([80, 0], steps=3)
    app.click_world([100, 0], steps=3)
    app.call("action.finish_sketch")
    plane = app.call("action.create_offset_plane",
                     {"base": "XY", "offset": 30.0})["feature"]
    app.call("action.enter_sketch", {"plane": plane})
    app.call("action.set_view", {"pan": [80, 0], "zoom": 3.0})
    c2 = app.call("query.mode")["active_sketch"]
    app.click_control("CircleToolBtn")
    app.click_world([80, 0], steps=3)
    app.click_world([90, 0], steps=3)
    app.call("action.finish_sketch")

    frustum = math.pi * 30 * (400 + 200 + 100) / 3.0
    r = app.call("action.loft", {"sections": [
        {"sketch": c1, "at": [80, 0]}, {"sketch": c2, "at": [80, 0]}]})
    check(near(r["volume"], frustum, frustum * 0.03),
          f"frustum loft volume ({r['volume']:.0f} vs {frustum:.0f})")
    check(len(app.call("query.bodies")["bodies"]) == 2, "loft body built")

    try:
        app.call("action.loft", {"sections": [{"sketch": c1, "at": [80, 0]}]})
        check(False, "single-section loft refused")
    except RpcError:
        check(True, "single-section loft refused")

    app.call("action.undo")
    check(len(app.call("query.bodies")["bodies"]) == 1, "undo removes the loft")

    for name in ["SweepBtn", "LoftBtn"]:
        check(app.call("query.control", {"name": name})["visible"],
              f"{name} on the shelf")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_SWEEP_LOFT OK")


if __name__ == "__main__":
    main()
