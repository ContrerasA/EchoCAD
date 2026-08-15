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

## §M4 — Line tool, snapping, inference

Status: PENDING sign-off

1. Enter a sketch. **Expect:** toolbar shows Select / Line / Point; Select
   active; status bar shows cursor coordinates in inches as you move.
2. Press L, click, move roughly horizontally. **Expect:** rubber-band line;
   when within ~4° of horizontal it locks flat and a green "H" glyph shows.
3. Click to commit, continue near-vertical, click. **Expect:** "V" glyph and
   lock; chain continues from each committed point.
4. Hover an existing endpoint. **Expect:** green square marker; clicking
   there ends the segment exactly on that point (creates a Coincident
   constraint — verify via `query.constraints` or later the badge UI).
5. Press Esc. **Expect:** chain ends; further clicks start a new chain.
   Esc after only one click leaves no debris (no lone point).
6. Ctrl+Z repeatedly. **Expect:** one segment removed per undo.
7. Toggle grid snap off (RPC action.set_pref for now), draw. **Expect:**
   free placement; with it on, endpoints stick to grid intersections.
8. Point tool (P): click places a point marker (cross preview, square dot).
9. Select tool (V): click a line — it highlights yellow with its endpoints;
   drag an endpoint — geometry follows, one undo step per drag; Esc clears
   the selection.
10. Draw a rough rectangle of 4 chained segments closing on the start
    point. **Expect:** closing click snaps to the start point and ends the
    chain automatically.

Fix log:
- Removed window stretch (canvas_items) — precise automation clicks and UI
  now share one pixel space; desktop CAD UI should not scale anyway.
