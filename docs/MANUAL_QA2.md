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

- [X] 1. Launch the app. **Expect:** the top bar is grouped into captioned
   shelf groups (Solids / Construct / Inspect / History / File /
   Interchange / View); every button has an icon; hovering shows a tooltip
   (shortcuts included, e.g. "Undo (Ctrl+Z)").
- [X] 2. Enter a sketch. **Expect:** the Solids/Construct groups vanish, a
   "Sketch" group with Finish Sketch appears, and two shelf rows show:
   icon-only tool strip (Select / Create / Modify / Dimension / Options
   groups) and an icon-only Constraints strip. Tooltips name every tool
   with its shortcut; clicking activates it (button stays pressed).
- [X] 3. Resize the window narrow (~900px). **Expect:** whole groups wrap
   to the next row; no button is pushed off-screen or clipped.
- [X] 4. Preferences → Theme → Light. **Expect:** the ENTIRE app recolors:
   buttons/panels/labels/status bar light, the 3D viewport background goes
   light with darker grid lines, the sketch canvas matches. Sketch line
   colors (blue/green/violet) stay legible.
- [X] 5. In light theme, open a sketch, draw, dimension, orbit off-axis.
   **Expect:** everything legible: grid, badges, dimension labels,
   selection highlight.
    Can't easily see dimension line. not enough contrast
    Update:
    When switching to light theme, popups like Preferences, are still dark, with only inputs and text changed. The tool shelf bacground is also dark, when drawing geometry, the ghost lines appear white on an alright light gray background. same for dimensions, and all other tooling. it's not till we accept the geometry that it turns into a contrasting color that we can see
- [X] 6. Quit and relaunch. **Expect:** the light theme is remembered.
   Switch back to Dark; relaunch; dark comes back.
- [X] 7. Icon check: hover every tool + constraint button once. **Expect:**
   each icon plausibly depicts its command (no blanks, no mismatches);
   both themes tint icons legibly.

### §M26 fix log

- Item 5 (2026-08-19): dimension lines/arrows hardcoded a near-white ink
  that vanished on the light background. The dimension overlay ink is now
  theme-sourced (`dim_line` / `dim_driven` palette entries — dark ink in
  the light theme); the label chips behind dimension values and type-in
  fields follow the theme panel color too, so their text stays legible in
  both themes. Selected amber and conflict red are unchanged (legible on
  both).
  Round 2 (2026-08-19), from the update note: three more dark holdouts.
  (a) GHOST previews — every drawing tool hardcoded white for its in-progress
  lines/markers, invisible on the light canvas until commit. All 38 sites now
  use a theme-following ghost ink (white on dark, near-black on light).
  (b) DIALOGS — the lazily-built popups (Preferences, Extrude, Revolve,
  Move, Color…, all 14) are raw Windows, which clear to the engine's dark
  default instead of drawing a themed panel; each now gets a themed backdrop
  panel injected as it is created, and AcceptDialog/FileDialog got themed
  "panel" styles.
  (c) SHELF — the space around the shelf groups was the same engine dark
  clear color; the app root now paints a theme-following backdrop.
  Covered by `tests/m29_qa_fixes.gd` (I).

## §M27 — Viewing: projection, look-at, units, measure

Status: PENDING sign-off

- [X] 1. Model mode with a body: press **P** (or the Ortho shelf toggle).
   **Expect:** projection flips to orthographic with no size jump; parallel
   edges render parallel. P again returns to perspective, again no jump.
- [X] 2. Enter a sketch with Ortho ON, finish it. **Expect:** sketch mode
   unaffected (always ortho); finishing returns to the ORTHO model view.
   Relaunch the app: the projection choice is remembered.
- [X] 3. **Look At** → click the XZ plane, then again → click a flat body
   face. **Expect:** hover highlights planes/faces; the camera animates to
   face it square-on. Esc cancels the pick.
- [X] 4. Orbit away, zoom far out, press **F** (or Fit). **Expect:** the
   model fills the view, centered, in both projections.
    Zoom does not work in ortho projection mode
    Update:
	Zoom does now work, however the camera is still clipping the nearby grid. like if it's near clipping pane is set too high
- [X] 5. Views dropdown → **Save View**; orbit elsewhere; pick the saved
   view. **Expect:** the exact camera returns (angle, distance, and its
   projection). Save the file, reopen it: the view survives.
- [X] 6. Preferences → Units → Millimeters. **Expect:** dimension labels,
   grid step readout, type-in defaults, and the Parameters dialog all speak
   mm; the model itself does not move. Switch to Feet and back.
- [X] 7. In a sketch select: one line; a circle; two points; two parallel
   edges; two angled lines; a point + a line. **Expect:** the status bar
   shows Length/∠, R/⌀, Dist ΔX ΔY, parallel Dist, ∠, and Dist
   respectively, in the display unit.
