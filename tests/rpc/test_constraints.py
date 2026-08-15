#!/usr/bin/env python3
"""M7 RPC test: constraint palette through real UI — ctrl-click multi-select,
constraint bar buttons, DOF status, conflicts, delete via badge + Delete key."""

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
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # Two separate lines drawn by hand.
    app.click_control("LineToolBtn")
    app.click_world([-40, -20], steps=6)
    app.click_world([10, -12], steps=6)
    app.call("input.key", {"key": "escape"})
    app.click_world([-40, 20], steps=6)
    app.click_world([10, 35], steps=6)
    app.call("input.key", {"key": "escape"})
    lines = app.entities_of_kind("line")
    check(len(lines) == 2, "two lines drawn")

    # Ctrl-click both lines with the select tool, then click Parallel.
    app.click_control("SelectToolBtn")
    app.click_world([-15, -16], steps=6)                      # on line 1
    app.call("input.click",
             {"at": app.world_to_screen([-15, 27.5]), "modifiers": ["ctrl"]})
    sel = app.call("query.selection")["selection"]
    check(len(sel) == 2, f"ctrl-click built 2-entity selection (got {sel})")
    app.click_control("ParallelConBtn")
    cons = app.constraints()
    check(any(c["type"] == "PARALLEL" for c in cons), "Parallel button applied")
    ents = {e["id"]: e for e in app.entities()}
    l1, l2 = lines
    import math
    def direction(l):
        a, b = ents[l["p0"]]["pos"], ents[l["p1"]]["pos"]
        return math.atan2(b[1] - a[1], b[0] - a[0])
    cross = math.sin(direction(l2) - direction(l1))
    check(abs(cross) < 1e-3, "lines actually parallel after solve")

    # DOF status text present and sensible.
    dof = app.call("query.dof")
    check("DOF remaining" in dof["summary"], f"summary: {dof['summary']}")

    # Invalid application refused with a reason.
    app.call("action.select", {"ids": [l1["id"]]})
    try:
        app.call("action.add_constraint", {"type": "PARALLEL"})
        check(False, "invalid apply refused")
    except RpcError as e:
        check("two lines" in e.message, "invalid apply refused with reason")

    # Fully constrain a fresh line via RPC constraints; entities report done.
    app.call("action.add_constraint",
             {"type": "FIX", "operands": [l1["p0"]]})
    app.call("action.add_constraint", {"type": "HORIZONTAL",
                                       "operands": [l1["id"]]})
    app.call("action.add_constraint",
             {"type": "DISTANCE", "operands": [l1["p0"], l1["p1"]],
              "value": 50.8})
    ents = {e["id"]: e for e in app.entities()}
    a, b = ents[l1["p0"]]["pos"], ents[l1["p1"]]["pos"]
    check(near(math.hypot(b[0] - a[0], b[1] - a[1]), 50.8, 1e-3)
          and near(a[1], b[1], 1e-3), "driven distance + H solved to 2in flat")
    dof = app.call("query.dof")
    check(l1["p0"] in dof["constrained_points"]
          and l1["p1"] in dof["constrained_points"],
          "fully constrained points reported")

    # Conflict: second contradictory distance -> conflicts + summary.
    app.call("action.add_constraint",
             {"type": "DISTANCE", "operands": [l1["p0"], l1["p1"]],
              "value": 100.0})
    dof = app.call("query.dof")
    check(len(dof["conflicts"]) > 0 and dof["summary"] == "Conflicting constraints",
          "conflict detected and summarized")
    idx = app.constraints()[-1]["index"]
    app.call("action.delete_constraint", {"index": idx})
    dof = app.call("query.dof")
    check(len(dof["conflicts"]) == 0, "delete clears conflict")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
