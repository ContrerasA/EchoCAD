#!/usr/bin/env python3
"""M39 RPC test: explicit boolean targets, intersect, pattern of a cut
feature, face-plane follow-through, and the dialog's Targets picker driven
by real clicks."""

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


def sketch_rect(app, a, b):
    app.call("action.enter_sketch", {"plane": "XY"})
    sid = app.call("query.mode")["active_sketch"]
    c = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
    app.call("action.set_view", {"pan": c, "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world(a, steps=5)
    app.click_world(b, steps=5)
    app.call("action.finish_sketch")
    return sid


def vol(app, fid):
    for b in app.call("query.bodies")["bodies"]:
        if b["id"] == fid:
            return b["volume"]
    return -1.0


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    s1 = sketch_rect(app, [0, 0], [40, 30])
    p1 = app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]
    s2 = sketch_rect(app, [40, 0], [80, 30])
    p2 = app.call("action.extrude", {"sketch": s2, "at": [60, 15], "distance": 10})["feature"]

    # Straddling cut with explicit target: only plate 2 loses volume.
    s3 = sketch_rect(app, [35, 10], [45, 20])
    r = app.call("action.extrude", {"sketch": s3, "at": [40, 15], "distance": 10,
                                    "operation": "cut", "targets": [p2]})
    check(near(vol(app, p1), 12000.0, 0.05), f"targeted cut spares plate 1 ({vol(app, p1):.1f})")
    check(near(vol(app, p2), 11500.0, 0.05), f"targeted cut carves plate 2 ({vol(app, p2):.1f})")
    tl = app.call("query.timeline")
    cut_f = [f for f in tl["features"] if f["id"] == r["feature"]]
    check(bool(cut_f), "cut is in the timeline")

    # Intersect keeps the overlap only.
    s4 = sketch_rect(app, [20, 5], [60, 25])
    app.call("action.extrude", {"sketch": s4, "at": [40, 15], "distance": 10,
                                "operation": "intersect", "targets": [p1]})
    check(near(vol(app, p1), 20 * 20 * 10, 0.05), f"intersect keeps 20x20x10 ({vol(app, p1):.1f})")
    app.call("action.undo")

    # Pattern of the CUT feature (not a body): 4 instances re-cut plate 2.
    s5 = sketch_rect(app, [50, 2], [54, 6])
    hole = app.call("action.extrude", {"sketch": s5, "at": [52, 4], "distance": 10,
                                       "operation": "cut", "targets": [p2]})["feature"]
    before = vol(app, p2)
    pr = app.call("action.pattern_body", {"body": hole, "mode": "linear",
                                          "count1": 4, "offset1": [6, 0, 0]})
    check(near(vol(app, p2), before - 3 * 160.0, 0.05),
          f"pattern of a cut re-cuts 3 more holes ({before:.0f} -> {vol(app, p2):.0f})")
    check(len(app.call("query.bodies")["bodies"]) == 2, "feature pattern adds no bodies")
    errs = app.call("query.kernel")["errors"]
    check(pr["feature"] not in errs, "pattern has no rebuild error")

    # The Targets picker in the dialog, driven by real clicks: arm Extrude,
    # click the profile, type the distance, choose Cut, press Pick…, click
    # plate 1 in the viewport, Enter, OK. Plate 2 overlaps the cut too but
    # must be spared.
    s6 = sketch_rect(app, [36, 22], [44, 26])
    app.click_control("ExtrudeBtn")
    hit = app.call("query.plane_point", {"plane": "XY", "uv": [40, 24]})
    app.call("input.click", {"at": hit["p"]})
    dist = app.call("query.control", {"name": "ExtrudeDistEdit"})
    check(dist["visible"], "extrude dialog opened from the profile click")
    app.call("input.type", {"text": "10"})
    app.call("action.select_option", {"name": "ExtrudeOpPick", "index": 2})
    trow = app.call("query.control", {"name": "ExtrudeTargetsBtn"})
    check(trow["visible"], "Targets row shows for Cut")
    app.click_control("ExtrudeTargetsBtn")
    top = app.call("query.project", {"p": [10, 25, 10]})
    check(top["visible"], "plate 1 top face is on screen")
    app.call("input.click", {"at": top["p"]})
    chip = app.call("query.control", {"name": "ExtrudeTargetsBtnChip_" + p1})
    check(chip["visible"], "picked body shows as a chip")
    app.call("input.key", {"key": "enter"})
    v1, v2 = vol(app, p1), vol(app, p2)
    app.click_control("ExtrudeOkBtn")
    check(near(vol(app, p1), v1 - 4 * 4 * 10, 0.05),
          f"UI-targeted cut carves plate 1 ({v1:.0f} -> {vol(app, p1):.0f})")
    check(near(vol(app, p2), v2, 0.05), "UI-targeted cut spares plate 2")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
