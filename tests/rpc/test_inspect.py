#!/usr/bin/env python3
"""M43 RPC test: mass properties, interference, section, print check
through the queries, and the Properties / Section dialogs via the UI."""

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


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    s1 = sketch_rect(app, [0, 0], [40, 30])
    box = app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]
    s2 = sketch_rect(app, [30, 20], [50, 40])
    box2 = app.call("action.extrude", {"sketch": s2, "at": [40, 30], "distance": 10})["feature"]

    mp = app.call("query.mass_properties", {"body": box, "material": "steel"})
    check(near(mp["volume_mm3"], 12000, 1e-6) and near(mp["mass_g"], 12 * 7.85, 1e-6),
          f"mass properties (steel {mp['mass_g']:.2f} g)")
    check(near(mp["centroid"][2], 5.0, 1e-4) and mp["watertight"], "centroid + watertight")

    ov = app.call("query.interference", {})["overlaps"]
    check(len(ov) == 1 and near(ov[0]["volume"], 1000.0, 1e-6), f"interference 1000 mm³ ({ov})")

    sec = app.call("action.section", {"on": True, "plane": "XY", "offset": 4, "body": box})
    check(sec["on"] and near(sec["kept_volume"], 4800.0, 1e-6), f"section keeps z<4 ({sec})")
    app.call("action.section", {"on": False})

    pc = app.call("query.print_check", {"body": box, "bed": [220, 220, 250]})
    check(pc["watertight"] and pc["fits"] and pc["overhang_ratio"] < 1e-9, f"print check ({pc})")
    pc2 = app.call("query.print_check", {"body": box, "bed": [20, 20, 20]})
    check(not pc2["fits"], "does not fit a 20 mm cube bed")

    # Properties dialog through the UI: select the body, press Properties.
    app.call("action.select", {"body": box}) if False else None
    app.click_control("PropertiesBtn")
    pt = app.call("query.project", {"p": [10, 10, 10]})
    app.call("input.click", {"at": pt["p"]})
    vol = app.call("query.control", {"name": "VolumeInfo"})
    check(vol["visible"] and "cm³" in vol["text"], f"properties dialog shows the volume ({vol['text']})")
    app.call("action.select_option", {"name": "PropsMaterialPick", "index": 7})
    mass = app.call("query.control", {"name": "MassInfo"})["text"]
    check("94.20 g" in mass, f"material switch to steel updates the mass ({mass})")
    app.click_control("PropertiesOkBtn")

    # Section dialog.
    app.click_control("SectionBtn")
    check(app.call("query.control", {"name": "SectionOnCheck"})["visible"], "section dialog opened")
    app.click_control("SectionOkBtn")
    check(app.call("query.control", {"name": "SectionBtn"})["visible"], "section button stays on the shelf")
    # Close keeps the section on (the button stays lit); Cancel switches it off.
    app.click_control("SectionBtn")
    app.click_control("SectionDialogCancelBtn")

    # Measure: arm, two clicks near two corners give a distance in the status
    # bar (the body fills the view so the snap tolerance is meaningful).
    app.call("action.fit")
    app.click_control("MeasureBtn")
    p1 = app.call("query.project", {"p": [0.3, 0.3, 10]})
    p2 = app.call("query.project", {"p": [39.7, 0.3, 10]})
    app.call("input.click", {"at": p1["p"]})
    app.call("input.click", {"at": p2["p"]})
    meas = app.call("query.control", {"name": "StatusMeasure"})["text"]
    hint = app.call("query.control", {"name": "StatusHint"})["text"]
    check("1.575 in" in meas or "40.000 mm" in meas, f"measure reports the 40 mm edge ({meas} / {hint})")
    app.call("input.key", {"key": "escape"})

    for name in ["MeasureBtn", "SectionBtn", "PropertiesBtn", "InterferenceBtn", "PrintCheckBtn"]:
        c = app.call("query.control", {"name": name})
        check(c["visible"] or bool(c.get("flyout_owner")), f"{name} on the shelf")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
