#!/usr/bin/env python3
"""M41 RPC test: edge chains of a body, fillet/chamfer through the action,
and the Fillet dialog driven by clicks (candidate edges, chain toggle,
size, OK), then editing the feature from its chip."""

import math
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
    app.call("action.set_view", {"pan": [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], "zoom": 4.0})
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
    box = app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]
    edges = app.call("query.edges", {"body": box})["edges"]
    check(len(edges) == 12 and all(e["convex"] and not e["closed"] for e in edges),
          f"box has 12 open convex chains ({len(edges)})")

    # Chamfer one top edge through the action.
    r = app.call("action.edge_fillet", {"body": box, "treat": "chamfer", "size": 3,
                                        "near": [[20, 0, 10]]})
    check(r["edges"] == 1 and near(r["body_volume"], 12000 - 0.5 * 9 * 40, 0.05),
          f"chamfer volume ({r['body_volume']:.2f})")
    app.call("action.undo")

    # Fillet two edges: the straight one and, after a through hole, its rim.
    faces = [b for b in app.call("query.bodies", {"faces": True})["bodies"] if b["id"] == box][0]["faces"]
    topf = max(faces, key=lambda f: f["point"][2])
    app.call("action.hole", {"body": box, "face": topf["face"], "uv": [[30, 15]],
                             "diameter": 8, "extent": "through_all"})
    edges = app.call("query.edges", {"body": box})["edges"]
    rims = [e for e in edges if e["closed"] and abs(e["mid"][2] - 10) < 1e-3]
    check(len(rims) == 1 and rims[0]["points"] >= 40, f"hole top rim is one closed chain ({len(rims)})")
    v_before = vol(app, box)
    r = app.call("action.edge_fillet", {"body": box, "treat": "fillet", "size": 1.5,
                                        "near": [[20, 0, 10], [34, 15, 10]]})
    check(r["edges"] == 2 and r["error"] == "" and r["body_volume"] < v_before - 10,
          f"fillet of a straight edge + hole rim ({v_before:.1f} -> {r['body_volume']:.1f}, {r['error']})")
    bodies = app.call("query.bodies")["bodies"]
    check(bodies[0]["watertight"], "filleted body watertight")
    app.call("action.undo")

    # The dialog: Fillet button -> candidates shown -> click the top-back
    # edge midpoint -> type size -> OK.
    app.click_control("FilletEdgesBtn")
    lab = app.call("query.control", {"name": "FilletPickBtn"})
    check(lab["visible"], "fillet dialog opened with the pick armed")
    pt = app.call("query.project", {"p": [20, 30, 10]})
    app.call("input.click", {"at": pt["p"]})
    info = app.call("query.control", {"name": "EdgesInfo"})
    check(info["text"].startswith("1 picked"), f"click picked the chain ({info['text']})")
    # Clicking again toggles it off, and again on.
    app.call("input.click", {"at": pt["p"]})
    check(app.call("query.control", {"name": "EdgesInfo"})["text"] == "none picked", "second click toggles off")
    app.call("input.click", {"at": pt["p"]})
    app.call("input.key", {"key": "enter"})
    app.click_control("FilletSizeEdit")
    app.call("input.key", {"key": "a", "modifiers": ["ctrl"]})
    app.call("input.type", {"text": "2mm"})
    v0 = vol(app, box)
    app.click_control("FilletOkBtn")
    seg = 4 - math.pi
    check(vol(app, box) < v0 - seg * 40 * 0.9 and vol(app, box) > v0 - seg * 40 * 1.2,
          f"dialog fillet applied ({v0:.1f} -> {vol(app, box):.1f})")
    tl = app.call("query.timeline")["features"]
    check(tl[-1]["kind"] == "edge_fillet", "edge_fillet feature in the timeline")
    fid = tl[-1]["id"]

    # Edit from the chip: switch to chamfer 3 mm.
    chip = app.call("query.control", {"name": "Chip_" + fid})
    x, y, w, h = chip["rect"]
    app.call("input.click", {"at": [x + w / 2, y + h / 2], "double": True})
    check(app.call("query.control", {"name": "FilletSizeEdit"})["visible"], "chip double-click edits the fillet")
    check(app.call("query.control", {"name": "EdgesInfo"})["text"].startswith("1 picked"),
          "edit dialog re-selects the feature's edge")
    app.call("action.select_option", {"name": "FilletKindPick", "index": 1})
    app.click_control("FilletSizeEdit")
    app.call("input.key", {"key": "a", "modifiers": ["ctrl"]})
    app.call("input.type", {"text": "3mm"})
    app.click_control("FilletOkBtn")
    check(near(vol(app, box), v0 - 0.5 * 9 * 40, 0.05), f"edited to a 3 mm chamfer ({vol(app, box):.2f})")
    check(app.call("query.kernel")["errors"] == {}, "no rebuild errors")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
