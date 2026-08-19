#!/usr/bin/env python3
"""M29 RPC test: patterns/chamfer/polygon driven through real input —
shelf buttons, type-while-drawing fields, clicks."""

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
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [50, 25], "zoom": 3.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # Source rect.
    app.click_control("RectToolBtn")
    app.click_world([5, 5], steps=3)
    app.click_world([25, 20], steps=3)
    lines = app.entities_of_kind("line")
    check(len(lines) == 4, "source rect drawn")

    # Rectangular pattern 2x2 via typed fields.
    app.call("action.select", {"ids": [l["id"] for l in lines]})
    app.click_control("RectPatternToolBtn")
    app.call("input.type", {"text": "2"})
    app.call("input.key", {"key": "tab"})
    app.call("input.type", {"text": "2"})
    app.call("input.key", {"key": "tab"})
    app.call("input.type", {"text": "30mm"})
    app.call("input.key", {"key": "tab"})
    app.call("input.type", {"text": "25mm"})
    app.click_world([80, 40], steps=3)
    check(len(app.entities_of_kind("line")) == 16,
          "2x2 pattern -> 16 lines")
    pts = [tuple(p["pos"]) for p in app.entities_of_kind("point")]
    check(any(near(x, 35, 1e-3) and near(y, 30, 1e-3) for x, y in pts),
          "copy at (+30,+25)")
    app.call("action.undo")
    check(len(app.entities_of_kind("line")) == 4, "one undo removes pattern")

    # Circular pattern: a circle 3x over 180 degrees.
    app.click_control("CircleToolBtn")
    app.click_world([60, 0], steps=3)
    app.click_world([65, 0], steps=3)
    circ = app.entities_of_kind("circle")[0]
    app.call("action.select", {"ids": [circ["id"]]})
    app.click_control("CircPatternToolBtn")
    app.call("input.type", {"text": "3"})
    app.call("input.key", {"key": "tab"})
    app.call("input.type", {"text": "180"})
    app.click_world([0, 0], steps=3)
    circles = app.entities_of_kind("circle")
    check(len(circles) == 3, "3 copies over 180 degrees")
    emap = app.entity_map()
    centers = [emap[c["center"]]["pos"] for c in circles]
    check(any(near(c[0], -60, 1e-3) and near(c[1], 0, 1e-2) for c in centers),
          "last copy lands on 180 degrees")
    app.call("action.undo")

    # Chamfer the rect corner at (25,20) with a typed distance.
    app.click_control("ChamferToolBtn")
    app.call("input.type", {"text": "4mm"})
    n_before = len(app.entities())
    app.click_world([25, 20], steps=3)
    check(len(app.entities_of_kind("line")) == 5, "chamfer added the edge")
    check(len(app.entities()) == n_before + 2, "chamfer census (+2)")
    pts2 = [tuple(p["pos"]) for p in app.entities_of_kind("point")]
    check(any(near(x, 21, 1e-3) and near(y, 20, 1e-3) for x, y in pts2),
          "chamfer cut 4mm along the top edge")
    app.call("action.undo")

    # Polygon: hexagon, R from the second click.
    app.click_control("PolygonToolBtn")
    app.click_world([100, 50], steps=3)
    app.click_world([112, 50], steps=3)
    check(len(app.entities_of_kind("line")) == 10,
          "hexagon added 6 sides")
    check(any(c.get("construction") for c in app.entities_of_kind("circle")),
          "construction circle present")
    app.call("action.undo")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_SKETCH_PATTERNS OK")


if __name__ == "__main__":
    main()
