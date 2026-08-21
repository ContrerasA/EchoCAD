#!/usr/bin/env python3
"""M24 RPC test: action.export_stl — binary layout + volume, ascii variant,
per-body filter, error on empty document."""

import os
import struct
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


def parse_binary(path):
    with open(path, "rb") as f:
        header = f.read(80)
        (count,) = struct.unpack("<I", f.read(4))
        vol = 0.0
        for _ in range(count):
            vals = struct.unpack("<12fH", f.read(50))
            n = vals[0:3]
            a, b, c = vals[3:6], vals[6:9], vals[9:12]
            cx = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                  a[0] * b[1] - a[1] * b[0])
            vol += (cx[0] * c[0] + cx[1] * c[1] + cx[2] * c[2]) / 6.0
        trailing = f.read()
    return {"header": header, "count": count, "volume": abs(vol),
            "trailing": trailing}


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})
    tmp = tempfile.mkdtemp(prefix="echocad_stl_")

    # Empty document refuses.
    try:
        app.call("action.export_stl", {"path": os.path.join(tmp, "empty.stl")})
        check(False, "empty document refused")
    except RpcError:
        check(True, "empty document refused")

    # Box body.
    app.call("action.enter_sketch", {"plane": "XY"})
    s1 = app.call("query.mode")["active_sketch"]
    app.call("action.set_view", {"pan": [0, 0], "zoom": 4.0})
    app.call("action.set_pref", {"grid_snap": False})
    app.click_control("RectToolBtn")
    app.click_world([0, 0], steps=5)
    app.click_world([40, 30], steps=5)
    app.call("action.finish_sketch")
    e1 = app.call("action.extrude",
                  {"sketch": s1, "at": [20, 15], "distance": 10})["feature"]

    p_bin = os.path.join(tmp, "box.stl")
    r = app.call("action.export_stl", {"path": p_bin})
    parsed = parse_binary(p_bin)
    check(parsed["count"] == r["triangles"] and not parsed["trailing"],
          f"binary layout ({parsed['count']} facets, no trailing bytes)")
    check(not parsed["header"].startswith(b"solid"),
          "binary header does not start with 'solid'")
    check(near(parsed["volume"], 12000.0, 1.0),
          f"volume 12000 (got {parsed['volume']:.1f})")

    # ASCII variant.
    p_asc = os.path.join(tmp, "box_ascii.stl")
    app.call("action.export_stl", {"path": p_asc, "ascii": True})
    with open(p_asc, "r", encoding="ascii") as f:
        text = f.read()
    check(text.startswith("solid") and "endsolid" in text
          and text.count("facet normal") == parsed["count"],
          "ascii variant parses with the same facet count")

    # Per-body filter.
    app.call("action.enter_sketch", {"plane": "XY"})
    s2 = app.call("query.mode")["active_sketch"]
    # Frame where this rect goes: entering a sketch now opens on the model
    # (or the face) rather than on a kilometre-wide default view, so a rect
    # drawn 100 mm away from the first box needs the view moved there first
    # -- exactly what the first sketch above does.
    app.call("action.set_view", {"pan": [105, 5], "zoom": 4.0})
    app.click_control("RectToolBtn")
    app.click_world([100, 0], steps=5)
    app.click_world([110, 10], steps=5)
    app.call("action.finish_sketch")
    e2 = app.call("action.extrude",
                  {"sketch": s2, "at": [105, 5], "distance": 5})["feature"]
    p_one = os.path.join(tmp, "one.stl")
    r2 = app.call("action.export_stl", {"path": p_one, "body": e2})
    check(r2["bodies"] == 1
          and near(parse_binary(p_one)["volume"], 500.0, 1.0),
          "per-body filter exports only the named body")

    app.call("app.quit")
    print(f"\n{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failures")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
