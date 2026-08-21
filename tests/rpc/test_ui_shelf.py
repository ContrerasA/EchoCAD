#!/usr/bin/env python3
"""M26 RPC test: tool shelf + theme. Shelf buttons stay reachable by name and
clickable through real input after the grouped restructure; the theme pref
round-trips through action.set_pref; the preferences dialog opens."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad, RpcError

PORT = int(os.environ.get("ECHOCAD_PORT", "4777"))
FAILURES = []


def check(cond, label):
    print(("ok  " if cond else "FAIL") + "  " + label)
    if not cond:
        FAILURES.append(label)


def main():
    app = EchoCad(port=PORT).wait_ready()
    app.call("app.window", {"size": [1280, 800]})

    # Model-mode shelf: the grouped buttons are visible and named.
    for name in ["CreateSketchBtn", "ExtrudeBtn", "RevolveBtn",
                 "OffsetPlaneBtn", "ParametersBtn",
                 "ImportDxfBtn", "ExportDxfBtn", "ExportStlBtn",
                 "PreferencesBtn"]:
        r = app.call("query.control", {"name": name})
        # Export STL / DXF sit in stacks since M44 (3MF▸STL▸OBJ, DXF▸SVG):
        # reachable through the flyout when not the stack's face.
        check(r["visible"] or bool(r.get("flyout_owner")), f"{name} visible in model mode")
    # Save / Open moved to the File menu (QA §M36): named controls survive,
    # but no File group sits in the ribbon.
    for name in ["SaveBtn", "OpenBtn"]:
        r = app.call("query.control", {"name": name})
        check(not r["visible"], f"{name} not in the ribbon")
    r = app.call("query.control", {"name": "FinishSketchBtn"})
    check(not r["visible"], "FinishSketchBtn hidden in model mode")

    # Sketch mode through real clicks: shelf button -> plane pick.
    app.click_control("CreateSketchBtn")
    check(app.call("query.mode")["picking_plane"], "plane pick armed")
    app.call("action.enter_sketch", {"plane": "XY"})  # settle deterministically
    check(app.call("query.mode")["mode"] == "sketch", "sketch mode entered")

    # Tool buttons live in grouped shelves but still drive the ToolManager.
    app.click_control("LineToolBtn")
    check(app.call("query.active_tool")["tool"] == "line",
          "LineToolBtn activates the line tool")
    app.click_control("TrimToolBtn")
    check(app.call("query.active_tool")["tool"] == "trim",
          "TrimToolBtn activates the trim tool")
    r = app.call("query.control", {"name": "CoincidentConBtn"})
    check(r["visible"], "constraint shelf visible in sketch mode")
    r = app.call("query.control", {"name": "CreateSketchBtn"})
    check(not r["visible"], "Solids group hidden in sketch mode")
    app.call("action.finish_sketch")

    # Theme pref round-trips and touches the running app.
    r = app.call("action.set_pref", {"dark_theme": False})
    check(r["dark_theme"] is False, "set_pref switches to light theme")
    r = app.call("action.set_pref", {"dark_theme": True})
    check(r["dark_theme"] is True, "set_pref restores dark theme")

    # Preferences dialog opens with the theme picker in it.
    app.click_control("PreferencesBtn")
    r = app.call("query.control", {"name": "ThemePick"})
    check(r["visible"], "preferences dialog shows the theme picker")

    app.close()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("TEST_UI_SHELF OK")


if __name__ == "__main__":
    main()
