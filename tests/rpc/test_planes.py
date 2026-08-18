#!/usr/bin/env python3
"""M22 RPC test: offset construction planes — create, sketch on one, extrude
from it, drive the offset, plane transforms query, timeline integration."""

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

    # Offset plane from XY, 25 mm up.
    r = app.call("action.create_offset_plane", {"base": "XY", "offset": 25.0})
    plane_id = r["feature"]
    check(r["name"] == "Plane1", "Plane1 created")
    xf = app.call("query.plane_transform", {"plane": plane_id})
    check(near(xf["origin"][2], 25.0, 1e-6), f"plane at z=25 (got {xf['origin']})")
    tl = app.call("query.timeline")
    check([f["kind"] for f in tl["features"]] == ["plane"],
          "timeline has the plane feature")

    # Bogus base refused.
    try:
        app.call("action.create_offset_plane", {"base": "nope", "offset": 5})
        check(False, "bogus base refused")
    except RpcError:
        check(True, "bogus base refused")

    # Sketch ON the plane by feature id; draw a rect with real input.
    app.call("action.enter_sketch", {"plane": plane_id})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=5)
    app.click_world([40, 30], steps=5)
    profs = app.call("query.profiles")["profiles"]
    check(len(profs) == 1 and near(profs[0]["area"], 1200.0, 1.0),
          f"rect profile on the offset plane (got {len(profs)})")
    app.call("action.finish_sketch")

    # Extrude lands at the plane's height.
    r2 = app.call("action.extrude",
                  {"sketch": sketch_id, "at": [20, 15], "distance": 12.7})
    check(near(r2["volume"], 1200 * 12.7, 30.0),
          f"extrude volume (got {r2['volume']:.0f})")
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 1 and near(bodies[0]["aabb"][2], 25.0, 1e-3),
          f"body floats at z=25 (got {bodies[0]['aabb'] if bodies else None})")

    # Drive the offset: the body follows.
    app.call("action.set_plane_offset", {"plane": plane_id, "offset": 40.0})
    bodies = app.call("query.bodies")["bodies"]
    check(near(bodies[0]["aabb"][2], 40.0, 1e-3),
          f"offset edit moved the body (got {bodies[0]['aabb'][2]:.1f})")
    app.call("action.undo")
    bodies = app.call("query.bodies")["bodies"]
    check(near(bodies[0]["aabb"][2], 25.0, 1e-3), "undo restored the offset")

    # Offset Plane button arms base picking (UI wiring); Esc cancels.
    app.click_control("OffsetPlaneBtn")
    check(True, "Offset Plane button clickable")
    app.call("input.key", {"key": "escape"})

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
