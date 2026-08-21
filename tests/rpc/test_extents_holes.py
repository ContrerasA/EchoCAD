#!/usr/bin/env python3
"""M40 RPC test: extrude extents through the action and the edit dialog,
the hole wizard through action.hole and through the dialog (face pick +
placement clicks), query.bodies faces."""

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


def sketch_rect(app, a, b, plane="XY"):
    app.call("action.enter_sketch", {"plane": plane})
    sid = app.call("query.mode")["active_sketch"]
    app.call("action.set_view", {"pan": [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world(a, steps=5)
    app.click_world(b, steps=5)
    app.call("action.finish_sketch")
    return sid


def body(app, fid, faces=False):
    for b in app.call("query.bodies", {"faces": faces})["bodies"]:
        if b["id"] == fid:
            return b
    return None


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Symmetric + taper through the action.
    s1 = sketch_rect(app, [0, 0], [10, 10])
    r = app.call("action.extrude", {"sketch": s1, "at": [5, 5], "distance": 10,
                                    "extent": "symmetric", "symmetric_whole": True})
    b = body(app, r["feature"])
    check(near(b["volume"], 1000.0, 0.01) and near(b["aabb"][2], -5.0, 1e-3),
          f"symmetric whole spans -5..5 ({b['aabb'][2]:.2f})")
    app.call("action.undo")
    r = app.call("action.extrude", {"sketch": s1, "at": [5, 5], "distance": 10,
                                    "taper_deg": 10})
    top = 10 + 2 * 10 * math.tan(math.radians(10))
    frustum = 10 / 3 * (100 + top * top + math.sqrt(100 * top * top))
    b = body(app, r["feature"])
    check(near(b["volume"], frustum, frustum * 1e-3), f"taper frustum ({b['volume']:.1f})")
    check(b["watertight"], "tapered body watertight")
    app.call("action.undo")

    # Plate + through-all cut from a plane below; to_face via faces list.
    plate = app.call("action.extrude", {"sketch": s1, "at": [5, 5], "distance": 10})["feature"]
    faces = body(app, plate, faces=True)["faces"]
    topf = max(faces, key=lambda f: f["point"][2])
    check(near(topf["normal"][2], 1.0, 1e-6) and near(topf["point"][2], 10.0, 1e-6),
          "query.bodies faces lists the top face")

    # Edit dialog: double-click the plate's chip, switch to Two Sided, set 3 the other way.
    chip = app.call("query.control", {"name": "Chip_" + plate})
    x, y, w, h = chip["rect"]
    app.call("input.click", {"at": [x + w / 2, y + h / 2], "double": True})
    dlg = app.call("query.control", {"name": "ExtrudeDistEdit"})
    check(dlg["visible"], "double-click opens the extrude edit dialog")
    app.call("action.select_option", {"name": "ExtrudeExtentPick", "index": 2})
    d2 = app.call("query.control", {"name": "ExtrudeDist2Edit"})
    check(d2["visible"], "Two Sided shows the second distance row")
    app.click_control("ExtrudeDist2Edit")
    app.call("input.key", {"key": "a", "modifiers": ["ctrl"]})
    app.call("input.type", {"text": "3mm"})
    app.click_control("ExtrudeOkBtn")
    b = body(app, plate)
    check(near(b["aabb"][2], -3.0, 1e-3) and near(b["volume"], 1300.0, 0.05),
          f"two-sided edit applied (-3..10: {b['aabb'][2]:.2f}, {b['volume']:.1f})")
    app.call("action.undo")

    # Holes through the action: two M6 clearance through holes.
    r = app.call("action.hole", {"body": plate, "face": topf["face"], "uv": [[3, 5], [7, 5]],
                                 "diameter": 6.6, "extent": "through_all"})
    check(r["error"] == "", f"hole action ok ({r['error']})")
    b = body(app, plate)
    check(b["volume"] < 1000.0 - 400.0, f"holes removed material ({b['volume']:.1f})")
    check(b["watertight"], "holed body watertight")
    app.call("action.undo")

    # Hole wizard through the UI: Hole button -> face pick armed -> click the
    # top face -> placement armed -> click two centres -> Enter -> OK.
    app.click_control("HoleBtn")
    topc = app.call("query.project", {"p": [5, 5, 10]})
    app.call("input.click", {"at": topc["p"]})
    face_lab = app.call("query.control", {"name": "FaceInfo"})
    check("face of" in face_lab["text"], f"face pick filled the dialog ({face_lab['text']})")
    for px in (3.0, 7.0):
        pt = app.call("query.project", {"p": [px, 5, 10]})
        app.call("input.click", {"at": pt["p"]})
    pos_lab = app.call("query.control", {"name": "PositionsInfo"})
    check(pos_lab["text"].startswith("2"), f"two positions placed ({pos_lab['text']})")
    app.call("input.key", {"key": "enter"})
    before = body(app, plate)["volume"]
    app.click_control("HoleOkBtn")
    after = body(app, plate)["volume"]
    check(after < before - 100, f"wizard holes cut the plate ({before:.0f} -> {after:.0f})")
    tl = app.call("query.timeline")["features"]
    check(tl[-1]["kind"] == "hole", "Hole feature at the end of the timeline")
    check(app.call("query.kernel")["errors"] == {}, "no rebuild errors")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
