#!/usr/bin/env python3
"""M15 RPC test: project reference geometry with real clicks, source-follow."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Source sketch: a rectangle on XY.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [30, 25], "zoom": 6.0})
    app.call("action.set_pref", {"grid_snap": False, "inference": False})
    src_id = app.call("query.mode")["active_sketch"]
    app.click_control("RectToolBtn")
    app.click_world([10, 10], steps=6)
    app.click_world([50, 40], steps=8)
    check(len(app.entities_of_kind("line")) == 4, "source rect drawn")
    app.click_control("FinishSketchBtn")

    # Target sketch on the same plane; the rect shows as dimmed reference.
    app.call("action.enter_sketch", {"plane": "XY"})
    app.call("action.set_view", {"pan": [30, 25], "zoom": 6.0})
    tgt_id = app.call("query.mode")["active_sketch"]
    check(tgt_id != src_id, "second sketch is a new feature")

    # Project the bottom edge with a real toolbar click + canvas click.
    app.click_control("ProjectToolBtn")
    check(app.call("query.active_tool")["tool"] == "project",
          "toolbar click activates project tool")
    app.click_world([30, 10], steps=6)
    lines = app.entities_of_kind("line")
    pts = app.entities_of_kind("point")
    check(len(lines) == 1 and len(pts) == 2,
          f"projected line + 2 points (got {len(lines)}L/{len(pts)}P)")
    check(all("link" in e for e in lines + pts),
          "projected entities carry their source link")
    ys = sorted(p["pos"][1] for p in pts)
    check(near(ys[0], 10) and near(ys[1], 10), "projection is an exact copy")

    # One undo removes the whole projection.
    app.call("action.undo")
    check(len(app.entities()) == 0, "projection is one undo step")
    app.call("action.redo")

    # Snapping works: a line started ON a projected endpoint welds to it.
    proj_pt = next(p for p in app.entities_of_kind("point")
                   if near(p["pos"][0], 10) and near(p["pos"][1], 10))
    app.click_control("LineToolBtn")
    app.click_world([10, 10], steps=6)
    app.click_world([10, -10], steps=6)
    app.call("input.key", {"key": "escape"})
    drawn = app.entities_of_kind("line")
    new_line = [l for l in drawn if "link" not in l][0]
    check(proj_pt["id"] in (new_line["p0"], new_line["p1"]),
          "line welds onto the projected endpoint (snap works)")
    app.click_control("FinishSketchBtn")

    # Edit the SOURCE: drag its (10,10) corner; the projection follows.
    app.call("action.edit_sketch", {"feature": src_id})
    app.call("action.set_view", {"pan": [30, 25], "zoom": 6.0})
    app.click_control("SelectToolBtn")
    app.call("input.drag", {"from": app.world_to_screen([10, 10]),
                            "to": app.world_to_screen([4, 6]), "steps": 12})
    app.click_control("FinishSketchBtn")
    tpts = app.entities_of_kind("point", sketch=tgt_id)
    moved = [p for p in tpts if "link" in p and near(p["pos"][0], 4, 0.5)
             and near(p["pos"][1], 6, 0.5)]
    check(len(moved) == 1,
          f"projected corner followed the source drag (pts {[(p['pos']) for p in tpts if 'link' in p]})")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
