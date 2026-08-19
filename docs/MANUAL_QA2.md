# EchoCAD — Manual QA Checklist, volume 2 (M22+)

Continuation of `docs/MANUAL_QA.md`, which holds §M2–§M21 and was closed at
the end of the M21 QA pass (it had grown past 100 KB). Same rules, restated:

Cumulative, hand-driven, windowed. One section per milestone; each section is
signed off before its branch merges. Steps are numbered with an expected
result; log fixes under the section as they happen.

Run: `godot --path .` (see CLAUDE.md for the binary path).

## Checkbox legend

- `[ ]` — not yet verified.
- `[x]` — verified working by hand.
- `[!]` — verified BROKEN. An `Issue:` line follows saying what is wrong; the
  matching entry in the section's fix log says what was done about it.
- `[~]` — works, but a follow-up is deferred to a later milestone. The
  `Deferred:` line names the milestone.

A section may only be signed off when it has no `[ ]` and no `[!]` boxes left.

---

## §M22 — Construction planes + sketch on faces

Status: PENDING sign-off

- [X] 1. Model mode: press **Offset Plane**, hover the origin planes — they
   glow like in sketch-plane picking; click XY. **Expect:** a small dialog
   asks for the offset; type `1in`, OK. A tan/amber quad appears floating
   25.4 mm above the ground plane, centred over the origin. The timeline
   gains a "Plane1" chip; the browser gains a "Construction" folder with a
   Plane1 row (eye ticked).
- [X] 2. **Create Sketch**, click the floating tan plane. **Expect:** the
   camera flies square onto it; the grid sits ON the elevated plane (not at
   the ground); the status bar reads "Sketch2 on Plane1" (name may vary).
   Draw a rectangle, Finish Sketch. The sketch's lines render at the
   plane's height in 3D.
- [X] 3. Extrude the elevated rectangle 0.5in. **Expect:** the solid FLOATS —
   its bottom face at the plane height, not on the ground.
- [X] 4. Double-click the Plane1 chip (or its browser row). **Expect:** the
   offset dialog reopens showing `1.000 in`. Change it to `2in`. The plane
   quad, the sketch on it, and the extruded solid all move up together.
   Ctrl+Z brings all three back down in ONE step.
- [X] 5. Offset Plane again; this time click Plane1 itself as the base, type
   `0.5in`. **Expect:** a second plane appears 0.5in above Plane1 (chained).
- [X] 6. **Create Sketch**, then hover the TOP FACE of the floating solid.
   **Expect:** the face highlights amber. Click it: a sketch opens ON the
   face (grid at face height); the timeline shows a new Plane + Sketch pair.
   Draw a circle on it, Finish; extrude the circle 0.25in — it stacks on the
   solid. Ctrl+Z on the sketch-on-face step removes the plane AND the empty
   sketch together (one undo step).
- [X] 7. Browser: untick the eye on Plane1. **Expect:** its quad disappears
   in model mode; while picking a sketch plane it re-appears (mode gate),
   like the origin planes. Re-tick: it stays visible in plain model mode.
- [X] 8. Right-click the Plane1 chip → Delete. **Expect:** REFUSED with a
   status message (a sketch still uses it). Delete the chained plane from
   item 5 (nothing uses it) — it goes away.
  Right clicking planes in outliner does not show a right click menu
- [X] 9. Timeline: drag the rollback marker before Plane1. **Expect:** the
   plane quad, the elevated sketch and the solid all vanish; drag it back —
   everything returns.
- [X] 10. Save the document, reopen it. **Expect:** planes, sketches on
   them, and the floating solid all come back exactly; Plane1's offset
   still edits parametrically.
- [X] 11. In the elevated sketch, Shift+MMB orbits off-axis; the in-edit
   geometry renders at the plane's height; clicking the plane's view-cube
   face flies back square; drawing continues to land on the elevated plane
   while off-axis.

### §M22 fix log

