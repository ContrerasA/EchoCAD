#!/usr/bin/env python3
"""M31 RPC test: SVG import through the automation API + extrude of the
welded outline."""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, RpcError, near

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="60mm" height="40mm"
     viewBox="0 0 60 40">
  <rect x="5" y="5" width="30" height="20"/>
  <circle cx="48" cy="15" r="8"/>
  <path d="M 5 32 C 15 26 25 38 35 32"/>
</svg>"""


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    path = os.path.join(tempfile.gettempdir(), "echocad_m31.svg")
    with open(path, "w") as f:
        f.write(SVG)

    r = app.call("action.import_svg", {"path": path, "plane": "XY"})
    fid = r["feature"]
    check(r["lines"] == 4 and r["circles"] == 1 and r["splines"] == 1,
          f"census ({r})")

    ents = app.entities(sketch=fid)
    circles = [e for e in ents if e["kind"] == "circle"]
    check(near(circles[0]["radius"], 8.0, 1e-6), "circle radius in mm")

    profs = app.call("query.profiles", {"sketch": fid})["profiles"]
    areas = sorted(abs(p["area"]) for p in profs)
    check(any(near(a, 600.0, 1.0) for a in areas), f"rect welded (areas {areas})")
    check(any(near(a, 3.1415926 * 64, 2.0) for a in areas), "circle profile")

    r2 = app.call("action.extrude", {"sketch": fid, "at": [20, 25],
                                     "distance": 5.0})
    check(near(r2["volume"], 600 * 5.0, 20.0),
          f"imported rect extrudes (vol {r2['volume']:.0f})")

    # Width override doubles everything.
    r3 = app.call("action.import_svg",
                  {"path": path, "plane": "XY", "width": 120.0})
    ents3 = app.entities(sketch=r3["feature"])
    c3 = [e for e in ents3 if e["kind"] == "circle"][0]
    check(near(c3["radius"], 16.0, 1e-6), "width override scales")

    try:
        app.call("action.import_svg", {"path": "/no/such.svg"})
        check(False, "missing file refused")
    except RpcError:
        check(True, "missing file refused")

    r4 = app.call("query.control", {"name": "ImportSvgBtn"})
    check(r4["visible"], "Import SVG button on the shelf")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_SVG_IMPORT OK")


if __name__ == "__main__":
    main()
