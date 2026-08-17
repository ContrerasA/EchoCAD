#!/usr/bin/env python3
"""M20 RPC test: marquee selection through real pointer input (window and
crossing bands), the Parameters button/dialog, and parameter RPC actions
including reference-protected delete."""

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


def band(app, frm, to):
    # input.down presses at the CURRENT cursor -> park the cursor first.
    app.call("input.move", {"to": app.world_to_screen(frm), "steps": 3})
    app.call("input.down", {})
    mid = [(frm[0] + to[0]) / 2, (frm[1] + to[1]) / 2]
    app.call("input.move", {"to": app.world_to_screen(mid), "steps": 2})
    app.call("input.move", {"to": app.world_to_screen(to), "steps": 2})
    app.call("input.up", {})


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [30, 8], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # Two rectangles side by side.
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=4)
    app.click_world([20, 15], steps=4)
    app.click_world([40, 0], steps=4)
    app.click_world([60, 15], steps=4)
    app.call("input.key", {"key": "escape"})
    app.click_control("SelectToolBtn")

    # Window band (L->R) around rect A: 8 entities.
    band(app, [-5, -5], [25, 20])
    sel = app.call("query.selection")["selection"]
    check(len(sel) == 8, f"window band selects all of rect A (got {len(sel)})")

    # Crossing band (R->L) over rect B's right side: touching counts.
    band(app, [70, 8], [55, -5])
    sel = app.call("query.selection")["selection"]
    check(len(sel) >= 3, f"crossing band catches touched entities (got {len(sel)})")

    # Plain click on empty space deselects.
    app.call("input.click", {"at": app.world_to_screen([30, -12])})
    sel = app.call("query.selection")["selection"]
    check(len(sel) == 0, "empty click clears selection")

    # Parameters button opens the dialog.
    app.click_control("ParametersBtn")
    tree = app.call("query.control", {"name": "ParamsTree"})
    check(tree["visible"], "Parameters dialog opens with its table")
    app.call("input.key", {"key": "escape"})

    # Parameter actions: set, drive a dimension, protected delete.
    app.call("action.set_parameter", {"name": "gap", "expr": "1", "unit": "in"})
    params = app.call("query.parameters")["parameters"]
    check(len(params) == 1 and near(params[0]["value"], 25.4, 1e-6),
          f"parameter created (got {params})")
    lines = [e for e in app.entities() if e["kind"] == "line"]
    line = lines[0]
    app.call("action.add_constraint",
             {"type": "DISTANCE", "operands": [line["p0"], line["p1"]],
              "value": 20.0})
    cons = app.constraints()
    idx = [c["index"] for c in cons if c["type"] == "DISTANCE"][-1]
    app.call("action.set_dimension", {"index": idx, "text": "gap"})
    ents = app.entity_map()
    p0, p1 = ents[line["p0"]]["pos"], ents[line["p1"]]["pos"]
    length = ((p0[0] - p1[0]) ** 2 + (p0[1] - p1[1]) ** 2) ** 0.5
    check(near(length, 25.4, 0.05), f"dimension drove to gap (got {length:.2f})")
    try:
        app.call("action.delete_parameter", {"name": "gap"})
        check(False, "referenced parameter delete refused")
    except RpcError:
        check(True, "referenced parameter delete refused")
    app.call("action.delete_constraint", {"index": idx})
    app.call("action.delete_parameter", {"name": "gap"})
    check(len(app.call("query.parameters")["parameters"]) == 0,
          "unreferenced parameter deletes")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
