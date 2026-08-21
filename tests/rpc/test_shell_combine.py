#!/usr/bin/env python3
"""M42 RPC test: shell / combine / split / press-pull through the actions
and the Shell + Press Pull dialogs driven by clicks."""

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


def body(app, fid):
    for b in app.call("query.bodies", {"faces": True})["bodies"]:
        if b["id"] == fid:
            return b
    return None


def top_face(b):
    return max(b["faces"], key=lambda f: f["point"][2])


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    s1 = sketch_rect(app, [0, 0], [40, 30])
    box = app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]
    topf = top_face(body(app, box))

    r = app.call("action.shell", {"body": box, "thickness": 2,
                                  "remove": [{"body": box, "face": topf["face"]}]})
    check(r["error"] == "" and near(r["body_volume"], 12000 - 36 * 26 * 8, 0.05),
          f"shell open-top volume ({r['body_volume']:.1f})")
    app.call("action.undo")

    s2 = sketch_rect(app, [30, 10], [60, 20])
    bar = app.call("action.extrude", {"sketch": s2, "at": [45, 15], "distance": 10})["feature"]
    r = app.call("action.combine", {"target": box, "tools": [bar], "operation": "cut"})
    check(near(r["body_volume"], 11000.0, 0.05) and len(app.call("query.bodies")["bodies"]) == 1,
          f"combine cut consumed the tool ({r['body_volume']:.1f})")
    app.call("action.undo")

    pl = app.call("action.create_offset_plane", {"base": "XZ", "offset": -10})["feature"]
    r = app.call("action.split_body", {"body": box, "plane": pl})
    check(r["error"] == "" and near(r["kept_volume"] + r["other_volume"], 12000.0, 0.05)
          and min(r["kept_volume"], r["other_volume"]) > 1000,
          f"split halves sum ({r['kept_volume']:.0f} + {r['other_volume']:.0f})")
    app.call("action.undo")
    app.call("action.undo")

    r = app.call("action.press_pull", {"face": {"body": box, "face": topf["face"]}, "distance": 5})
    check(near(r["body_volume"], 18000.0, 0.05), f"press pull +5 ({r['body_volume']:.1f})")
    app.call("action.undo")

    # Shell dialog: button -> click the top face -> Enter -> thickness -> OK.
    app.click_control("ShellBtn")
    pt = app.call("query.project", {"p": [20, 15, 10]})
    app.call("input.click", {"at": pt["p"]})
    check(app.call("query.control", {"name": "FacesInfo"})["text"].startswith("1 face"),
          "shell dialog took the clicked face")
    app.call("input.key", {"key": "enter"})
    app.click_control("ShellThicknessEdit")
    app.call("input.key", {"key": "a", "modifiers": ["ctrl"]})
    app.call("input.type", {"text": "3mm"})
    app.click_control("ShellOkBtn")
    b = body(app, box)
    check(near(b["volume"], 12000 - 34 * 24 * 7, 0.05), f"dialog shell 3 mm ({b['volume']:.1f})")
    check(b["watertight"], "shelled body watertight")
    app.call("action.undo")

    # Press Pull dialog: button -> click the top face -> distance -> OK.
    app.click_control("PressPullBtn")
    app.call("input.click", {"at": pt["p"]})
    check("face of" in app.call("query.control", {"name": "FaceInfo"})["text"], "press pull took the face")
    app.click_control("PressPullDistEdit")
    app.call("input.key", {"key": "a", "modifiers": ["ctrl"]})
    app.call("input.type", {"text": "-4mm"})
    app.click_control("PressPullOkBtn")
    check(near(body(app, box)["volume"], 12000 - 4800, 0.05), f"dialog push -4 ({body(app, box)['volume']:.1f})")
    kinds = [f["kind"] for f in app.call("query.timeline")["features"]]
    check(kinds[-1] == "face_offset", "face_offset feature in the timeline")
    for name in ["ShellBtn", "CombineBtn", "SplitBodyBtn", "PressPullBtn"]:
        c = app.call("query.control", {"name": name})
        # Stacked tools (M42 ribbon): the stack's face is visible, the other
        # variants live in its flyout (flyout_owner names the stack button).
        check(c["visible"] or bool(c.get("flyout_owner")), f"{name} on the shelf")
    check(app.call("query.kernel")["errors"] == {}, "no rebuild errors")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
