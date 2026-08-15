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

## §M5 — Rectangle + circle

Status: PENDING sign-off

1. Rectangle (R): click two corners. **Expect:** live preview; result is 4
   lines with shared corner points; top/bottom horizontal, sides vertical
   (drag a corner later with Select — shape shears only as constraints
   allow once the solver lands).
2. While the second corner rubber-bands, W/H boxes follow the cursor
   showing live sizes in inches; type `2`, Tab, `1`, Enter. **Expect:**
   exact 2in x 1in rectangle; typed field highlights while active.
3. Center Rect: first click is the center (cross marker), second a corner;
   typed W/H are FULL sizes centered on the first click.
4. Circle (C): click center, move (live R readout), type `0.5`, Enter.
   **Expect:** exact 0.5in radius. Or click the rim to size by eye.
5. 3-Pt Circle: click three points; after the second, the preview circle
   passes through both picks and the cursor. Collinear third click is
   refused (no commit).
6. Esc mid-shape cancels with no debris; one undo step per finished shape.
7. Unit suffixes work in fields: `10mm`, `1.5in`.

Fix log:
- (none yet)

## §M6 — Arcs + constraint solver

Status: PENDING sign-off

1. 3-Pt Arc (A): click start, end, then a bulge point — preview follows the
   third pick, arc lands through all three. Winding matches the bulge side.
2. Center Arc: click center, click start (radius locks), sweep the cursor —
   the preview follows the direction you wind, past 180° if you keep going;
   third click commits.
3. Tangent Arc: first click must land on a line ENDPOINT (green square when
   snapped); the preview arc always leaves tangent to the line; second
   click commits. Result carries Tangent + Coincident constraints.
4. Select tool: drag the free end of a line that has a tangent arc — the
   arc's start follows (coincident) and tangency re-solves live during the
   drag. Ctrl+Z once reverts the entire drag (drag + re-solve = one step).
5. Drag an arc endpoint: the opposite endpoint keeps the same radius (arc
   implicit coupling), no kinks or explosions.
6. Over-constrain something (e.g. two different distances between the same
   points via RPC): geometry stays bounded, no vibrating explosion.
7. `query.dof` over RPC reports sensible numbers ("N DOF remaining" /
   "Fully constrained") and lists conflicts when you create one.

Fix log:
- Snap-index rebuilds triggered mid-drag by command pushes were clobbering
  the gesture's self-exclusion, so a dragged point could snap back to its
  own origin and collapse the undo batch. Exclusions now persist until the
  gesture ends.

## §M7 — Constraint palette + DOF UI

Status: PENDING sign-off

1. In a sketch, the constraint bar shows Coincident/H/V/Parallel/
   Perpendicular/Collinear/Equal/Midpoint/Concentric/Tangent/PointOn/Fix/
   Symmetry. With nothing (or the wrong things) selected, clicking one
   prints a reason in the status bar ("Cannot apply: needs two lines").
2. Ctrl-click two lines, click Parallel. **Expect:** lines rotate to
   parallel; a ∥ badge appears near each... (badge sits by the operands'
   midpoint); one Ctrl+Z undoes constraint + motion together.
3. Constraint badges: green = satisfied, amber = redundant, red =
   conflicting. Click a badge to select it (yellow outline); Delete removes
   it; Esc deselects.
4. Status bar shows "N DOF remaining"; it drops as you constrain. Fully
   constrain a line (Fix an endpoint + Horizontal + a Distance via RPC for
   now): the line and its points render GREEN and status reads "Fully
   constrained".
5. Create a conflict (two different distances on the same pair): badges go
   red, status reads "Conflicting constraints"; geometry stays calm (no
   vibration). Deleting one distance clears it.
6. Delete key with entities selected deletes them plus their constraints in
   one undo step; constraints referencing them vanish.

Fix log:
- Conflict detection now flags every violated constraint once redundancy
  exists — the iterative solver satisfies whichever duplicate ran last, so
  the violated one is often NOT the redundant one.

## §M8 — Dimensions + parameters

Status: PENDING sign-off

1. Smart Dimension (D): click a line — a live dimension follows the cursor
   showing its length; click empty space to park it. Extension lines,
   dimension line with arrowheads, value chip at the parked spot.
2. After parking, type `2` Enter — the line drives to exactly 2 in and the
   whole flow is ONE Ctrl+Z.
3. Pick two points → distance; a circle → ⌀ diameter with leader; an arc →
   R radius; two angled lines → angle arc with degrees; two parallel lines
   → gap. Wrong combos just restart the pick.
4. Select tool: drag a dimension label — it parks where you drop it (world-
   anchored: pans/zooms with the sketch); geometry never moves.
5. Click a label to select it (yellow), type a new value, Enter — drives.
   `10mm` and `0.5in` suffixes work. Delete removes the dimension.
6. Expressions: type `width / 2` into a dimension after creating parameter
   `width` (RPC action.set_parameter for now) — label shows the formula;
   changing the parameter re-drives every dependent dimension and re-solves
   in one undo step. Typos ("wdith") are refused with a message, nothing
   changes.
7. Driven dimensions render in parentheses/grey and never move geometry.

Fix log:
- SketchConstraint.make now copies its operand array — the smart dimension
  tool cleared a shared array on reset and gutted the stored constraint.
