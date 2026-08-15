#!/usr/bin/env python3
"""M4 RPC test: draw with the line tool via REAL injected mouse events —
human-like moves, tool button clicks — then compare document state to
expected geometry (canonical mm)."""

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
    app.call("action.set_pref", {"grid_snap": False, "inference": True})

    # Activate the line tool by clicking its real toolbar button.
    app.click_control("LineToolBtn")
    check(app.call("query.active_tool")["tool"] == "line",
          "toolbar click activates line tool")

    # Draw an L: exact horizontal then exact vertical, via world targets.
    for p in [(0, 0), (50.8, 0.4), (50.3, 25.4)]:
        app.click_world(p, steps=10)
    app.call("input.key", {"key": "escape"})

    ents = app.entities()
    lines = [e for e in ents if e["kind"] == "line"]
    pts = [e for e in ents if e["kind"] == "point"]
    check(len(lines) == 2 and len(pts) == 3, "L-shape census (2 lines, 3 points)")
    cons = app.constraints()
    types = sorted(c["type"] for c in cons)
    check(types == ["HORIZONTAL", "VERTICAL"], f"inferred H+V (got {types})")
    by_id = {e["id"]: e for e in ents}
    corner = by_id[lines[0]["p1"]]
    check(vec_near(corner["pos"], [50.8, 0.0], 1e-3),
          "H inference snapped corner to y=0 (2in over)")

    # Draw with grid snap on: endpoints land on grid intersections.
    app.call("action.set_pref", {"grid_snap": True})
    n_before = len(app.entities())
    app.click_control("PointToolBtn")
    app.click_world([30.2, 29.9], steps=8)
    ents = app.entities()
    check(len(ents) == n_before + 1, "point tool placed one point")
    p = ents[-1]["pos"]
    # Grid step at zoom 4 with inch unit: 0.5in = 12.7mm -> nearest to
    # (30.2, 29.9) is (25.4, 25.4)? step depends on zoom; just assert on-grid.
    step = None
    # infer step from the snapped value: both coords must be integer multiples
    # of SOME common inch-derived step (0.127mm granularity check).
    for cand in [3.175, 6.35, 12.7, 25.4, 63.5]:
        if near(p[0] % cand, 0, 1e-3) or near(p[0] % cand, cand, 1e-3):
            step = cand
            break
    check(step is not None
          and (near(p[1] % step, 0, 1e-3) or near(p[1] % step, step, 1e-3)),
          f"grid snap landed on an inch-grid intersection (got {p})")

    # Undo twice removes the point and the last segment.
    app.call("action.undo")
    app.call("action.undo")
    check(len([e for e in app.entities() if e["kind"] == "line"]) == 1,
          "undo granularity: one segment per step")

    # Keyboard shortcut: L re-activates line tool.
    app.click_control("SelectToolBtn")
    app.call("input.key", {"key": "l"})
    check(app.call("query.active_tool")["tool"] == "line",
          "L shortcut activates line tool")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
