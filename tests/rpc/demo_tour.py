#!/usr/bin/env python3
"""Watchable demo: drives the app like a human. Launch the app yourself:

    godot --path . -- --automation-port=4777

then run:  python3 tests/rpc/demo_tour.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from client import EchoCad

app = EchoCad(port=int(os.environ.get("ECHOCAD_PORT", "4777"))).wait_ready()
app.call("app.window", {"size": [1280, 800]})

print("orbiting...")
app.call("input.drag", {"from": [640, 400], "to": [820, 480],
                        "button": "middle", "modifiers": ["shift"], "steps": 40})
time.sleep(0.5)
print("zooming...")
app.call("input.scroll", {"amount": 3})
time.sleep(0.5)

print("creating sketch on a plane (button + click)...")
app.click_control("CreateSketchBtn")
time.sleep(0.3)
win = app.call("app.window")["size"]
app.call("input.click", {"at": [win[0] / 2, win[1] / 2], "steps": 30})
time.sleep(0.8)

print("panning around the sketch...")
app.call("input.drag", {"from": [600, 400], "to": [800, 300],
                        "button": "middle", "steps": 40})
time.sleep(0.5)
app.call("input.scroll", {"amount": 4})
time.sleep(0.5)

print("finishing sketch...")
app.click_control("FinishSketchBtn")
time.sleep(0.5)
print("done. timeline:", app.call("query.timeline"))
