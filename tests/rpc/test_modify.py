#!/usr/bin/env python3
"""M10 RPC test: trim and fillet through real input."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, near, vec_near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # Cross, then trim the right half of the horizontal line.
    app.click_control("LineToolBtn")
    app.click_world([-40, 0], steps=5)
    app.click_world([40, 0], steps=5)
    app.call("input.key", {"key": "escape"})
    # Esc ends the chain AND drops back to Select (Fusion behaviour), so the
    # Line tool has to be picked up again for the second stroke.
    app.click_control("LineToolBtn")
    app.click_world([0, -40], steps=5)
    app.click_world([0, 40], steps=5)
    app.call("input.key", {"key": "escape"})
    app.click_control("TrimToolBtn")
    app.click_world([20, 0.4], steps=6)
    lines = app.entities_of_kind("line")
    check(len(lines) == 2, "trim split the cross")
    ents = app.entity_map()
    h_spans = []
    for l in lines:
        a, b = ents[l["p0"]]["pos"], ents[l["p1"]]["pos"]
        if abs(a[1]) < 0.01 and abs(b[1]) < 0.01:
            h_spans.append(sorted([a[0], b[0]]))
    check(h_spans == [[-40.0, 0.0]], f"kept left span (got {h_spans})")
    app.call("action.undo")
    check(len(app.entities_of_kind("line")) == 2 and not h_spans == [], "trim one undo")
    app.call("action.redo")

    # L corner + fillet with typed radius.
    app.click_control("LineToolBtn")
    app.click_world([60, -40], steps=5)
    app.click_world([100, -40], steps=5)
    app.click_world([100, 0], steps=5)
    app.call("input.key", {"key": "escape"})
    app.click_control("FilletToolBtn")
    app.call("input.type", {"text": "0.25"})
    app.click_world([100, -40], steps=6)
    arcs = app.entities_of_kind("arc")
    check(len(arcs) == 1, "fillet arc created")
    ents = app.entity_map()
    fc = ents[arcs[0]["center"]]["pos"]
    check(vec_near(fc, [100 - 6.35, -40 + 6.35], 0.01),
          f"fillet center exact (got {fc})")
    types = [c["type"] for c in app.constraints()]
    check(types.count("TANGENT") == 2, "fillet tangencies present")
    dof = app.call("query.dof")
    check(len(dof["conflicts"]) == 0, "no conflicts after fillet")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
