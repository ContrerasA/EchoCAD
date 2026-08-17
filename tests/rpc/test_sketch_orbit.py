#!/usr/bin/env python3
"""M14 RPC test: in-sketch orbit via real input, cube-face return, exact view."""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, near

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
    app.call("action.set_view", {"pan": [5, 5], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # A line to look at, drawn with real clicks.
    app.click_control("LineToolBtn")
    app.click_world([0, 20], steps=6)
    app.click_world([40, 20], steps=6)
    app.call("input.key", {"key": "escape"})
    n0 = len(app.entities())
    check(n0 == 3, f"line drawn (3 entities, got {n0})")

    # Shift+MMB drag: off-axis sub-state, canvas yields to the 3D view.
    app.call("input.drag", {"from": [640, 400], "to": [700, 480],
                            "button": "middle", "modifiers": ["shift"],
                            "steps": 16})
    m = app.call("query.mode")
    check(m["mode"] == "sketch" and m["sketch_orbit"],
          f"shift+MMB entered the off-axis sub-state (got {m})")

    # Sketching CONTINUES off-axis (Fusion): clicks ray-cast onto the plane.
    app.click_control("LineToolBtn")
    app.click_world([10, -15], steps=4)
    app.click_world([35, -30], steps=4)
    app.call("input.key", {"key": "escape"})   # end the chain (tool -> Select)
    ents = app.entities()
    check(len(ents) == n0 + 3,
          f"off-axis clicks drew a line on the plane (got {len(ents) - n0:+d})")
    hit = [e for e in ents if e["kind"] == "point"
           and near(e["pos"][0], 10, 0.5) and near(e["pos"][1], -15, 0.5)]
    check(len(hit) == 1, "off-axis click landed at the right plane point")
    check(app.call("query.mode")["sketch_orbit"],
          "drawing off-axis stayed off-axis")
    n0 = len(ents)
    app.call("input.key", {"key": "escape"})   # nothing to cancel: fly home
    time.sleep(0.6)                            # ...after the fly-back tween
    m = app.call("query.mode")
    check(not m["sketch_orbit"], "Esc returned to the locked view")

    # Off-axis again, then home via the plane's view-cube face — a real click.
    app.call("input.drag", {"from": [640, 400], "to": [720, 470],
                            "button": "middle", "modifiers": ["shift"],
                            "steps": 16})
    check(app.call("query.mode")["sketch_orbit"], "re-entered off-axis")
    face = app.call("query.cube_face", {"plane": "XY"})
    check(face["ok"], f"XY cube face is clickable (got {face})")
    app.call("input.click", {"at": [face["x"], face["y"]], "steps": 6})
    time.sleep(0.6)
    m = app.call("query.mode")
    check(not m["sketch_orbit"], "cube face returned to the locked view")
    v = app.call("query.view")
    check(near(v["pan"][0], 5) and near(v["pan"][1], 5) and near(v["zoom"], 4.0),
          f"pan/zoom restored exactly (got {v['pan']} @ {v['zoom']})")

    # Editing works again: draw a second line.
    app.click_control("LineToolBtn")
    app.click_world([0, -10], steps=6)
    app.click_world([40, -10], steps=6)
    app.call("input.key", {"key": "escape"})
    check(len(app.entities()) == n0 + 3, "editing restored after return")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