- [X] 8. Browser → right-click a body → **Properties…**. **Expect:** a
   popup with volume and bounding size in the display unit (³ for volume).

### Issues
In ortho mode, can't zoom into the model
Also the grid looks like it clips when close to the camera
Changing the color of a body doesn't seem to change the color of it in the regular model mode

### §M27 fix log

- Item 4 / ortho zoom (2026-08-19): the wheel only scaled the eye DISTANCE,
  which changes nothing under an orthographic camera — apparent size lives
  in `camera.size`. Ortho zoom now scales the camera size (distance scales
  alongside so the eye stays clear of the model and a later switch back to
  perspective lands at a sane range). Covered by `tests/m29_qa_fixes.gd` (F).
  Round 2 (2026-08-19), "still clipping the nearby grid": ortho ignores the
  eye distance for apparent size but NOT for the near plane — with the eye
  close, a grazing view of the ground grid crosses the near plane inside the
  view and cuts off. The ortho eye is now parked at least 8 view-heights
  back (toggle, zoom, and Fit all enforce it; pan speed keys off the view
  height so it does not race with the far eye). Sketch mode is square-on to
  its plane and is deliberately left alone. Covered by
  `tests/m29_qa_fixes.gd` (F, standoff assertion).
- Grid clipping (2026-08-19): the ground-grid quad was pinned at the plane
  ORIGIN with a fixed step count each way, so a close-up view away from the
  origin watched the grid fade out mid-screen ("clips near the camera").
  The quad now follows the camera target, snapped to the major-line lattice
  so the lines themselves never move — only the (off-screen) faded edge
  re-centers.
- Body color (2026-08-19): deselecting any body repainted EVERY body with
  the shared default gray, erasing the M32 per-body color the moment the
  colored body was no longer selected. Deselection now restores each
  body's own color. Covered by `tests/m29_qa_fixes.gd` (G).

## §M28 — Sketch splines

Status: PENDING sign-off

- [X] 1. Spline tool (B): click 4–5 points, Enter. **Expect:** a smooth
   curve through every clicked point; ghost preview follows the cursor
   while drawing; ONE Ctrl+Z removes the whole curve.
- [X] 2. Draw a spline ending double-click. **Expect:** double-click
   finishes it (no extra point from the second click).
- [X] 3. Draw 4+ points, then click the FIRST point. **Expect:** the curve
   closes smoothly (no corner at the joint); the closed region shows the
   blue profile fill; Extrude accepts it.
- [X] 4. Select the spline. **Expect:** amber tangent handles at each fit
   point. Drag one: the curve reshapes live, both sides of the handle stay
   mirrored (no kink); the drag is ONE undo step.
	Does work, however when i click on an individual point, i lose ability to edit the handles.
	I'd like to see the handles if one point is selected as well
	Also, alt + drag should adjust one single handle, not both at same time
	Regular drag should reset the handles so that they're symetrical again
- [X] 5. Drag a fit point with Select. **Expect:** the curve follows
   smoothly. Add a dimension/constraint to a fit point: it behaves like
   any sketch point (solver, DOF, badges).
- [X] 6. Construction toggle on, draw a spline. **Expect:** violet dashed
   construction curve; no profile from it.
- [X] 7. Trim/Extend/Offset on a spline. **Expect:** no crash — trim and
   extend find no cuts; Offset refuses with a status hint (documented
   limitation).
- [X] 8. Mirror a spline (with an override dragged in). **Expect:** the
   mirrored copy is the true reflection, including the reshaped bend.
   Look at docs/M28.ecad. The left spline is original. I've set it to miror around the construction line
   When i move any points on the original spline left / right, the mirror line also moves. This shouldn't be happening
- [X] 9. Export DXF with a spline; re-import. **Expect:** the curve comes
   back as a welded polyline in the right place (tessellation, documented).
- [X] 10. Save/reopen the document. **Expect:** the spline, its overrides,
   and closure survive exactly.

### §M28 fix log

- Item 4 (2026-08-19): three parts. (a) Selecting a single FIT POINT now
  shows that point's handle too — before, only selecting the whole spline
  did, so clicking a point lost the handles. (b) Alt+drag moves ONE handle
  side: the spline stores an asymmetric {out, in} override (the point may
  kink); it survives save/reopen, mirror, and patterns. (c) A plain drag
  stores a symmetric override again, so a kinked point is smoothed by
  re-dragging its handle without Alt. Covered by `tests/m29_qa_fixes.gd`
  (A, D).
- Item 8 (2026-08-19): dragging an original spline point pulled the mirror
  LINE along because the drag planner (DragFilter) grew its moving set
  through the SYMMETRY constraint into the free construction axis — the
  projection then spent part of the motion bending the axis. The axis
  operand is now excluded from that recruitment (it is a datum: the
  mirrored PARTNER follows a drag, the axis never does; grabbing the axis
  itself still drags it). Covered by `tests/m29_qa_fixes.gd` (B).