- Item 8 (2026-08-18): construction-plane rows in the browser had no context
  menu at all — only the timeline chip did. Added a right-click menu to
  `cplane` rows (`Edit Offset...` / `Delete`); Delete routes through
  `app.request_delete_feature`, so the reference guard still refuses while a
  sketch or a chained plane uses it. Covered by `tests/m25_qa_fixes.gd` (D).
  Round 2 (2026-08-18): still filed `[!]` after the fix round — the real
  right-click popup path (row select + `_on_item_mouse_selected`) is now
  exercised end-to-end by `tests/m25_qa_fixes.gd` (E) and opens the menu on
  the right target. If the windowed re-test still shows nothing, make sure
  the run is from this working tree (the fix is uncommitted code, not a
  setting).

---

## §M23 — Revolve

Status: PENDING sign-off

- [X] 1. Sketch on XY: a rectangle from about (20,0) to (30,10) — off to the
   right of the origin. Finish. Press **Revolve**, hover the rectangle —
   the region highlights amber like Extrude's pick; click it. **Expect:**
   the status bar now asks for the axis: "click a sketch line, or press
   X / Y for the sketch axes".
     Unable to select gizmo axis for axis to revolve around. Only able to specify with keyboard
- [X] 2. Press **Y**. **Expect:** the Revolve dialog opens (angle box,
   operation dropdown). Leave the angle empty (=360), OK. A RING (donut
   with a square cross-section) appears around the vertical axis; the
   timeline gains a "Revolve1" chip; the browser lists the body.
- [X] 3. Orbit the ring. **Expect:** shaded like extruded solids, with edge
   lines on the four sharp circles; no seams on the smooth walls; no
   see-through faces.
- [X] 4. Undo. Revolve the same rectangle again, angle **90**. **Expect:** a
   quarter of the ring with two flat end caps; the caps carry outline edges.
- [X] 5. Draw a sketch with a rectangle straddling the vertical axis (e.g.
   (-5,20) to (5,30)) and try to revolve it about Y. **Expect:** refused
   with a status message about the region straddling the axis; no feature
   is added.
- [X] 6. In a sketch, draw a rectangle plus a separate vertical CONSTRUCTION
   line (X toggle) to its left. Revolve the rectangle and CLICK THE LINE as
   the axis. **Expect:** the ring forms around the line, not the sketch
   axis.
    When selecting axis, it doesn't highlight / grow in width when hovered
- [X] 7. Booleans: extrude a plate, then sketch a small rectangle over it
   and revolve it 360° about a line through the plate with operation
   **Cut**. **Expect:** a round groove/trough carved out of the plate;
   undo restores the plate in one step.
- [X] 8. Edit the ring's source sketch (drag the rectangle a little),
   finish. **Expect:** the revolve replays — the ring follows the profile.
- [X] 9. Save and reopen. **Expect:** revolves rebuild identically; the
   timeline order and names survive.
- [X] 10. Suppress the Revolve chip. **Expect:** the ring disappears;
   unsuppress brings it back.

### §M23 fix log

- Item 1 (2026-08-18): the axis pick only accepted the X/Y keys or a click on
  a line entity — there was nothing drawn to click for the sketch axes.
  While the pick is armed the world now draws the sketch's own u/v axes
  through its origin (red = X, green = Y, on the sketch's plane, on top of
  fills/bodies) and `_axis_pick_under_ray` resolves a click near either of
  them to `x`/`y`, exactly like the keys. Line entities win ties.
- Item 6 (2026-08-18): no hover feedback on axis candidates. Mouse motion
  during the axis pick now highlights the candidate under the cursor (line
  entity or drawn axis) as a thick amber band (~4 px at the current zoom).
- "Additional" error spam (2026-08-18): clicking a body row made
  `BrowserTree._on_item_selected` call `app.select_body`, which refreshes
  (clears + rebuilds) the tree from inside the Tree's own mouse-selection
  callback — Godot forbids that (`tree.cpp:5780/5614`), leaving the refresh
  half-done and `set_text` on null. `select_body` is now `call_deferred`
  from the tree callback, so the refresh runs after the mouse event.
- "Issues" — cut revolve listed as a body (2026-08-18): the browser listed
  every live `SolidFeature` as a body row, so a Cut/Join feature got a
  phantom row whose eye toggled nothing. It now lists the BUILT bodies from
  `CadWorld.bodies()` (one row per NEW_BODY root; join/cut features fold
  into the body they touch, and a body fully consumed by cuts drops out).
  Boolean bakes land a frame late, so the world emits `bodies_rebuilt` and
  the browser re-lists on it. Covered by `tests/m25_qa_fixes.gd` (A–C).

