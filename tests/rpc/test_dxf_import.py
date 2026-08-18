#!/usr/bin/env python3
"""M25 RPC test: action.import_dxf — export/import round trip, extrude of
the imported profile, error handling."""

import os
import sys
import tempfile

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
    tmp = tempfile.mkdtemp(prefix="echocad_dxfi_")

    # Draw a rect + circle, export DXF.
    app.call("action.enter_sketch", {"plane": "XY"})
    s1 = app.call("query.mode")["active_sketch"]
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=5)
    app.click_world([40, 30], steps=5)
    app.click_control("CircleToolBtn")
    app.click_world([60, 15], steps=5)
    app.click_world([65, 15], steps=5)
    app.call("action.finish_sketch")
    path = os.path.join(tmp, "round.dxf")
    app.call("action.export_dxf", {"path": path, "sketch": s1})

    # Import it back: census matches, timeline gains a sketch.
    r = app.call("action.import_dxf", {"path": path})
    check(r["lines"] == 4 and r["circles"] == 1 and r["arcs"] == 0,
          f"round-trip census (got {r})")
    tl = app.call("query.timeline")
    check([f["kind"] for f in tl["features"]] == ["sketch", "sketch"],
          "timeline gained the imported sketch")

    # The imported rect welds closed: extrude it.
    r2 = app.call("action.extrude",
                  {"sketch": r["feature"], "at": [20, 15], "distance": 10})
    check(near(r2["volume"], 12000.0, 30.0),
          f"imported profile extrudes (got {r2['volume']:.0f})")

    # Missing / malformed files refuse.
    try:
        app.call("action.import_dxf", {"path": os.path.join(tmp, "nope.dxf")})
        check(False, "missing file refused")
    except RpcError:
        check(True, "missing file refused")
    bad = os.path.join(tmp, "bad.dxf")
    with open(bad, "w") as f:
        f.write("not a dxf\n")
    try:
        app.call("action.import_dxf", {"path": bad})
        check(False, "malformed file refused")
    except RpcError:
        check(True, "malformed file refused")

    # Import button exists (UI wiring).
    app.click_control("ImportDxfBtn")
    check(True, "Import DXF button clickable")
    app.call("input.key", {"key": "escape"})

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