## §M29 — Sketch patterns, chamfer, polygon

Status: PENDING sign-off

- [X] 1. Draw a rect, select it (marquee), pick **Rect Pattern**. Move the
   cursor: a ghost grid follows. Type N/M (Tab cycles) and DX/DY with unit
   suffixes; click. **Expect:** the grid of copies lands; ONE Ctrl+Z
   removes all of it.
    The input boxes don't make much sense since it's' abreviations. Fusion has icons, and a tool props panel on the right that opens and lets us edit the properties of the action being performed, as well as minimal ui with icons in the workspace
    N doesn't make sense either since default value is a decimal in inches, but should be unitless whole number
    Update:
    If rows set to 1, then vertical spacing shouldn't be an option in the inputs
    Same for horizontal
- [X] 2. Drag a point on a pattern copy. **Expect:** the copy keeps its
   shape (its H/V/equal constraints came along) but may move/scale as a
   whole — Fusion-lite freedom, dimensions are not replicated.
- [X] 3. Select a circle + slot, pick **Circ Pattern**, type N=6, click a
   center. **Expect:** 5 ghost copies preview around the center before the
   click; committed copies are evenly spaced; arcs/slots keep their shape.
- [X] 4. Circ Pattern with A=180, N=3. **Expect:** copies at 90° and 180°
   exactly.
   A and N doesn't make sense since N is represented in inches, but should be unitless integer, and A is also represented in inches, but should be degrees. it starts off as 14.173 somehow being 365deg, and N = 0.157 somehow equaling 4
- [X] 5. **Chamfer**: hover a rect corner (highlights), type a distance,
   click. **Expect:** a straight cut with equal legs; the two edges rewire
   to the cut points; ONE undo restores the corner. Constraints referencing
   the old corner disappear cleanly (no orphan badges).
- [X] 6. **Polygon**: click center, move (ghost n-gon), type N=8 and R,
   click. **Expect:** regular octagon + construction circle through its
   vertices + construction center point; dragging a vertex rotates/scales
   the polygon but keeps it regular; dimensioning the circle pins the size.
   	Don't see a way to move polygon, no move tool apparent, and no move option appears when hovering over any part of polygon. if entire polygon is selected with box marquee too, and i drag an edge / point, only that edge / point move
