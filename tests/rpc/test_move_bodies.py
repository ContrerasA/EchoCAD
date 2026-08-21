#!/usr/bin/env python3
"""M32 RPC test: move/copy bodies + color through the automation API and
the shelf dialogs."""

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

    # Box body.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [20, 15], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    sketch_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=3)
    app.click_world([40, 30], steps=3)
    app.call("action.finish_sketch")
    r = app.call("action.extrude", {"sketch": sketch_id, "at": [20, 15],
                                    "distance": 10.0})
    body = app.call("query.bodies")["bodies"][0]["id"]
    vol0 = app.call("query.bodies")["bodies"][0]["volume"]

    # Move.
    r = app.call("action.move_body",
                 {"body": body, "translation": [25, 0, 5]})
    check(r["feature"].startswith("f"), "move feature created")
    b = app.call("query.bodies")["bodies"][0]
    check(near(b["aabb"][0], 25.0, 1e-3) and near(b["aabb"][2], 5.0, 1e-3),
          f"body moved (aabb {b['aabb'][:3]})")
    check(near(b["volume"], vol0, vol0 * 1e-5), "volume preserved")

    # Rotate 90 about Z: extents swap.
    app.call("action.undo")
    r = app.call("action.move_body",
                 {"body": body, "translation": [0, 0, 0],
                  "axis": [0, 0, 1], "angle": 90.0})
    b = app.call("query.bodies")["bodies"][0]
    check(near(b["aabb"][3], 30.0, 1e-3) and near(b["aabb"][4], 40.0, 1e-3),
          f"rotation swapped extents ({b['aabb'][3:]})")

    try:
        app.call("action.move_body", {"body": body, "translation": [0, 0, 0]})
        check(False, "zero move refused")
    except RpcError:
        check(True, "zero move refused")

    # Copy.
    r = app.call("action.copy_body",
                 {"body": body, "translation": [100, 0, 0]})
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 2, "copy produced a second body")
    copy = next(x for x in bodies if x["id"] == r["feature"])
    check(near(copy["volume"], vol0, vol0 * 1e-5), "copy volume matches")

    # Color. A copy inherits the source color until it is given one of its
    # own (QA fix round §M32.5) — so coloring a copy now SUCCEEDS.
    app.call("action.set_body_color", {"body": body, "color": [0.9, 0.1, 0.1]})
    try:
        app.call("action.set_body_color",
                 {"body": r["feature"], "color": [0, 1, 0]})
        check(True, "coloring a copy accepted (own color override)")
    except RpcError:
        check(False, "coloring a copy accepted (own color override)")

    # Shelf buttons + timeline features present.
    for name in ["MoveBodyBtn", "CopyBodyBtn"]:
        c = app.call("query.control", {"name": name})
        # Stacked tools (M42 ribbon): the stack's face is visible, the other
        # variants live in its flyout (flyout_owner names the stack button).
        check(c["visible"] or bool(c.get("flyout_owner")), f"{name} on the shelf")
    kinds = [f["kind"] for f in app.call("query.timeline")["features"]]
    check("transform" in kinds and "copy_body" in kinds,
          "move/copy are timeline features")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_MOVE_BODIES OK")


if __name__ == "__main__":
    main()
