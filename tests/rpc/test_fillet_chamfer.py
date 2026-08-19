#!/usr/bin/env python3
"""M35 RPC test: 3D fillet/chamfer through the automation API."""

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


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # 40x30x10 box.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [20, 15], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=3)
    app.click_world([40, 30], steps=3)
    app.call("action.finish_sketch")
    body = app.call("action.extrude", {"sketch": sketch_id, "at": [20, 15],
                                       "distance": 10.0})["feature"]
    v_box = 40 * 30 * 10.0

    # Lateral fillet r5.
    r = app.call("action.fillet_edges",
                 {"body": body, "size": 5.0, "lateral": True, "top": False})
    fid = r["feature"]
    want = v_box - 4 * (25 - math.pi * 25 / 4) * 10
    got = app.call("query.bodies")["bodies"][0]["volume"]
    check(near(got, want, want * 0.01),
          f"lateral fillet volume ({got:.0f} vs {want:.0f})")

    # Second treatment refused; then undo and chamfer the top rim.
    try:
        app.call("action.chamfer_edges", {"body": body, "size": 2.0})
        check(False, "double treatment refused")
    except RpcError:
        check(True, "double treatment refused")
    app.call("action.undo")
    r = app.call("action.chamfer_edges",
                 {"body": body, "size": 3.0, "lateral": False, "top": True})
    got2 = app.call("query.bodies")["bodies"][0]["volume"]
    check(near(got2, v_box - 594.0, (v_box - 594) * 0.01),
          f"top chamfer volume ({got2:.0f})")

    # Oversize refused.
    app.call("action.undo")
    try:
        app.call("action.fillet_edges", {"body": body, "size": 25.0,
                                         "lateral": True, "top": False})
        check(False, "oversize refused")
    except RpcError:
        check(True, "oversize refused")

    # Timeline chip + suppress round trip.
    r = app.call("action.fillet_edges",
                 {"body": body, "size": 2.0, "lateral": True, "top": True})
    kinds = [f["kind"] for f in app.call("query.timeline")["features"]]
    check("edge_treat" in kinds, "treatment is a timeline feature")
    app.call("action.suppress", {"feature": r["feature"], "suppressed": True})
    got3 = app.call("query.bodies")["bodies"][0]["volume"]
    check(near(got3, v_box, 1.0), "suppress restores the sharp body")
    app.call("action.suppress", {"feature": r["feature"], "suppressed": False})

    for name in ["FilletEdgesBtn", "ChamferEdgesBtn"]:
        check(app.call("query.control", {"name": name})["visible"],
              f"{name} on the shelf")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_FILLET_CHAMFER OK")


if __name__ == "__main__":
    main()
