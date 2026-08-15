#!/usr/bin/env python3
"""M5 RPC test: rectangle + circle through real injected input, including
Fusion-style type-while-drawing (input.type + Tab + Enter)."""

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
    app.call("action.set_pref", {"grid_snap": False})

    # Rectangle by clicks.
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=8)
    app.click_world([40, 25], steps=8)
    ents = app.entities()
    check(len([e for e in ents if e["kind"] == "line"]) == 4
          and len([e for e in ents if e["kind"] == "point"]) == 4,
          "rect census 4 lines + 4 shared points")
    types = sorted(c["type"] for c in app.constraints())
    check(types == ["HORIZONTAL", "HORIZONTAL", "VERTICAL", "VERTICAL"],
          f"rect auto H/H/V/V (got {types})")

    # Typed rectangle: first corner click, then "2 <Tab> 1 <Enter>" = 2x1 in.
    app.click_world([50, 20], steps=6)
    app.call("input.move", {"to": app.world_to_screen([70, 30]), "steps": 6})
    app.call("input.type", {"text": "2"})
    app.call("input.key", {"key": "tab"})
    app.call("input.type", {"text": "1"})
    app.call("input.key", {"key": "enter"})
    ents = app.entities()
    pts = [e for e in ents if e["kind"] == "point"]
    check(len(pts) == 8, "typed rect committed")
    xs = sorted(p["pos"][0] for p in pts[4:])
    ys = sorted(p["pos"][1] for p in pts[4:])
    check(near(xs[-1] - xs[0], 50.8, 1e-3) and near(ys[-1] - ys[0], 25.4, 1e-3),
          f"typed rect is 2in x 1in (got {xs[-1]-xs[0]:.3f} x {ys[-1]-ys[0]:.3f})")

    # Circle with typed radius.
    app.click_control("CircleToolBtn")
    app.click_world([-60, -20], steps=6)
    app.call("input.type", {"text": "0.75"})
    app.call("input.key", {"key": "enter"})
    circles = app.entities_of_kind("circle")
    check(len(circles) == 1 and near(circles[0]["radius"], 19.05, 1e-3),
          "typed circle radius 0.75in = 19.05mm")

    # 3-point circle.
    app.click_control("Circle3ToolBtn")
    for p in [(60, -60), (80, -60), (70, -50)]:
        app.click_world(p, steps=6)
    circles = app.entities_of_kind("circle")
    check(len(circles) == 2, "3pt circle committed")
    by_id = {e["id"]: e for e in app.entities()}
    c3 = circles[-1]
    check(vec_near(by_id[c3["center"]]["pos"], [70, -60], 1e-3)
          and near(c3["radius"], 10.0, 1e-3), "3pt circle center/radius")

    # Undo: whole shapes, one step each.
    app.call("action.undo")
    check(len(app.entities_of_kind("circle")) == 1, "undo removed 3pt circle")
    app.call("action.undo")
    check(len(app.entities_of_kind("circle")) == 0, "undo removed typed circle")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
