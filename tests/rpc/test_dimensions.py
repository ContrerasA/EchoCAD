#!/usr/bin/env python3
"""M8 RPC test: smart dimension through real input (pick, park, type),
label drag, parameters + expressions, driven toggle."""

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


def length(app, line):
    ents = {e["id"]: e for e in app.entities()}
    a, b = ents[line["p0"]]["pos"], ents[line["p1"]]["pos"]
    return math.hypot(b[0] - a[0], b[1] - a[1])


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # A line to dimension.
    app.click_control("LineToolBtn")
    app.click_world([0, 0], steps=6)
    app.click_world([40, 0], steps=6)
    app.call("input.key", {"key": "escape"})
    line = app.entities_of_kind("line")[0]

    # Smart dimension: D key, pick the line, park, type 2, Enter.
    app.call("input.key", {"key": "d"})
    check(app.call("query.active_tool")["tool"] == "dimension",
          "D activates smart dimension")
    app.click_world([20, 0.4], steps=6)      # pick line
    app.click_world([20, 18], steps=6)       # park above
    cons = app.constraints()
    dim = [c for c in cons if c["type"] == "DISTANCE"][-1]
    check(near(dim["value"], 40.0, 1e-3), "parked at measured value")
    app.call("input.type", {"text": "2"})
    app.call("input.key", {"key": "enter"})
    check(near(length(app, line), 50.8, 1e-2), "typed 2in drove the line")
    app.call("action.undo")
    check(len([c for c in app.constraints() if c["type"] == "DISTANCE"]) == 0,
          "pick+park+type undone as one step")
    app.call("action.redo")

    # Label drag with select tool: label_offset changes, geometry doesn't.
    app.click_control("SelectToolBtn")
    dim = [c for c in app.constraints() if c["type"] == "DISTANCE"][-1]
    off0 = dim["label_offset"]
    label_world = [ (0 + 50.8) / 2 + off0[0], 0 + off0[1] ]
    app.call("input.drag", {"from": app.world_to_screen(label_world),
                            "to": app.world_to_screen([label_world[0] + 10,
                                                       label_world[1] + 8]),
                            "steps": 10})
    dim2 = [c for c in app.constraints() if c["type"] == "DISTANCE"][-1]
    check(abs(dim2["label_offset"][0] - off0[0]) > 5,
          f"label drag moved offset ({off0} -> {dim2['label_offset']})")
    check(near(length(app, line), 50.8, 1e-2), "label drag left geometry alone")

    # Parameter + expression drive.
    r = app.call("action.set_parameter",
                 {"name": "width", "expr": "2", "unit": "in"})
    check(near(r["values"]["width"], 50.8, 1e-6), "parameter created (2in)")
    idx = dim2["index"]
    r = app.call("action.set_dimension", {"index": idx, "text": "width / 2"})
    check(r["expr"] == "width / 2" and near(r["value"], 25.4, 1e-6),
          "expression accepted")
    check(near(length(app, line), 25.4, 1e-2), "expression drove geometry")
    app.call("action.set_parameter", {"name": "width", "expr": "4"})
    check(near(length(app, line), 50.8, 1e-2), "parameter change re-drove")

    # Bad expression rejected.
    try:
        app.call("action.set_dimension", {"index": idx, "text": "bogus + 1"})
        check(False, "bad expression rejected")
    except RpcError as e:
        check("bogus" in e.message, "bad expression rejected with name")

    # Driven toggle: measure only.
    app.call("action.set_driven", {"index": idx, "driven": True})
    before = length(app, line)
    app.call("action.set_dimension", {"index": idx, "text": "9"})
    check(near(length(app, line), before, 1e-3), "driven never moves geometry")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
