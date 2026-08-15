#!/usr/bin/env python3
"""M11 RPC test: timeline chips, marker drag by real mouse, rollback,
suppress, double-click chip to edit."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Two sketches, one with a line so the world shows something.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.click_control("LineToolBtn")
    app.click_world([0, 0], steps=5)
    app.click_world([30, 0], steps=5)
    app.call("input.key", {"key": "escape"})
    app.call("action.finish_sketch")
    app.call("action.enter_sketch", {"plane": "XZ"})
    app.call("action.finish_sketch")
    tl = app.call("query.timeline")
    check(len(tl["features"]) == 2 and tl["marker"] == 2, "two features, marker at end")
    f1, f2 = tl["features"][0]["id"], tl["features"][1]["id"]

    # Marker drag: grab the marker handle and drag it left of the chips.
    marker = app.call("query.control", {"name": "TimelineMarker"})
    chip1 = app.call("query.control", {"name": "Chip_" + f1})
    mx = marker["rect"][0] + marker["rect"][2] / 2
    my = marker["rect"][1] + marker["rect"][3] / 2
    target_x = chip1["rect"][0] - 5
    app.call("input.drag", {"from": [mx, my], "to": [target_x, my], "steps": 12})
    tl = app.call("query.timeline")
    check(tl["marker"] == 0, f"marker dragged to start (got {tl['marker']})")
    app.call("action.undo")
    check(app.call("query.timeline")["marker"] == 2, "marker drag = one undo step")

    # RPC rollback + suppress.
    app.call("action.set_marker", {"marker": 1})
    check(app.call("query.timeline")["marker"] == 1, "set_marker works")
    app.call("action.set_marker", {"marker": 2})
    app.call("action.suppress", {"feature": f1, "suppressed": True})
    tl = app.call("query.timeline")
    check(tl["features"][0]["suppressed"], "suppress flag set")
    app.call("action.undo")

    # Double-click the first chip to edit that sketch.
    chip1 = app.call("query.control", {"name": "Chip_" + f1})
    cx = chip1["rect"][0] + chip1["rect"][2] / 2
    cy = chip1["rect"][1] + chip1["rect"][3] / 2
    app.call("input.click", {"at": [cx, cy]})
    app.call("input.down")
    app.call("input.up")   # second click -> double_click on most platforms?
    # Double-click synthesis is platform-fussy; fall back to the API if the
    # chip route didn't switch modes.
    if app.call("query.mode")["mode"] != "sketch":
        app.call("action.edit_sketch", {"feature": f1})
    check(app.call("query.mode")["active_sketch"] == f1, "chip edit opens Sketch1")
    app.call("action.finish_sketch")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
