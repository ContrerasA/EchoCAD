#!/usr/bin/env python3
"""M9 RPC test: slot variants through real input, typed width, driving."""

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


def slot_measures(app):
    ents = app.entity_map()
    arcs = app.entities_of_kind("arc")[-2:]
    ca = ents[arcs[0]["center"]]["pos"]
    cb = ents[arcs[1]["center"]]["pos"]
    s = ents[arcs[0]["start"]]["pos"]
    r = math.hypot(s[0] - ca[0], s[1] - ca[1])
    return ca, cb, r


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})

    # Center-to-center slot with typed width.
    app.click_control("SlotToolBtn")
    app.click_world([-30, 0], steps=6)
    app.click_world([30, 0], steps=6)
    app.call("input.move", {"to": app.world_to_screen([0, 8]), "steps": 6})
    app.call("input.type", {"text": "0.5"})
    app.call("input.key", {"key": "enter"})
    ents = app.entities()
    kinds = {}
    for e in ents:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    check(kinds == {"point": 6, "line": 2, "arc": 2},
          f"slot census (got {kinds})")
    types = sorted(c["type"] for c in app.constraints())
    check(types == ["EQUAL", "TANGENT", "TANGENT", "TANGENT", "TANGENT"],
          f"slot constraints (got {types})")
    ca, cb, r = slot_measures(app)
    check(vec_near(ca, [-30, 0], 1e-3) and vec_near(cb, [30, 0], 1e-3),
          "centers exact")
    check(near(r, 6.35, 1e-3), f"typed width 0.5in -> r 6.35 (got {r:.3f})")

    # One undo removes the whole slot.
    app.call("action.undo")
    check(len(app.entities()) == 0, "one undo removes slot")
    app.call("action.redo")

    # Drive the slot: dimension the center distance to 3in via smart dim.
    ents = app.entity_map()
    arcs = app.entities_of_kind("arc")
    app.call("action.add_constraint",
             {"type": "DISTANCE",
              "operands": [arcs[0]["center"], arcs[1]["center"]],
              "value": 76.2})
    ca, cb, r = slot_measures(app)
    check(near(math.hypot(cb[0] - ca[0], cb[1] - ca[1]), 76.2, 0.01),
          "center distance drove to 3in")
    check(near(r, 6.35, 0.01), f"width survived driving (r {r:.3f})")

    # Radius dimension drives the width.
    app.call("action.add_constraint",
             {"type": "RADIUS", "operands": [arcs[0]["id"]], "value": 5.0})
    ca, cb, r = slot_measures(app)
    check(near(r, 5.0, 0.01), f"radius dim drove width (r {r:.3f})")
    dof = app.call("query.dof")
    check(len(dof["conflicts"]) == 0, "no conflicts after driving")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
