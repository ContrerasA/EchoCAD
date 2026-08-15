# EchoCAD — Manual QA Checklist

Cumulative, hand-driven, windowed. One section per milestone; each section is
signed off before its branch merges. Steps are numbered with an expected
result; log fixes under the section as they happen.

Run: `godot --path .` (see CLAUDE.md for the binary path).

---

## §M2 — 3D shell + sketch mode

Status: PENDING sign-off

1. Launch the app. **Expect:** window opens; 3D view with red/green/blue
   origin axes and three faint origin planes; view cube top-right; status bar
   reads "Model".
2. Drag with middle mouse button. **Expect:** view pans; the view cube does
   not move (it only rotates).
3. Hold Shift + drag middle mouse. **Expect:** orbit around the origin; view
   cube rotates in lockstep.
4. Scroll wheel up/down. **Expect:** zoom in/out toward the model.
5. Click a face of the view cube (e.g. the one facing you). **Expect:**
   camera animates (~0.25 s) to that axis-aligned view.
6. Click "Create Sketch". **Expect:** status hint reads "Select a plane
   (Esc to cancel)"; hovering a plane highlights it brighter.
7. Press Esc. **Expect:** picking cancels, hint clears, no sketch created.
8. Click "Create Sketch", then click the XZ plane. **Expect:** camera
   animates to look straight at the plane; view switches to the 2D sketch
   canvas: dark background, adaptive grid, red horizontal + green vertical
   axis lines through the origin; status reads "Sketch" and "Sketch1 on XZ";
   "Finish Sketch" button replaces "Create Sketch".
9. Scroll wheel in the sketch view. **Expect:** zoom anchors at the cursor
   (the point under the cursor stays put); grid density adapts — line
   spacing stays readable at every zoom, never a solid wall or a bare void.
10. Middle-drag in the sketch view. **Expect:** pan; axes and grid move
    together, no drift or smearing.
11. Click "Finish Sketch". **Expect:** back to the 3D view; planes visible
    again; status "Model".
12. Ctrl+Z. **Expect:** the (empty) Sketch1 feature is undone. Ctrl+Shift+Z
    restores it.
13. Create a second sketch on XY. **Expect:** it is auto-named "Sketch2".
14. Resize the window in both modes. **Expect:** layout fills the window; no
    stretching artifacts; sketch raster stays crisp after resize.

Fix log:
- (none yet)

## §M3 — Automation API

Status: PENDING sign-off

1. Launch `godot --path . -- --automation-port=4777`, then run
   `python3 tests/rpc/demo_tour.py`. **Expect:** the app visibly orbits,
   zooms, clicks "Create Sketch", clicks a plane, pans around the sketch,
   finishes the sketch — all with smooth, human-looking pointer motion; the
   script prints the timeline at the end.
2. While the app is open with the server on, run
   `python3 tests/rpc/test_shell.py` (ECHOCAD_PORT=4777). **Expect:** all
   checks print `ok`, app quits itself at the end.
3. Launch WITHOUT `--automation-port`. **Expect:** no server, no listening
   port, app behaves normally.

Fix log:
- (none yet)
