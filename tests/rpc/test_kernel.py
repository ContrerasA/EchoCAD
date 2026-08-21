#!/usr/bin/env python3
"""M38 RPC test: the Manifold kernel — exact cut volumes, watertight
bodies, face census, a no-target cut flagged as a red chip with its reason,
and query.kernel."""

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


def draw_rect(app, a, b):
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world(a, steps=5)
    app.click_world(b, steps=5)


def sketch_rect(app, a, b):
    app.call("action.enter_sketch", {"plane": "XY"})
    sid = app.call("query.mode")["active_sketch"]
    draw_rect(app, a, b)
    app.call("action.finish_sketch")
    return sid


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    k = app.call("query.kernel")
    check(k["manifold"] is True, f"Manifold kernel loaded ({k['kernel']})")
    check(k["errors"] == {}, "no rebuild errors on an empty document")

    # Plate with an exact pocket: no EPS inflation of the cut.
    s1 = sketch_rect(app, [0, 0], [40, 30])
    app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})
    s2 = sketch_rect(app, [10, 10], [20, 20])
    r = app.call("action.extrude", {"sketch": s2, "at": [15, 15],
                                    "distance": 10, "operation": "cut"})
    check(near(r["body_volume"], 11000.0, 0.05),
          f"pocket cut volume exact (got {r['body_volume']:.3f})")
    bodies = app.call("query.bodies")["bodies"]
    check(len(bodies) == 1, "one body")
    b = bodies[0]
    check(b.get("watertight") is True, "body is watertight")
    check(b.get("genus") == 1, f"through-pocket body has genus 1 (got {b.get('genus')})")
    check(len(b.get("face_features", [])) == 2,
          f"faces from both features survive ({b.get('face_features')})")

    # Flush notch: shares the plate's edge — exact too.
    s3 = sketch_rect(app, [30, 20], [40, 30])
    r2 = app.call("action.extrude", {"sketch": s3, "at": [35, 25],
                                     "distance": 12, "operation": "cut"})
    check(near(r2["body_volume"], 10000.0, 0.05),
          f"flush notch volume exact (got {r2['body_volume']:.3f})")

    # A cut far from everything: red chip, reason in tooltip, query.kernel.
    s4 = sketch_rect(app, [60, 40], [70, 50])
    r3 = app.call("action.extrude", {"sketch": s4, "at": [65, 45],
                                     "distance": 5, "operation": "cut"})
    fid = r3["feature"] if "feature" in r3 else r3.get("id")
    errs = app.call("query.kernel")["errors"]
    check(fid in errs, f"no-target cut reports a rebuild error ({errs})")
    chip = app.call("query.control", {"name": "Chip_" + fid})
    check(chip["variation"] == "TimelineChipError", "its chip is error-tinted")
    check(errs.get(fid, "") in chip["tooltip"], "chip tooltip carries the reason")
    app.call("action.undo")
    app.call("action.undo")
    check(app.call("query.kernel")["errors"] == {}, "undo clears the error")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
