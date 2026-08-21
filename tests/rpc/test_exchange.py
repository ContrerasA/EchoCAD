#!/usr/bin/env python3
"""M44 RPC test: 3MF / OBJ export, mesh import as bodies (with scale), SVG
export, and the ribbon buttons."""

import os
import sys
import tempfile
import zipfile

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
    tmp = tempfile.mkdtemp(prefix="echocad_m44_")

    s1 = sketch_rect(app, [0, 0], [40, 30])
    box = app.call("action.extrude", {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]

    p3 = os.path.join(tmp, "box.3mf")
    app.call("action.export_mesh", {"path": p3, "format": "3mf"})
    with zipfile.ZipFile(p3) as z:
        names = z.namelist()
        model = z.read("3D/3dmodel.model").decode()
    check("3D/3dmodel.model" in names and "[Content_Types].xml" in names, "3MF has the core parts")
    check('unit="millimeter"' in model and "<triangle" in model and 'name="Extrude1"' in model,
          "3MF model XML: mm, triangles, body name")

    pobj = os.path.join(tmp, "box.obj")
    app.call("action.export_mesh", {"path": pobj, "format": "obj"})
    with open(pobj) as f:
        obj = f.read()
    check(obj.count("\nv ") == 8 and obj.count("\nf ") == 12, "OBJ: 8 welded vertices, 12 faces")

    r = app.call("action.import_mesh", {"path": pobj})
    check(r["count"] == 1 and r["errors"] == {}, f"OBJ imports as a body ({r})")
    bodies = app.call("query.bodies")["bodies"]
    imported = [b for b in bodies if b["id"] == r["features"][0]]
    check(len(imported) == 1 and near(imported[0]["volume"], 12000, 1e-3) and imported[0]["watertight"],
          "imported body volume + watertight")
    kinds = [f["kind"] for f in app.call("query.timeline")["features"]]
    check(kinds[-1] == "mesh_body", "mesh_body feature in the timeline")
    app.call("action.undo")

    r2 = app.call("action.import_mesh", {"path": p3, "scale": 2.0})
    bodies = app.call("query.bodies")["bodies"]
    imp2 = [b for b in bodies if b["id"] == r2["features"][0]]
    check(len(imp2) == 1 and near(imp2[0]["volume"], 12000 * 8, 1e-2), "3MF import with scale 2")
    app.call("action.undo")

    psvg = os.path.join(tmp, "sk.svg")
    app.call("action.export_svg", {"path": psvg, "sketch": s1})
    with open(psvg) as f:
        svg = f.read()
    check(svg.count("<line") == 4 and "viewBox" in svg, "SVG export of the sketch")

    for name in ["ImportMeshBtn", "Export3mfBtn", "ExportObjBtn", "ExportSvgBtn", "ExportStlBtn", "ExportDxfBtn"]:
        c = app.call("query.control", {"name": name})
        check(c["visible"] or bool(c.get("flyout_owner")), f"{name} on the shelf")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
