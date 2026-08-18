#!/usr/bin/env python3
"""M23 RPC test: revolve action — full ring, partial angle, straddle
refusal, cut through a body, timeline integration."""

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
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world(a, steps=5)
    app.click_world(b, steps=5)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Ring: rect x 20..30, y 0..10 about the sketch Y axis.
    app.call("action.enter_sketch", {"plane": "XY"})
    sketch_id = app.call("query.mode")["active_sketch"]
    draw_rect(app, [20, 0], [30, 10])
    app.call("action.finish_sketch")
    r = app.call("action.revolve",
                 {"sketch": sketch_id, "at": [25, 5], "axis": "y",
                  "angle": 360.0})
    check(r["name"] == "Revolve1", "Revolve1 created")
    check(near(r["volume"], 5000 * math.pi, 200.0),
          f"ring volume 5000*pi (got {r['volume']:.0f})")
    tl = app.call("query.timeline")
    check([f["kind"] for f in tl["features"]] == ["sketch", "revolve"],
          "timeline has sketch + revolve")

    # Partial angle: quarter of the ring.
    app.call("action.undo")
    r2 = app.call("action.revolve",
                  {"sketch": sketch_id, "at": [25, 5], "axis": "y",
                   "angle": 90.0})
    check(near(r2["volume"], 1250 * math.pi, 100.0),
          f"quarter volume (got {r2['volume']:.0f})")
    app.call("action.undo")

    # Straddling region refused.
    app.call("action.enter_sketch", {"plane": "XY"})
    s2 = app.call("query.mode")["active_sketch"]
    draw_rect(app, [-5, 20], [5, 30])
    app.call("action.finish_sketch")
    try:
        app.call("action.revolve",
                 {"sketch": s2, "at": [0, 25], "axis": "y", "angle": 360.0})
        check(False, "straddling region refused")
    except RpcError:
        check(True, "straddling region refused")

    # Cut: box + revolve cut about the sketch X axis (90 deg notch).
    app.call("action.enter_sketch", {"plane": "XY"})
    s3 = app.call("query.mode")["active_sketch"]
    draw_rect(app, [0, 0], [40, 30])
    app.call("action.finish_sketch")
    app.call("action.extrude", {"sketch": s3, "at": [20, 15], "distance": 10})
    app.call("action.enter_sketch", {"plane": "XY"})
    s4 = app.call("query.mode")["active_sketch"]
    draw_rect(app, [5, 2], [35, 9])
    app.call("action.finish_sketch")
    rc = app.call("action.revolve",
                  {"sketch": s4, "at": [20, 5], "axis": "x", "angle": 90.0,
                   "operation": "cut"})
    want = 12000 - 0.25 * math.pi * (81 - 4) * 30
    check(near(rc["body_volume"], want, 300.0),
          f"cut notch volume {want:.0f} (got {rc['body_volume']:.0f})")

    # Revolve button arms profile picking (UI wiring); Esc cancels.
    app.click_control("RevolveBtn")
    check(True, "Revolve button clickable")
    app.call("input.key", {"key": "escape"})

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