### Additional
Some errors did occur sometime during editing
󰣇  [tones] nixos:~/godot/echo-cad/  main   godot --path ./
Godot Engine v4.7.1.stable.official.a13da4feb - https://godotengine.org
OpenGL API 3.3.0 NVIDIA 595.71.05 - Compatibility - Using Device: NVIDIA - NVIDIA GeForce RTX 4080

[godot-geometry] extension initialized; GeometryOps registered.
[godot-thorvg] extension initialized; TVGCanvas registered.
ERROR: The tree cannot be cleared during mouse selection events.
   at: clear (scene/gui/tree.cpp:5780)
   GDScript backtrace (most recent call first):
       [0] refresh (res://src/app/browser_tree.gd:53)
       [1] select_body (res://src/app/app_root.gd:246)
       [2] _on_item_selected (res://src/app/browser_tree.gd:173)
ERROR: The tree cannot create items during mouse selection events.
   at: create_item (scene/gui/tree.cpp:5614)
   GDScript backtrace (most recent call first):
       [0] refresh (res://src/app/browser_tree.gd:55)
       [1] select_body (res://src/app/app_root.gd:246)
       [2] _on_item_selected (res://src/app/browser_tree.gd:173)
ERROR: The tree cannot create items during mouse selection events.
   at: create_item (scene/gui/tree.cpp:5614)
   GDScript backtrace (most recent call first):
       [0] refresh (res://src/app/browser_tree.gd:57)
       [1] select_body (res://src/app/app_root.gd:246)
       [2] _on_item_selected (res://src/app/browser_tree.gd:173)
SCRIPT ERROR: Cannot call method 'set_text' on a null value.
          at: BrowserTree.refresh (res://src/app/browser_tree.gd:58)
          GDScript backtrace (most recent call first):
              [0] refresh (res://src/app/browser_tree.gd:58)
              [1] select_body (res://src/app/app_root.gd:246)
              [2] _on_item_selected (res://src/app/browser_tree.gd:173)
### Issues
Revolving a cut operation creates a Revolve body in outliner, and ticking it on / off does nothing. it should instead be integrated into the body that it cut into.

---

## §M24 — STL export

Status: PENDING sign-off

- [X] 1. Empty document: press **Export STL**. **Expect:** no dialog; the
   status bar says there are no solid bodies to export.
- [X] 2. Extrude a box (with a hole in it for interest). Export STL.
   **Expect:** file dialog defaults to .stl with an "ASCII STL" checkbox
   (unticked); saving reports the triangle count in the status bar.
- [!] 3. Open the exported file in an external viewer/slicer (PrusaSlicer,
   Cura, Windows 3D Viewer...). **Expect:** the part loads at the right
   SIZE in mm (a 40 x 30 x 10 sketch box measures 40 x 30 x 10 mm), is
   watertight (no slicer repair warnings), and shows no inverted faces.
    Model did export but wrong scale. In EchoCAD it is 3.5inx3.5in. When imported into blender, it is 88.9m x 88.9m
- [X] 4. A boolean body (box with a revolved groove cut, from §M23.7):
   export and open externally. **Expect:** the carved shape survives the
   round trip; still manifold.
- [X] 5. Two bodies: right-click a body row in the browser → "Export
   STL...". **Expect:** only that body lands in the file.
    No right click option available
- [X] 6. Hide one body (browser eye), Export STL from the toolbar.
   **Expect:** only the visible body exports.
- [X] 7. Tick "ASCII STL" and export. **Expect:** the file opens in a text
   editor as `solid echocad` / `facet normal ...`; a viewer still loads it.

### §M24 fix log

- Item 3 (2026-08-18): NOT a bug — the file is correct. STL is a unitless
  format; the de-facto convention (every slicer) is 1 unit = 1 mm, and
  EchoCAD writes canonical mm (3.5 in = 88.9 mm, so 88.9 units). Blender is
  the odd one out: its scene maps 1 unit = 1 m, so an mm-convention STL
  reads as "88.9 m". Fix on the Blender side: import with Scale = 0.001, or
  set the scene's unit scale to millimetres. PrusaSlicer/Cura/3D Viewer show
  the part at 88.9 mm as expected.
  Round 2 (2026-08-18): still `[!]`, so the export dialog now carries a
  "Units" dropdown — "millimetres (slicers)" (default, unchanged files) and
  "metres (Blender)", which scales coordinates by 0.001 so Blender's
  1-unit-=-1-m import lands at true size. The binary header and the status
  bar name the unit written. Covered by `tests/m25_qa_fixes.gd` (G).
- Item 5 (2026-08-18): the per-body "Export STL..." context menu existed,
  but right-clicking a body row first fired the selection handler, whose
  mid-event tree refresh (see §M23 fix log) corrupted the tree before the
  menu could open. Fixed by the same deferred `select_body`; the menu now
  pops.

---

## §M25 — DXF import

Status: PENDING sign-off

- [X] 1. Export a sketch (rect + circle + a construction line) to DXF, then
   press **Import DXF** and pick that file. **Expect:** a NEW sketch
   appears in the timeline/browser with the same geometry in the same
   place; the construction line comes back violet-dashed; the status bar
   reports the entity census.
    Imported sketch appears in xy plane, though i originally drew it in xz plane
    Still not working. look at M25.ecad and M25.dxf. in ecad the sketch is on xz plane. when i import dxf into the ecad file, it's on xy plane. instead of encoding it in the file, maybe we can just choose what plane to place it on
- [X] 2. Hover the imported rectangle in Extrude picking. **Expect:** the
   region highlights (endpoints welded into a closed profile); extruding it
   works.
- [X] 3. Ctrl+Z after an import. **Expect:** the entire imported sketch
   disappears in ONE step.
- [~] 4. Import a DXF exported from another CAD (Fusion, LibreCAD,
   QCAD...): a 2D drawing with lines, arcs, circles, and a polyline.
   **Expect:** geometry lands correctly (polylines become lines+arcs);
   unsupported entities (text, dimensions, splines) are skipped and the
   status bar says how many.
- [~] 5. Import a file drawn in INCHES ($INSUNITS=1). **Expect:** the
   geometry lands at the right physical size (1in line measures 25.4 mm /
   1.000 in with Smart Dimension).
- [X] 6. Open the imported sketch and edit: drag points, add constraints,
   dimension it. **Expect:** imported geometry behaves like drawn geometry
   (snap, solver, DOF all work).
- [~] 7. Pick a garbage file (a .txt renamed .dxf). **Expect:** refused with
   a status message; the document is untouched.

### §M25 fix log

- Item 1 (2026-08-18): the interactive import always landed on XY (DXF is a
  2D format — it does not carry the source plane). The import file dialog
  now has a "Sketch plane" dropdown listing the origin planes and every live
  construction plane (default XY, remembered between imports), feeding the
  plane parameter `import_dxf` already had.
  Round 2 (2026-08-18): "still not working" note — the dropdown IS the
  requested "choose what plane to place it on" (DXF cannot carry the source
  plane; nothing is encoded in the file). The dialog path is now verified
  end-to-end by `tests/m25_qa_fixes.gd` (F): picking XZ in the dropdown and
  importing `tests/M25.dxf` lands the sketch on XZ. Re-test from this
  working tree; pick XZ in the "Sketch plane" dropdown inside the import
  file dialog before choosing the file.


## §M26 — Tool shelf, icons, themes

Status: PENDING sign-off

- [ ] 1. Launch the app. **Expect:** the top bar is grouped into captioned
   shelf groups (Solids / Construct / Inspect / History / File /
   Interchange / View); every button has an icon; hovering shows a tooltip
   (shortcuts included, e.g. "Undo (Ctrl+Z)").
- [ ] 2. Enter a sketch. **Expect:** the Solids/Construct groups vanish, a
   "Sketch" group with Finish Sketch appears, and two shelf rows show:
   icon-only tool strip (Select / Create / Modify / Dimension / Options
   groups) and an icon-only Constraints strip. Tooltips name every tool
   with its shortcut; clicking activates it (button stays pressed).
- [ ] 3. Resize the window narrow (~900px). **Expect:** whole groups wrap
   to the next row; no button is pushed off-screen or clipped.
- [ ] 4. Preferences → Theme → Light. **Expect:** the ENTIRE app recolors:
   buttons/panels/labels/status bar light, the 3D viewport background goes
   light with darker grid lines, the sketch canvas matches. Sketch line
   colors (blue/green/violet) stay legible.
- [ ] 5. In light theme, open a sketch, draw, dimension, orbit off-axis.
   **Expect:** everything legible: grid, badges, dimension labels,
   selection highlight.
- [ ] 6. Quit and relaunch. **Expect:** the light theme is remembered.
   Switch back to Dark; relaunch; dark comes back.
- [ ] 7. Icon check: hover every tool + constraint button once. **Expect:**
   each icon plausibly depicts its command (no blanks, no mismatches);
   both themes tint icons legibly.

## §M27 — Viewing: projection, look-at, units, measure

Status: PENDING sign-off

- [ ] 1. Model mode with a body: press **P** (or the Ortho shelf toggle).
   **Expect:** projection flips to orthographic with no size jump; parallel
   edges render parallel. P again returns to perspective, again no jump.
- [ ] 2. Enter a sketch with Ortho ON, finish it. **Expect:** sketch mode
   unaffected (always ortho); finishing returns to the ORTHO model view.
   Relaunch the app: the projection choice is remembered.
- [ ] 3. **Look At** → click the XZ plane, then again → click a flat body
   face. **Expect:** hover highlights planes/faces; the camera animates to
   face it square-on. Esc cancels the pick.
- [ ] 4. Orbit away, zoom far out, press **F** (or Fit). **Expect:** the
   model fills the view, centered, in both projections.
- [ ] 5. Views dropdown → **Save View**; orbit elsewhere; pick the saved
   view. **Expect:** the exact camera returns (angle, distance, and its
   projection). Save the file, reopen it: the view survives.
- [ ] 6. Preferences → Units → Millimeters. **Expect:** dimension labels,
   grid step readout, type-in defaults, and the Parameters dialog all speak
   mm; the model itself does not move. Switch to Feet and back.
- [ ] 7. In a sketch select: one line; a circle; two points; two parallel
   edges; two angled lines; a point + a line. **Expect:** the status bar
   shows Length/∠, R/⌀, Dist ΔX ΔY, parallel Dist, ∠, and Dist
   respectively, in the display unit.
- [ ] 8. Browser → right-click a body → **Properties…**. **Expect:** a
   popup with volume and bounding size in the display unit (³ for volume).

## §M28 — Sketch splines

Status: PENDING sign-off

- [ ] 1. Spline tool (B): click 4–5 points, Enter. **Expect:** a smooth
   curve through every clicked point; ghost preview follows the cursor
   while drawing; ONE Ctrl+Z removes the whole curve.
- [ ] 2. Draw a spline ending double-click. **Expect:** double-click
   finishes it (no extra point from the second click).
- [ ] 3. Draw 4+ points, then click the FIRST point. **Expect:** the curve
   closes smoothly (no corner at the joint); the closed region shows the
   blue profile fill; Extrude accepts it.
- [ ] 4. Select the spline. **Expect:** amber tangent handles at each fit
   point. Drag one: the curve reshapes live, both sides of the handle stay
   mirrored (no kink); the drag is ONE undo step.
- [ ] 5. Drag a fit point with Select. **Expect:** the curve follows
   smoothly. Add a dimension/constraint to a fit point: it behaves like
   any sketch point (solver, DOF, badges).
- [ ] 6. Construction toggle on, draw a spline. **Expect:** violet dashed
   construction curve; no profile from it.
- [ ] 7. Trim/Extend/Offset on a spline. **Expect:** no crash — trim and
   extend find no cuts; Offset refuses with a status hint (documented
   limitation).
- [ ] 8. Mirror a spline (with an override dragged in). **Expect:** the
   mirrored copy is the true reflection, including the reshaped bend.
- [ ] 9. Export DXF with a spline; re-import. **Expect:** the curve comes
   back as a welded polyline in the right place (tessellation, documented).
- [ ] 10. Save/reopen the document. **Expect:** the spline, its overrides,
   and closure survive exactly.

## §M29 — Sketch patterns, chamfer, polygon

Status: PENDING sign-off

- [ ] 1. Draw a rect, select it (marquee), pick **Rect Pattern**. Move the
   cursor: a ghost grid follows. Type N/M (Tab cycles) and DX/DY with unit
   suffixes; click. **Expect:** the grid of copies lands; ONE Ctrl+Z
   removes all of it.
- [ ] 2. Drag a point on a pattern copy. **Expect:** the copy keeps its
   shape (its H/V/equal constraints came along) but may move/scale as a
   whole — Fusion-lite freedom, dimensions are not replicated.
- [ ] 3. Select a circle + slot, pick **Circ Pattern**, type N=6, click a
   center. **Expect:** 5 ghost copies preview around the center before the
   click; committed copies are evenly spaced; arcs/slots keep their shape.
- [ ] 4. Circ Pattern with A=180, N=3. **Expect:** copies at 90° and 180°
   exactly.
- [ ] 5. **Chamfer**: hover a rect corner (highlights), type a distance,
   click. **Expect:** a straight cut with equal legs; the two edges rewire
   to the cut points; ONE undo restores the corner. Constraints referencing
   the old corner disappear cleanly (no orphan badges).
- [ ] 6. **Polygon**: click center, move (ghost n-gon), type N=8 and R,
   click. **Expect:** regular octagon + construction circle through its
   vertices + construction center point; dragging a vertex rotates/scales
   the polygon but keeps it regular; dimensioning the circle pins the size.
- [ ] 7. Pattern a spline; mirror-check bends. **Expect:** copies keep the
   exact bezier shape (handle overrides travel).

## §M30 — Reference images (canvases)

Status: PENDING sign-off

- [ ] 1. **Canvas** button → pick a photo (PNG/JPEG). **Expect:** the image
   lands on the plane (active sketch plane if sketching, else XY), a
   Canvases folder appears in the browser, a timeline chip appears, and
   the placement dialog opens.
- [ ] 2. In the dialog set Center/Width/Rotation/Opacity (unit suffixes
   work), Apply. **Expect:** the image moves/scales/tilts live in both the
   3D view and inside a sketch on that plane; Ctrl+Z reverts the edit in
   one step.
- [ ] 3. Right-click the browser row → **Calibrate…** (inside a sketch on
   its plane): click two recognizable points on the image, type the real
   distance. **Expect:** the image rescales so those points measure right
   (check with a dimension); the first pick stays put. Esc mid-pick
   cancels.
- [ ] 4. Trace geometry over the image. **Expect:** the image never steals
   clicks (it is not snappable/pickable); lines/splines draw over it; the
   grid stays visible above it.
- [ ] 5. Browser eye off/on; suppress via the timeline chip. **Expect:**
   the image hides in BOTH modes; suppress also removes it from replay.
- [ ] 6. Save, reopen. **Expect:** the image comes back exactly (bytes are
   embedded in the .ecad — move the original file away first to prove it).
- [ ] 7. Lock in the edit dialog. **Expect:** the lock shows in the browser
   row (🔒).
- [ ] 8. Import a renamed .txt as .png. **Expect:** refused with a status
   message; nothing added.

## §M31 — SVG import

Status: PENDING sign-off

- [ ] 1. **Import SVG** → pick a plane (and optional Width) → choose a
   simple file (rect + circle). **Expect:** geometry lands on that plane
   at physical size (an SVG with width="40mm" measures 40mm), right side
   up (not mirrored/flipped); ONE Ctrl+Z removes the import.
- [ ] 2. Import an Inkscape drawing (save as Plain SVG): outline with
   curves. **Expect:** straight runs come in as lines, circular arcs as
   arcs, curved runs as splines; the outline welds — hover in Extrude
   picking highlights the closed region and extruding works.
- [ ] 3. Import a file with grouped/transformed art (`<g transform=...>`,
   rotated/scaled elements). **Expect:** everything lands where the
   browser shows it.
- [ ] 4. Import a logo with text elements. **Expect:** text is skipped and
   counted in the status message; paths still import. (Convert text to
   paths in the editor to bring it in.)
- [ ] 5. Width override: type 100mm in the dialog. **Expect:** the drawing
   is uniformly scaled to 100mm wide.
- [ ] 6. Import a not-an-SVG (renamed .txt). **Expect:** refused with a
   status message; the document is untouched.
- [ ] 7. Open the imported sketch and edit: drag points, dimension the
   spline's fit points, add constraints. **Expect:** behaves like drawn
   geometry.

## §M32 — Move / copy bodies, appearance

Status: PENDING sign-off

- [ ] 1. Click a body, **Move Body**, type ΔX/ΔY/ΔZ (unit suffixes work)
   and/or an axis + angle, OK. **Expect:** the body moves/rotates (about
   its own center); a Move chip lands on the timeline; ONE Ctrl+Z undoes.
- [ ] 2. Double-click the Move chip, change values, OK. **Expect:** the
   body re-places parametrically; suppress on the chip puts it back.
- [ ] 3. Edit the source sketch of a MOVED body. **Expect:** the change
   replays and the body stays moved.
- [ ] 4. **Copy Body** on a selected body. **Expect:** a second body at the
   default offset, its own browser row/eye, exports its own STL. Edit the
   SOURCE (extrude height): the copy follows.
- [ ] 5. Browser → body → **Color…**, pick something loud. **Expect:** the
   body recolors (selection highlight still wins while selected); save +
   reopen keeps the color. Coloring a Copy is refused with a hint (it
   inherits the source).
- [ ] 6. Move a body that participates in booleans, then add a new Cut
   overlapping its OLD position. **Expect (known limitation):** booleans
   still target by pre-move overlap — the cut hits where the body
   originally stood. Documented, not a bug for this milestone.

## §M33 — Solid mirror + patterns

Status: PENDING sign-off

- [ ] 1. Select a body, **Mirror Body**, click the YZ plane. **Expect:**
   a reflected body appears on the other side, correctly lit and outward-
   facing (not inside-out dark); its own browser row + eye; ONE Ctrl+Z.
- [ ] 2. Edit the source sketch. **Expect:** mirror and any patterns
   replay to match.
- [ ] 3. **Pattern** (Linear): counts 3 × 2, offsets. **Expect:** ghost…
   dialog commits the grid; every instance a body row; double-click the
   chip and change counts — instances re-place.
- [ ] 4. **Pattern** (Circular): N=6 about Z, Total 360. **Expect:** a ring
   of instances evenly spaced. Total 180, N=3: instances at 90° and 180°.
- [ ] 5. Suppress the pattern chip. **Expect:** instances vanish; the
   source stays.
- [ ] 6. Export STL (all visible). **Expect:** every instance exports;
   volumes match the source in a slicer.
- [ ] 7. Save/reopen. **Expect:** mirror + patterns rebuild identically.
- [ ] 8. Known limitation: pattern/mirror instances are bodies derived
   AFTER booleans — a later Cut placed over an instance does not carve it
   (booleans target pre-instance bodies). Documented.

## §M34 — Sweep + loft

Status: PENDING sign-off

- [ ] 1. Draw a small profile on XZ; a path (lines/arcs chained) on XY
   starting at/near the profile. **Sweep** → click the profile (region
   highlights) → click the path → op dialog OK. **Expect:** a solid runs
   the whole path, square corners at line joints (no pinched corners),
   caps at both ends.
- [ ] 2. Sweep along a spline path. **Expect:** a smooth tube-like solid
   following the curve; no twisting.
- [ ] 3. Try a path with a hairpin tighter than the profile. **Expect:**
   refused with the status message about self-intersection.
- [ ] 4. Profile with a HOLE (circle inside a rect): sweep. **Expect:** the
   hole runs the length (check by orbiting/looking down the bore).
- [ ] 5. **Loft**: circle on XY, bigger/smaller circle on an offset plane;
   click both, OK. **Expect:** a smooth frustum; caps closed. Try a
   square→circle loft: walls stay sane (no bowtie twist).
- [ ] 6. Loft/sweep with Cut against an existing body. **Expect:** carves
   like extrude/revolve cuts do.
- [ ] 7. Chips: suppress/rollback/delete both features; edit the profile
   sketch afterward. **Expect:** replay updates the solids.
- [ ] 8. Export a swept part to STL and slice it. **Expect:** watertight.
