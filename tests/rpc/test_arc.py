#!/usr/bin/env python3
"""M6 RPC test: tangent arc via real input, drag re-solve, DOF query."""

import os
import sys

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
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})

    # Line, then a tangent arc off its right end. Deliberately clear of (0,0):
    # the sketch origin is a real point there and is PINNED, so a line welded
    # onto it could not move under the drag this test performs later. Kept
    # close to the origin all the same -- the sketch view is shorter than the
    # window, so points far up the Y axis fall outside it and cannot be clicked.
    app.click_control("LineToolBtn")
    app.click_world([-40, 20], steps=6)
    app.click_world([0, 20], steps=6)
    app.call("input.key", {"key": "escape"})
    app.click_control("TangentArcToolBtn")
    app.click_world([0, 20], steps=6)
    app.click_world([20, 40], steps=8)
    arcs = app.entities_of_kind("arc")
    check(len(arcs) == 1, "tangent arc committed")
    types = sorted(c["type"] for c in app.constraints())
    check("TANGENT" in types, f"tangent constraint present (got {types})")
    # The arc's start is WELDED to the line's endpoint — one shared point, not
    # a twin held by a Coincident. The twin made this case unstable: the rigid
    # ride-along, the tangency projection and the Coincident each undid the
    # others, so the solve never converged and a few mm of drag threw the arc's
    # centre metres away.
    ents = app.entity_map()
    line = app.entities_of_kind("line")[0]
    check(arcs[0]["start"] in (line["p0"], line["p1"]),
          "arc start welded to the line endpoint")

    # DOF query works and reports a positive DOF count.
    dof = app.call("query.dof")
    check(dof["analyzed"] and dof["dof"] > 0 and not dof["fully_constrained"],
          f"dof query ({dof['summary']})")
    check(len(dof["conflicts"]) == 0, "no conflicts reported")

    # Drag the line's free end down with a human-like drag; tangency and
    # coincidence must survive the re-solve.
    app.click_control("SelectToolBtn")
    app.call("input.drag", {"from": app.world_to_screen([-40, 20]),
                            "to": app.world_to_screen([-40, 0]), "steps": 16})
    ents = app.entity_map()
    arc = app.entities_of_kind("arc")[0]
    lines = app.entities_of_kind("line")
    line = lines[0]
    import math
    la = ents[line["p0"]]["pos"]
    lb = ents[line["p1"]]["pos"]
    c = ents[arc["center"]]["pos"]
    s = ents[arc["start"]]["pos"]
    d = [lb[0] - la[0], lb[1] - la[1]]
    dl = math.hypot(*d) or 1.0
    n = [-d[1] / dl, d[0] / dl]
    gap = abs(n[0] * (c[0] - la[0]) + n[1] * (c[1] - la[1]))
    r = math.hypot(c[0] - s[0], c[1] - s[1])
    check(near(gap, r, 0.1), f"tangency held after drag (gap {gap:.3f} vs r {r:.3f})")
    check(near(s[0], lb[0], 0.05) and near(s[1], lb[1], 0.05),
          "arc start stayed coincident with line end")

    # One undo removes the whole drag (drag + re-solve merged).
    app.call("action.undo")
    ents = app.entity_map()
    la = ents[line["p0"]]["pos"]
    check(near(la[0], -40, 1e-3) and near(la[1], 20, 1e-3),
          "one undo reverts the whole drag")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
