#!/usr/bin/env python3
"""M33 RPC test: mirror + pattern bodies through the automation API."""

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
    app.call("action.set_view", {"pan": [25, 10], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([10, 0], steps=3)
    app.click_world([40, 20], steps=3)
    app.call("action.finish_sketch")
    app.call("action.extrude", {"sketch": sketch_id, "at": [25, 10],
                                "distance": 8.0})
    body = app.call("query.bodies")["bodies"][0]
    vol0 = body["volume"]

    # Mirror across YZ.
    r = app.call("action.mirror_body", {"body": body["id"], "plane": "YZ"})
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 2, "mirror adds a body")
    mirrored = next(b for b in bodies if b["id"] == r["feature"])
    check(near(mirrored["volume"], vol0, vol0 * 1e-5),
          "mirrored volume positive and equal")
    check(mirrored["aabb"][0] < -39.9, "mirrored into -X")
    try:
        app.call("action.mirror_body", {"body": body["id"], "plane": "nope"})
        check(False, "bogus plane refused")
    except RpcError:
        check(True, "bogus plane refused")

    # Linear pattern 3x.
    r = app.call("action.pattern_body",
                 {"body": body["id"], "mode": "linear", "count1": 3,
                  "offset1": [50, 0, 0]})
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 4, f"linear pattern bodies ({len(bodies)})")
    xs = sorted(round(b["aabb"][0]) for b in bodies)
    check(xs == [-40, 10, 60, 110], f"instances at 50mm steps ({xs})")
    app.call("action.undo")

    # Circular pattern 4x about Z.
    r = app.call("action.pattern_body",
                 {"body": body["id"], "mode": "circular", "count1": 4,
                  "axis_origin": [0, 0, 0], "axis_dir": [0, 0, 1],
                  "total_deg": 360.0})
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 5, f"circular pattern bodies ({len(bodies)})")
    for b in bodies:
        check_vol = near(b["volume"], vol0, vol0 * 1e-4)
        if not check_vol:
            check(False, f"instance volume drifted ({b['volume']})")
            break
    else:
        check(True, "instance volumes preserved")

    # Suppress kills the instances; unsuppress brings them back.
    app.call("action.suppress", {"feature": r["feature"], "suppressed": True})
    check(len(app.call("query.bodies")["bodies"]) == 2, "suppress removes instances")
    app.call("action.suppress", {"feature": r["feature"], "suppressed": False})
    check(len(app.call("query.bodies")["bodies"]) == 5, "unsuppress restores")

    for name in ["MirrorBodyBtn", "PatternBodyBtn"]:
        check(app.call("query.control", {"name": name})["visible"],
              f"{name} on the shelf")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_SOLID_PATTERNS OK")


if __name__ == "__main__":
    main()