- [X] 7. Pattern a spline; mirror-check bends. **Expect:** copies keep the
   exact bezier shape (handle overrides travel).
   Seemingly works, but there are errors in console
   ERROR: Invalid polygon data, triangulation failed.
   at: (servers/rendering/renderer_canvas_cull.cpp:1770)
   GDScript backtrace (most recent call first):
       [0] _draw (res://src/render/sketch_view.gd:460)
ERROR: Invalid polygon data, triangulation failed.
   at: (servers/rendering/renderer_canvas_cull.cpp:1770)
   GDScript backtrace (most recent call first):
       [0] _draw (res://src/render/sketch_view.gd:460)
ERROR: Invalid polygon data, triangulation failed.
   at: (servers/rendering/renderer_canvas_cull.cpp:1770)
   GDScript backtrace (most recent call first):
       [0] _draw (res://src/render/sketch_view.gd:460)
ERROR: Invalid polygon data, triangulation failed.
   at: (servers/rendering/renderer_canvas_cull.cpp:1770)
   GDScript backtrace (most recent call first):
       [0] _draw (res://src/render/sketch_view.gd:460)
ERROR: Invalid polygon data, triangulation failed.
   at: (servers/rendering/renderer_canvas_cull.cpp:1770)
   GDScript backtrace (most recent call first):
       [0] _draw (res://src/render/sketch_view.gd:460)

### §M29 fix log

- Items 1 + 4 (2026-08-19): the count/angle type-ins were formatted as
  LENGTHS — the live value ran through the mm→display-unit conversion, so
  N=4 showed as "0.157" (4 mm in inches) and 360° as "14.173". The fields
  now carry a per-field kind: counts render as unitless whole numbers,
  angles as degrees ("360°"), lengths as before; typed counts/angles parse
  as raw numbers. Labels spell the field out instead of abbreviating:
  Count/Angle (circular), Cols/Rows/Spacing X/Spacing Y (rectangular),
  Sides/Radius (polygon), and the status hints name them. The Fusion-style
  tool-properties side panel with icons is a larger UI rework — deferred to
  a later milestone. Covered by `tests/m29_qa_fixes.gd` (C).
  Round 2 (2026-08-19), from the update note: a 1-count axis no longer
  offers its spacing — with Rows=1 the "Spacing Y" box is hidden (and with
  Cols=1, "Spacing X"); the boxes reappear as soon as the count is typed
  above 1, and Tab skips hidden fields. Covered by `tests/m29_qa_fixes.gd`
  (H).
- Item 6 (2026-08-19): dragging one entity of a MULTI-selection moved only
  that entity. When the grabbed entity is part of the current selection the
  whole selection now drags as one group — marquee the polygon, drag any of
  its edges or points, and the polygon translates together. Covered by
  `tests/m29_qa_fixes.gd` (E).
- Item 7 (2026-08-19): the console spam came from the closed-region fill —
  profiles through patterned splines yield some sliver triangles that
  collapse to zero SCREEN area, and Godot's draw-time re-triangulation
  fails on each with that error, once per frame. Zero-area triangles are
  now skipped at draw (they paint nothing anyway).

## §M30 — Reference images (canvases)

Status: PENDING sign-off

- [X] 1. **Canvas** button → pick a photo (PNG/JPEG). **Expect:** the image
   lands on the plane (active sketch plane if sketching, else XY), a
   Canvases folder appears in the browser, a timeline chip appears, and
   the placement dialog opens.
- [X] 2. In the dialog set Center/Width/Rotation/Opacity (unit suffixes
   work), Apply. **Expect:** the image moves/scales/tilts live in both the
   3D view and inside a sketch on that plane; Ctrl+Z reverts the edit in
   one step.
- [X] 3. Right-click the browser row → **Calibrate…** (inside a sketch on
   its plane): click two recognizable points on the image, type the real
   distance. **Expect:** the image rescales so those points measure right
   (check with a dimension); the first pick stays put. Esc mid-pick
   cancels.
- [X] 4. Trace geometry over the image. **Expect:** the image never steals
   clicks (it is not snappable/pickable); lines/splines draw over it; the
   grid stays visible above it.
- [X] 5. Browser eye off/on; suppress via the timeline chip. **Expect:**
   the image hides in BOTH modes; suppress also removes it from replay.
- [X] 6. Save, reopen. **Expect:** the image comes back exactly (bytes are
   embedded in the .ecad — move the original file away first to prove it).
- [X] 7. Lock in the edit dialog. **Expect:** the lock shows in the browser
   row (🔒).
- [~] 8. Import a renamed .txt as .png. **Expect:** refused with a status
   message; nothing added.
   	Works but errors in console
   	[godot-thorvg] extension initialized; TVGCanvas registered.
WARNING: Not a PNG file
     at: check_error (drivers/png/png_driver_common.cpp:57)
     GDScript backtrace (most recent call first):
         [0] texture (res://src/features/canvas_feature.gd:48)
         [1] load_file (res://src/features/canvas_feature.gd:71)
         [2] import_canvas (res://src/app/app_root.gd:1357)
         [3] <anonymous lambda> (res://src/app/app_root.gd:1389)
ERROR: Condition "!success" is true. Returning: ERR_FILE_CORRUPT
   at: png_to_image (drivers/png/png_driver_common.cpp:70)
   GDScript backtrace (most recent call first):
       [0] texture (res://src/features/canvas_feature.gd:48)
       [1] load_file (res://src/features/canvas_feature.gd:71)
       [2] import_canvas (res://src/app/app_root.gd:1357)
       [3] <anonymous lambda> (res://src/app/app_root.gd:1389)
ERROR: Condition "err" is true. Returning: Ref<Image>()
   at: load_mem_png (drivers/png/image_loader_png.cpp:60)
   GDScript backtrace (most recent call first):
       [0] texture (res://src/features/canvas_feature.gd:48)
       [1] load_file (res://src/features/canvas_feature.gd:71)
       [2] import_canvas (res://src/app/app_root.gd:1357)
       [3] <anonymous lambda> (res://src/app/app_root.gd:1389)
ERROR: Condition "image.is_null()" is true. Returning: ERR_PARSE_ERROR
   at: _load_from_buffer (core/io/image.cpp:4559)
   GDScript backtrace (most recent call first):
       [0] texture (res://src/features/canvas_feature.gd:48)
       [1] load_file (res://src/features/canvas_feature.gd:71)
       [2] import_canvas (res://src/app/app_root.gd:1357)
       [3] <anonymous lambda> (res://src/app/app_root.gd:1389)

### §M30 fix log

- Item 8 (2026-08-19): the refusal worked but only AFTER handing the bytes to
  the engine's PNG decoder, which logs driver-level errors on garbage before
  failing. `CanvasFeature.load_file` now sniffs the magic number first (PNG
  `89 50 4E 47` / JPEG `FF D8 FF`) and refuses anything else without ever
  calling a decoder — silent console, same status message. The sniff also
  decides the stored format, so a PNG renamed .jpg decodes correctly now
  instead of failing. Covered by `tests/m35_qa_fixes.gd` (A).


## Additional:
crash when closed after this milestone check
C:\Dev\Godot\EchoCAD>ERROR: BUG: Unreferenced static string to 0: Physics2DConstraintSolveIslands
   at: unref (core/string/string_name.cpp:117)
ERROR: BUG: Unreferenced static string to 0: Physics2DConstraintSetup
   at: unref (core/string/string_name.cpp:117)
ERROR: BUG: Unreferenced static string to 0: servers
   at: unref (core/string/string_name.cpp:117)
ERROR: BUG: Unreferenced static string to 0: _request_gizmo_for_id
   at: unref (core/string/string_name.cpp:117)
ERROR: BUG: Unreferenced static string to 0: _enter_world
   at: unref (core/string/string_name.cpp:117)
ERROR: 7 RID allocations of type '23NavMeshGeometryParser2D' were leaked at exit.
ERROR: 6 RID allocations of type '23NavMeshGeometryParser3D' were leaked at exit.
ERROR: Pages in use exist at exit in PagedAllocator: N12VariantPools11BucketLargeE
   at: ~PagedAllocator (./core/templates/paged_allocator.h:170)

## §M31 — SVG import

Status: PENDING sign-off

- [X] 1. **Import SVG** → pick a plane (and optional Width) → choose a
   simple file (rect + circle). **Expect:** geometry lands on that plane
   at physical size (an SVG with width="40mm" measures 40mm), right side
   up (not mirrored/flipped); ONE Ctrl+Z removes the import.
   	Units not given in open panel. Also instead of manually specifying width, we should be able to instead also do the dpi
- [X] 2. Import an Inkscape drawing (save as Plain SVG): outline with
   curves. **Expect:** straight runs come in as lines, circular arcs as
   arcs, curved runs as splines; the outline welds — hover in Extrude
   picking highlights the closed region and extruding works.
   	Only able to extrude squares / rectangles. Circles or complex closed paths not able to be extruded
- [X] 3. Import a file with grouped/transformed art (`<g transform=...>`,
   rotated/scaled elements). **Expect:** everything lands where the
   browser shows it.
- [X] 4. Import a logo with text elements. **Expect:** text is skipped and
   counted in the status message; paths still import. (Convert text to
   paths in the editor to bring it in.)
   	Text is still visible, but that may because it's exported as paths rather than text. check @tests/svg_text.svg to confirm
- [X] 5. Width override: type 100mm in the dialog. **Expect:** the drawing
   is uniformly scaled to 100mm wide.
- [X] 6. Import a not-an-SVG (renamed .txt). **Expect:** refused with a
   status message; the document is untouched.
- [X] 7. Open the imported sketch and edit: drag points, dimension the
   spline's fit points, add constraints. **Expect:** behaves like drawn
   geometry.
   	Does behave liek that with exception that it's not treated as a closed path, and can't be extruded as mentioned above

### §M31 fix log

- Items 2 + 7 (2026-08-19): all-curve outlines (a circle drawn as four
  beziers, Inkscape blobs) imported as OPEN splines whose two endpoints
  welded onto one node — and ProfileFinder silently DROPPED any open spline
  whose ends collapse to the same node, so those shapes never highlighted in
  Extrude picking. Two-sided fix: the importer now marks a curve chain that
  loops back onto its own start as a CLOSED spline, and ProfileFinder treats
  a welded-loop open spline as its own face (covers hand-drawn/DXF loops
  too). `tests/svg.svg`'s bezier circle and blob both extrude now. Covered
  by `tests/m35_qa_fixes.gd` (B, G).
- Item 1 (2026-08-19): the import dialog's Width field now names the display
  unit in its label (suffixes like `40mm` always worked; now it says so),
  and a new **DPI** field (default 96) rescales UNITLESS files — an SVG with
  no physical width/height is read at CSS's 96 px/in by default, and typing
  e.g. 300 shrinks it to true print size. Files that declare mm/cm/in/pt
  ignore the DPI (their size is already physical). Covered by
  `tests/m35_qa_fixes.gd` (C).
- Item 4 (2026-08-19): NOT a bug — `tests/svg_text.svg` contains zero
  `<text>` elements (only three `<path>`es): the exporter converted the text
  to outlines before saving, so importing it as geometry is correct. Real
  `<text>` elements are still skipped and counted (see the parse's skip
  list); nothing to change.
- Shutdown errors (2026-08-19): the "Unreferenced static string" /
  RID-leak spew at exit comes from resources held in GDScript STATIC vars
  (the theme's icon-texture cache, a compiled RegEx), which are torn down
  after the rendering servers. AppRoot now drops those caches in
  `_exit_tree`. The NavMeshGeometryParser RID lines are engine-internal
  Godot 4.7 exit noise (present in an empty project too) — harmless,
  after the window has closed, no data at risk.

## §M32 — Move / copy bodies, appearance

Status: PENDING sign-off

- [X] 1. Click a body, **Move Body**, type ΔX/ΔY/ΔZ (unit suffixes work)
   and/or an axis + angle, OK. **Expect:** the body moves/rotates (about
   its own center); a Move chip lands on the timeline; ONE Ctrl+Z undoes.
- [X] 2. Double-click the Move chip, change values, OK. **Expect:** the
   body re-places parametrically; suppress on the chip puts it back.
- [X] 3. Edit the source sketch of a MOVED body. **Expect:** the change
   replays and the body stays moved.
- [X] 4. **Copy Body** on a selected body. **Expect:** a second body at the
   default offset, its own browser row/eye, exports its own STL. Edit the
   SOURCE (extrude height): the copy follows.
- [X] 5. Browser → body → **Color…**, pick something loud. **Expect:** the
   body recolors (selection highlight still wins while selected); save +
   reopen keeps the color. Coloring a Copy is refused with a hint (it
   inherits the source).
   Copies should inherit color from source originally, but be allowed to color itself after
- [X] 6. Move a body that participates in booleans, then add a new Cut
   overlapping its OLD position. **Expect (known limitation):** booleans
   still target by pre-move overlap — the cut hits where the body
   originally stood. Documented, not a bug for this milestone.

### Additional:
UI elements in the Body Color window are too large, they take up too much room. have to increase window height to see apply button, not able to scroll

### §M32 fix log

- Additional (2026-08-19): the stock ColorPicker's sampler row, RGB/HSV mode
  switcher and preset shelf pushed Apply below the window. The picker is now
  compact (sampler/modes/presets hidden — wheel + sliders + hex stay) and
  sits inside a scroll container, so Apply is always reachable at 300x420.

- Item 5 (2026-08-19): as requested — a fresh copy INHERITS its source's
  color (recolor the source and every uncolored copy follows), and Color…
  on the copy now works instead of refusing: it stores an own color on the
  CopyBodyFeature that overrides the inherited one from then on (undoable,
  saved in the .ecad). The picker opens pre-seeded with the inherited
  color. Covered by `tests/m35_qa_fixes.gd` (D);
  `tests/rpc/test_move_bodies.py` updated (it asserted the old refusal).

## §M33 — Solid mirror + patterns

Status: PENDING sign-off

- [X] 1. Select a body, **Mirror Body**, click the YZ plane. **Expect:**
   a reflected body appears on the other side, correctly lit and outward-
   facing (not inside-out dark); its own browser row + eye; ONE Ctrl+Z.
- [X] 2. Edit the source sketch. **Expect:** mirror and any patterns
   replay to match.
  Editing source sketch causes body to disapear
- [X] 3. **Pattern** (Linear): counts 3 × 2, offsets. **Expect:** ghost…
   dialog commits the grid; every instance a body row; double-click the
   chip and change counts — instances re-place.
- [X] 4. **Pattern** (Circular): N=6 about Z, Total 360. **Expect:** a ring
   of instances evenly spaced. Total 180, N=3: instances at 90° and 180°.
- [X] 5. Suppress the pattern chip. **Expect:** instances vanish; the
   source stays.
- [X] 6. Export STL (all visible). **Expect:** every instance exports;
   volumes match the source in a slicer.
- [X] 7. Save/reopen. **Expect:** mirror + patterns rebuild identically.
- [~] 8. Known limitation: pattern/mirror instances are bodies derived
   AFTER booleans — a later Cut placed over an instance does not carve it
   (booleans target pre-instance bodies). Documented.

### §M33 fix log

- Item 2 + the bottom "big bug" (2026-08-19), from `tests/M33.ecad`: every
  profile-based feature (extrude/revolve/sweep/loft/fillet) remembered its
  region by a fixed ANCHOR POINT — editing the sketch and moving the whole
  shape left the anchor outside every region, so the body (and any mirror/
  pattern derived from it) silently vanished on replay. Anchors now
  SELF-HEAL: when the stored point no longer hits a region, the nearest
  region (by interior point) is used and a fresh in-region anchor is stored,
  so later edits keep working. M33.ecad rebuilds its 3x2.5x2in box again.
  Covered by `tests/m36_qa_fixes.gd` (A).

## §M34 — Sweep + loft

Status: PENDING sign-off

- [X] 1. Draw a small profile on XZ; a path (lines/arcs chained) on XY
   starting at/near the profile. **Sweep** → click the profile (region
   highlights) → click the path → op dialog OK. **Expect:** a solid runs
   the whole path, square corners at line joints (no pinched corners),
   caps at both ends.
   	Fails with message about tight paths and intersections. See @tests/M24.ecad
   	Update:
   		Still fails M32-2.ecad
    Update:
      Still get error see M34.ecad 
      Model Sweep failed: a path bend radius is tighter than the profile's 12.7mm extent
      In other programs, don't they just let the part intersect with itself?
- [X] 2. Sweep along a spline path. **Expect:** a smooth tube-like solid
   following the curve; no twisting.
- [~] 3. Try a path with a hairpin tighter than the profile. **Expect:**
   refused with the status message about self-intersection.
- [!] 4. Profile with a HOLE (circle inside a rect): sweep. **Expect:** the
   hole runs the length (check by orbiting/looking down the bore).
  Caps aren't drawn when we do this
  See M34-1
- [!] 5. **Loft**: circle on XY, bigger/smaller circle on an offset plane;
   click both, OK. **Expect:** a smooth frustum; caps closed. Try a
   square→circle loft: walls stay sane (no bowtie twist).
    Loft should allow me to select an axis to loft around. right now it wants two bodies instead
- [~] 6. Loft/sweep with Cut against an existing body. **Expect:** carves
   like extrude/revolve cuts do.
- [ ] 7. Chips: suppress/rollback/delete both features; edit the profile
   sketch afterward. **Expect:** replay updates the solids.
- [ ] 8. Export a swept part to STL and slice it. **Expect:** watertight.

### §M34 fix log

- Item 1 (2026-08-19), from `tests/M34.ecad` (the note says M24.ecad but the
  file is M34): the profile circle sits on XZ at (12.7, 63.5) while the
  spline path on XY starts ~150 mm away — and the sweep carried the profile
  at its DRAWN OFFSET from the path start, so the swept ring's radial extent
  was ~75 mm and every gentle bend read as "tighter than the profile".
  Now: when the path start projects INSIDE the profile the drawn offset is
  kept (Fusion-style offset sweeps still work); a profile drawn elsewhere is
  re-anchored to its own centroid, so it simply travels along the path —
  the M34.ecad case builds a clean tube. The refusal messages also say what
  actually failed now (no profile / closed-loop path / bend tighter than
  the profile / hairpin) instead of one catch-all. Covered by
  `tests/m35_qa_fixes.gd` (E).
  Round 2 (2026-08-19), "Still fails M32-2.ecad": that file is NOT in the
  repo (tests/ has no M32-2.ecad — please commit it if the case still
  fails). Two blind-spot fixes went in anyway: (a) the "keep the drawn
  offset" test PROJECTED the path start onto the profile plane, so a start
  far along the plane NORMAL still counted as "inside" and the phantom arm
  tripped the too-tight check — the offset is now kept only when the start
  is inside the outline AND within the profile's extent of its plane;
  (b) stale profile anchors self-heal (§M33 fix), which also revives sweeps
  whose profile sketch was edited after the pick; and the too-tight refusal
  now prints the actual numbers ("bend radius X mm vs profile extent Y mm")
  so the next report can say which case fired. Covered by
  `tests/m36_qa_fixes.gd` (B).
  Round 3 (2026-08-19), from `tests/M34.ecad` (now in the repo): the bend
  really IS tighter than the 1in-dia profile — and per the note ("don't
  they just let the part intersect with itself?") that is no longer a
  refusal: the sweep BUILDS (the mesh stays closed; the walls fold locally
  at the tight bend) and the status bar carries a warning instead
  ("...the solid self-intersects there"). Only true hairpins — a path
  joint turning more than ~120°, where the miter joint degenerates —
  still refuse, which keeps QA item 3 meaningful. Covered by
  `tests/m36_qa_fixes.gd` (B2) and the reworded hairpin case in
  `tests/m34_sweep_loft.gd`.
- Item 4 (2026-08-19), from `tests/M34-1.ecad` (now in the repo): the ring
  profile (two concentric circles) capped NOTHING because both circles
  tessellate at the same angles — the hole's splice bridge landed exactly
  ON an outer vertex and the engine's ear clipper refused the merged
  polygon (`triangulate_with_holes` returned no triangles). The same
  failure made a ring EXTRUDE vanish entirely. The triangulator now falls
  back to a Delaunay of the boundary points filtered to the region
  (centroid inside the outer, outside every hole), which caps any splice
  the ear clipper rejects — sweeps, extrudes, revolves and the 2D/3D
  region fills all share it. Covered by `tests/m36_qa_fixes.gd` (B3).
- Item 5 (2026-08-19): the documented flow (circle on XY, circle on an
  offset plane, click both, OK) does work end-to-end — verified by
  `tests/m36_qa_fixes.gd` (E), frustum volume and all — but the UX fought
  it: the Loft dialog popped up CENTERED, right on top of the profiles you
  are supposed to click, and picked sections showed nothing but a count.
  The dialog now opens in the top-right corner (same placement as the
  fillet/chamfer pick) and every picked section stays marked with an amber
  fill until commit/cancel. On "select an axis to loft around": lofting
  about an axis IS Revolve (§M23) — Loft is profile-to-profile by
  definition; the not-enough-sections hint now says so. Fusion-style
  centerline/guide-rail lofts are a future-milestone item.

## §M35 — 3D fillet + chamfer (prismatic)

Status: PENDING sign-off

- [!] 1. Extrude a rectangle; select the body; **Fillet Edges**, size,
   Side corners only. **Expect:** all four vertical edges round; the
   silhouette reads clean; a Fillet chip lands on the timeline.
   	Only front 8 edges have fillet, rear 4 don't. however this tool isn't supposed to fillet all edges, only the edges that we select. it should be select tool, then select all edges to fillet, adjust radius if needed, then accept. same for chamfer
   	Update: Unable to individually select front edges of a the body. it instead wants to only select the entire rectangular loop. filleted side edges worked as expected
- [ ] 2. Double-click the chip, change the size. **Expect:** re-rounds
   parametrically; suppress restores the sharp body.
- [ ] 3. **Chamfer Edges** with Top rim on a fresh box. **Expect:** a flat
   45° band around the top; Bottom rim ticks the base too.
- [ ] 4. Fillet Top rim on a CYLINDER. **Expect:** a smooth donut-edge cap.
- [ ] 5. Edit the source sketch (resize the rect). **Expect:** treatment
   replays on the new shape.
- [ ] 6. Oversize (radius > half an edge / taller than the body).
   **Expect:** refused with a status hint, nothing added.
- [ ] 7. Try it on a body with a Cut, on a revolve, on a swept body.
   **Expect:** refused with the prismatic-scope hint (documented — general
   mesh fillets are the B-rep-kernel tier tracked in the backlog).
- [ ] 8. Fillet a real bracket (corners + top rim), export STL, slice.
   **Expect:** watertight, printable.

### §M35 fix log

- Item 1 (2026-08-19): reworked to the requested select-edges workflow. The
  "front 8 / rear 4" split was the old defaults (side corners + top rim on,
  bottom rim off) — gone with them. Now: select a body, press Fillet/Chamfer
  Edges → every treatable edge draws highlighted in the viewport; hovering
  thickens the edge under the cursor; clicking toggles it into the selection
  (amber); the top/bottom RIM toggles as a whole loop (per-segment rim
  treatment needs variable insets — B-rep-kernel tier); a small Size+Apply
  panel sits top-right; Enter or Apply commits, Esc cancels. The feature
  stores the picked corner set (`corners`), replays and serializes it, and
  the timeline's double-click edit changes the size while keeping the picked
  edges. RPC `fillet_edges`/`chamfer_edges` accept an optional `corners`
  list; the old lateral/top/bottom args still mean "all corners" for
  compatibility. NOTE for re-test of items 2–8: the flows are unchanged
  except that "Side corners only" etc. is now expressed by which edges you
  click. Covered by `tests/m35_qa_fixes.gd` (F) and the unchanged
  `tests/m35_fillet_chamfer.gd`.
  Round 2 (2026-08-19), "unable to individually select front edges": rim
  segments were one all-or-nothing loop ("top"/"bottom" keys). Every rim
  SEGMENT is now its own pickable edge — click just the front top edge and
  only it gets treated. Whole rims (all segments picked, or legacy
  documents/RPC) keep the exact offset-ring path; partial rims build
  segment-wise: shortened wall + quarter-round/chamfer band under each
  picked edge, mitered where two picked edges meet, band ends sliding onto
  the neighbor wall's plane (the neighbor wall is clipped to match, so the
  mesh stays watertight — a single-edge chamfer removes exactly its wedge).
  Picked segments serialize (`top_segs`/`bottom_segs`) and replay. Known
  prismatic-tier limits: a rim treatment stops flat at an untreated
  neighbor (no Fusion-style corner ball), and rims across lateral corner
  ARCS stay sharp. Covered by `tests/m36_qa_fixes.gd` (C).

### Additional
commit changes
  big bug i discovered.
  create sketch of a cube > extrude it > Edit original Sketch > move all points > finish
  sketch > extruded body disapears. No object available in bodies section in outliner
  saved as @tests/M33.ecad
  another thing to note, i have to explicitely always tell agents to add hover over
  indicators for tools when we are adding new tools, or updating tools. for instance, when
  performing sweep operation, first i click sweep button, then click on closed geometry,
  then next step is to click another path to be the path that the geometry gets swept on.
  choosing the second path, there is no indication that the geometry under the mouse
  cursor will is valid until user clicks on it. there's no highlighting of the line like
  in other tools. i don't want to explicitely state this anymore, and there are many more
  tools that are similar that are broken like this. i want it to be a hard rule that when
  we're adding some tool like this

### Additional fix log (2026-08-19)

- "Big bug" (body disappears after moving all sketch points): fixed by the
  anchor self-heal — see the §M33 fix log. `tests/M33.ecad` rebuilds again.
- Hover hard rule: now a locked rule in CLAUDE.md ("Hover feedback is
  mandatory on every pick stage" — every new/updated tool pick must
  pre-highlight the candidate under the cursor; a pick stage without hover
  is a bug). The one current offender, the sweep PATH pick, now highlights
  the curve under the cursor (lines, arcs and splines alike) as the same
  amber band the revolve-axis pick uses. Audit of the other pick stages:
  sketch-plane / look-at / mirror-plane picks (plane + face hover),
  extrude / revolve / sweep-profile / loft (region hover), revolve axis
  (axis band), fillet/chamfer edges (edge tube) all already highlight.
  Covered by `tests/m36_qa_fixes.gd` (D).
- "commit changes": committed with this round.
