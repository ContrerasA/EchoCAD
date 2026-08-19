#!/usr/bin/env python3
"""M28 RPC test: spline drawn through real input, Enter finishes, closed
spline extrudes, handle drag reshapes the curve inside one undo step."""

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
    app.call("action.set_view", {"pan": [40, 10], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})

    # Open spline: 4 clicks + Enter.
    app.click_control("SplineToolBtn")
    check(app.call("query.active_tool")["tool"] == "spline",
          "spline tool active via shelf button")
    for p in [(5, 3), (25, 21), (50, -2), (75, 13)]:
        app.click_world(p, steps=3)
    app.call("input.key", {"key": "enter"})
    splines = app.entities_of_kind("spline")
    check(len(splines) == 1, "one spline committed on Enter")
    sp = splines[0]
    check(len(sp["points"]) == 4 and not sp["closed"], "4 fit points, open")
    pts = app.entities_of_kind("point")
    check(len(pts) == 4, "fit points are real sketch points")

    # Undo removes the whole curve in one step.
    app.call("action.undo")
    check(len(app.entities_of_kind("spline")) == 0, "undo removes the spline")
    app.call("action.redo")
    sp = app.entities_of_kind("spline")[0]

    # Handle drag: select the spline, grab the handle square near fit point 1
    # (out control = p + tangent/3, Catmull-Rom auto tangent), drag it.
    emap = app.entity_map()
    fitpos = [emap[pid]["pos"] for pid in sp["points"]]
    tangent = [(fitpos[2][0] - fitpos[0][0]) / 2.0,
               (fitpos[2][1] - fitpos[0][1]) / 2.0]
    handle = [fitpos[1][0] + tangent[0] / 3.0, fitpos[1][1] + tangent[1] / 3.0]
    app.click_control("SelectToolBtn")
    app.click_world(fitpos[1])   # clicking the fit point also selects... a point
    app.call("action.select", {"ids": [sp["id"]]})
    app.call("input.drag", {"from": app.world_to_screen(handle),
                            "to": app.world_to_screen([handle[0] + 8,
                                                       handle[1] + 6]),
                            "steps": 8})
    sp2 = app.entities_of_kind("spline")[0]
    check(sp2["handles"][1] is not None, "handle drag stored an override")
    app.call("action.undo")
    sp3 = app.entities_of_kind("spline")[0]
    check(sp3["handles"][1] is None, "one undo clears the handle gesture")

    # Closed spline in a fresh sketch: last click back on the first point.
    app.call("action.finish_sketch")
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [135, 20], "zoom": 3.0})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("SplineToolBtn")
    ring = [(120, 0), (150, 8), (160, 35), (130, 42), (110, 25)]
    for p in ring:
        app.click_world(p, steps=3)
    app.click_world(ring[0], steps=3)
    sps = app.entities_of_kind("spline")
    check(len(sps) == 1 and sps[0]["closed"],
          "clicking the first point closes the spline")
    profs = app.call("query.profiles")["profiles"]
    check(len(profs) == 1, "closed spline is a profile")
    area = profs[0]["area"]
    app.call("action.finish_sketch")
    r = app.call("action.extrude",
                 {"sketch": sketch_id, "at": [135, 20], "distance": 10.0})
    check(near(r["volume"], area * 10.0, area * 0.25),
          f"spline extrude volume (got {r['volume']:.0f} vs {area * 10:.0f})")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_SPLINES OK")


if __name__ == "__main__":
    main()
