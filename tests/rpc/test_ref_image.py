#!/usr/bin/env python3
"""M30 RPC test: canvas import/edit/calibrate through the automation API."""

import os
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, RpcError, near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def write_png(path, w=64, h=32):
    """Minimal solid-color RGB PNG, stdlib only."""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I",
                                                              zlib.crc32(c))
    raw = b"".join(b"\x00" + b"\x50\x90\xc0" * w for _ in range(h))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    path = os.path.join(tempfile.gettempdir(), "echocad_m30.png")
    write_png(path)

    r = app.call("action.import_canvas",
                 {"path": path, "plane": "XY", "width": 128.0})
    fid = r["feature"]
    check(r["name"] == "Canvas1" and r["plane"] == "XY", "canvas imported")
    check(near(r["width_mm"], 128.0, 1e-6) and near(r["height_mm"], 64.0, 1e-6),
          "aspect-derived height")

    r = app.call("action.set_canvas",
                 {"feature": fid, "center": [20, 10], "opacity": 0.4})
    check(near(r["center"][0], 20, 1e-9) and near(r["opacity"], 0.4, 1e-9),
          "placement edit lands")

    # Calibrate: picked 10mm apart, really 50mm -> width x5, center scaled
    # about the first pick.
    r = app.call("action.calibrate_canvas",
                 {"feature": fid, "a": [0, 0], "b": [10, 0], "distance": 50.0})
    check(near(r["width_mm"], 128.0 * 5.0, 1e-6), "calibration scales width")
    check(near(r["center"][0], 100.0, 1e-6) and near(r["center"][1], 50.0, 1e-6),
          "calibration holds the first pick")
    app.call("action.undo")
    r = app.call("query.canvas", {"feature": fid})
    check(near(r["width_mm"], 128.0, 1e-6), "undo reverts the calibration")

    # Bad path refused.
    try:
        app.call("action.import_canvas", {"path": "/no/such/file.png"})
        check(False, "bad path refused")
    except RpcError:
        check(True, "bad path refused")

    # Timeline carries the feature; suppress hides it from live features.
    tl = app.call("query.timeline")
    kinds = [f["kind"] for f in tl["features"]]
    check("canvas" in kinds, "canvas is a timeline feature")
    app.call("action.suppress", {"feature": fid, "suppressed": True})
    app.call("action.suppress", {"feature": fid, "suppressed": False})

    # The shelf button exists for hand use.
    r = app.call("query.control", {"name": "ImportCanvasBtn"})
    check(r["visible"], "Canvas shelf button visible")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_REF_IMAGE OK")


if __name__ == "__main__":
    main()
