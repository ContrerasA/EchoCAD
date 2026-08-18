# EchoCAD — Manual QA Checklist

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

## §M2 — 3D shell + sketch mode

Status: PENDING sign-off

- [x] 1. Launch the app. **Expect:** window opens; 3D view with red/green/blue
   origin axes; the browser tree sits on the left with "Origin" and "Bodies"
   folders; view cube top-right; status bar reads "Model". The world is
   **Z-up** (Blender/Fusion): blue Z points straight up, red X and green Y
   lie flat in the ground plane. The origin planes are **hidden** (Fusion
   behaviour), and there is **no stray cube at the origin**.
- [X] 1a. The view cube's orientation matches the 3D view **from boot**, before
   any orbit. **Issue:** on launch the 3D view is the 3/4 home view but the
   cube renders flat, as if from the front; it only catches up on the first
   orbit. Fixed — see fix log **7**.
- [x] 2. Drag with middle mouse button. **Expect:** view pans; the view cube does
   not move (it only rotates).
- [x] 3. Hold Shift + drag middle mouse. **Expect:** orbit; view cube rotates in
   lockstep; the horizon stays level (no roll) at every angle.
- [x] 3a. Start a Shift+MMB orbit, then **release Shift while still dragging**.
   **Expect:** it keeps orbiting — it must not switch to panning mid-drag.
   The gesture only ends when the middle button is released.
- [x] 3b. With a solid in view, check the "Orbit:" dropdown in the top bar.
   **Expect:** "Body Center" is the default (Fusion style) — orbiting keeps
   the body pinned in place even when it is off-center. Switch to
   "Under Cursor" (Blender style): orbit pivots about the surface point under
   the pointer where the drag began. Switch to "View Center": orbit pivots
   about the view's center, as before.
- [x] 4. Scroll wheel up/down. **Expect:** zoom in/out toward the model.
- [x] 5. Click a face of the view cube (e.g. the one facing you). **Expect:**
   camera animates (~0.25 s) to that axis-aligned view.
- [x] 6. Click "Create Sketch". **Expect:** the three origin planes **appear**;
   status hint reads "Select a plane (Esc to cancel)"; hovering a plane
   highlights it brighter.
- [x] 7. Press Esc. **Expect:** picking cancels, hint clears, no sketch created,
   and the origin planes go back to hidden.
- [x] 8. Click "Create Sketch", then click the XZ plane. **Expect:** camera
   animates to look straight at the plane; view switches to the 2D sketch
   canvas: dark background, adaptive grid, red horizontal + green vertical
   axis lines through the origin; status reads "Sketch" and "Sketch1 on XZ";
   "Finish Sketch" button replaces "Create Sketch". The 2D canvas background
   is the **same dark colour** as the 3D view — the swap must not change the
   shade under the work.
- [x] 9. Scroll wheel in the sketch view. **Expect:** zoom anchors at the cursor
   (the point under the cursor stays put); grid density adapts — line
   spacing stays readable at every zoom, never a solid wall or a bare void.
- [x] 10. Middle-drag in the sketch view. **Expect:** pan; axes and grid move
    together, no drift or smearing.
- [x] 11. Click "Finish Sketch". **Expect:** the 2D canvas drops and the camera
    **animates back** to the model view you were at before entering the
    sketch; planes stay hidden; status "Model".
- [x] 12. Ctrl+Z. **Expect:** the (empty) Sketch1 feature is undone. Ctrl+Shift+Z
    restores it.
- [x] 13. Create a second sketch on XY. **Expect:** it is auto-named "Sketch2".
- [x] 14. Resize the window in both modes. **Expect:** layout fills the window; no
    stretching artifacts; sketch raster stays crisp after resize.
- [x] 15. Sketch a closed square and extrude it, then click the solid in the 3D
    view. **Expect:** it turns amber; its row in the browser's "Bodies"
    folder highlights. Click empty space: the highlight clears. Ctrl+Z after
    selecting: undo steps back over the *extrude*, never over the selection
    (selecting a body is view state, not a model change).
- [x] 16. Untick the eye box next to a body in the browser. **Expect:** it hides,
    and clicking where it was selects nothing. Re-tick: it comes back.
- [x] 17. Tick "XY" under Origin in plain model mode (no sketch, not picking).
    **Expect:** the XY plane appears *immediately* — a ticked box means
    visible, not merely "allowed to show". Untick it: it goes away.
- [x] 17a. With all three planes unticked, click "Create Sketch". **Expect:** all
    three appear anyway (you are being asked to click one). Press Esc: they
    all go back to hidden, and the boxes still read unticked — the pick-time
    reveal is a temporary override and does not rewrite your ticks.
- [x] 17b. Tick only XZ, then "Create Sketch" and Esc. **Expect:** all three show
    during the pick; afterwards XZ stays visible and the other two hide.
- [x] 17c. Look at each origin plane's shape. **Expect:** Fusion-style quadrants —
    each quad has a *corner at the origin* and runs out in its two positive
    directions, so the three together form a corner. They are NOT sheets
    centred on the origin crossing through each other.
- [x] 18. Untick "Axes" under Origin. **Expect:** the origin axes disappear.
- [x] 19. Look closely at the view cube while a solid is on screen. **Expect:** it
    shows *only* the cube — no bodies, no axes, no planes inside it.
- [X] 20. In plain model mode, look at the ground. **Expect:** a Fusion-style grid
    lying flat on the **XY** ground plane, every 5th line brighter, fading
    out well away from the origin. Orbit under it: the grid does not block
    the solids sitting on it. **Issue:** at some camera distances not every
    line renders, so cells read as rectangles instead of squares. Fixed —
    see fix log **8e** for the cause that was finally right. Passes **8**,
    **8b**, **8c** and **8d** each fixed a real but different bug and left the
    thing on screen untouched.
- [x] 21. Zoom way out, then way in. **Expect:** the grid spacing steps through
    1/2/5 × powers of ten — it never packs into a solid sheet or vanishes.
- [X] 21a. Zoom slowly through a spacing change, in BOTH model and sketch mode.
    **Expect:** Blender-style — the intermediate lines FADE in and out as you
    scale, reaching full strength exactly as the spacing changes over. Nothing
    should appear or vanish on a single frame, and no line should have a TWIN
    a few pixels beside it at any zoom. **Issue:** the spacing snapped between
    rungs, so every intermediate line popped; the first fix for that then drew
    doubled lines. Fixed — see fix log **14** and **15**.
- [x] 22. Create a sketch on **XZ**. **Expect:** during the fly-in the grid is
    already standing up on XZ, matching the 2D canvas you land on. Click
    "Finish Sketch": it lies back down on XY.
- [x] 23. Re-open that sketch from the timeline (double-click its chip). **Expect:**
    the grid stands up on XZ again.
- [x] 24. Untick "Grid" under Origin in the browser. **Expect:** the grid
    disappears, in both model and sketch mode, and stays gone across a
    sketch enter/exit round trip until re-ticked.
- [!] 25. With Sketch1 finished and containing geometry, create Sketch2 on the
    same plane. **Expect:** Sketch1's geometry is still visible in the 2D
    canvas, drawn dimly as reference, and Sketch2's own geometry draws on
    top at full strength, and the 3D model (solids from earlier extrudes)
    stays visible behind the canvas. **Issue:** other sketches were not drawn
    at all, and the 3D model was hidden completely. Fixed — see fix log **9**
    (reference sketches), **10** (model visible behind the canvas) and **12**
    (the model now pans/zooms WITH the sketch instead of hanging in place like
    a ghost image) and **13** (ORTHOGRAPHIC in sketch mode — the earlier passes
    were faking a 2D view with a perspective camera).
- [X] 25a. Look at the browser tree. **Expect:** a **Sketches** folder listing
    every sketch by name, each with an eye tick that hides it in the 3D view
    AND as reference geometry in sketch mode. The sketch currently open is
    highlighted. Fixed — see fix log **11**.
- [X] 26. Hover a reference-geometry line from another sketch with the Line
    tool. **Expect:** it does NOT snap to it and does NOT highlight — M2
    reference geometry is display-only. Snapping to other sketches is M15.

Fix log:
- **1 + 4 (one bug)** — `ViewCube`'s `SubViewport` never set `own_world_3d`,
  so it shared the main `World3D`: its 25 mm cube rendered as a phantom box at
  the model origin, and every body leaked into the corner widget. Setting
  `own_world_3d = true` fixes both directions at once. The cube is still what
  draws the widget — it just lives in its own world now.
- **2** — origin planes now start hidden. `CadWorld` gates them on
  `_planes_mode_visible` (on only while "Create Sketch" is picking a plane,
  off again on Esc/commit) ANDed with a per-plane browser toggle, so unticking
  a plane keeps it hidden even during picking.
- **2 (follow-up: ticks did nothing)** — the first cut ANDed the browser tick
  with the mode gate, so a tick was only a *permission* and planes stayed
  hidden outside plane-picking. Corrected to an OR: a tick means visible, full
  stop, and plane-picking force-shows all three on top of that without
  rewriting the ticks (so an unticked plane returns to hidden after the pick).
  The ticks now start unticked, which both keeps the open view clean and makes
  the boxes honest about what is on screen.
- **2 (follow-up: quad shape)** — the origin planes were sheets centred on the
  origin, crossing through each other. They are now Fusion-style quadrants:
  each quad has its corner ON the origin and runs out along +u/+v
  (`QuadMesh.center_offset` shifts the inherently-centred quad). `PLANE_HALF`
  became `PLANE_SIDE` (a full side, not a half-extent) and both ray hit tests
  moved to a shared `_on_quad` helper testing `0..PLANE_SIDE` rather than `±`.
- **2 (tree)** — new `src/app/browser_tree.gd`: a Fusion-style browser docked
  left with Origin (Axes + the three planes) and Bodies folders, each row
  carrying an eye checkbox. Visibility is view state — it never touches the
  command stack, matching Fusion.
- **3** — solids are click-selectable in model mode via `CadWorld.pick_body`
  (reuses the existing ray-vs-triangle test); the hit body recolours to
  `COLOR_BODY_SELECTED` and its browser row selects. Hidden bodies are not
  pickable, and are excluded from `model_bounds`/`pick_point` so orbit pivots
  never land on invisible geometry.
- **5a** — the sketch-entry animation existed but was invisible: `edit_sketch`
  showed the 2D canvas on the same frame it started the camera tween, painting
  over it. The canvas now waits for the tween (`_after_camera_move`).
  `finish_sketch` is the mirror: it drops the canvas first, then animates the
  camera back to the view captured on entry, via the new
  `OrbitCamera.capture_view`/`restore_view`.
- **5b** — both modes now share one background. `CadWorld.COLOR_BG` is the
  single source: model mode paints it as the environment's clear colour
  (previously unset, so it fell back to Godot's default grey) and
  `SketchView.COLOR_BG` aliases it.
- **5c (deferred)** — orbiting inside the sketch view and returning via a
  view-cube face is a mode sub-state plus a 3D render path for the in-edit
  sketch, too large for this pass. Written up as **M14 — Orbitable sketch
  view** in `docs/MILESTONES.md`. `capture_view`/`restore_view` landed here
  and give M14 its return-trip animation.
- **6 (3D ground grid)** — model mode had no grid at all; only the 2D canvas
  drew one. `CadWorld` now builds a line-mesh grid that lies on **XY** in
  model mode and moves onto the sketch's own plane while one is open (set in
  `edit_sketch` *before* the fly-in, so the camera lands on a grid that
  already agrees with the 2D canvas; `finish_sketch`/`load_document` put it
  back on XY). Density follows camera distance off the same 1/2/5 ladder the
  sketch canvas uses — `SketchView.grid_step_mm` was factored into a shared
  `SketchView.step_for(unit, target_mm)` so the two surfaces cannot drift
  apart. Drawn with `no_depth_test` + a negative `sorting_offset` so it never
  occludes the solids sitting on it. Toggleable via a "Grid" row under Origin
  in the browser.
- **7 (step 1a — view cube flat on boot)** — `OrbitCamera._ready` sets the
  home 3/4 view and emits `moved` from inside its own `add_child`, which
  happens BEFORE `AppRoot` creates the view cube and connects the signal. The
  cube therefore never received an orientation until the user's first orbit.
  `_build_ui` already re-primed the grid for exactly this reason; the cube now
  gets the same treatment (`view_cube.sync_orientation(rig.rotation)` right
  after it is added), and `ViewCube._ready` seeds itself with an identity sync
  so it is never left in an unset state even without an owner.
- **8 (step 20 — grid cells read as rectangles)** — the u-direction and
  v-direction lines were emitted into the same `ImmediateMesh` surface run but
  the *extent* of each line was `_grid_step * GRID_EXTENT_STEPS`, i.e. the
  grid's size changed with the zoom-driven step. At the distances where the
  step ladder had just changed, the far lines of one direction ran past the
  camera's far plane / outside the fade while the other direction's did not,
  so one axis visibly dropped lines and cells read as rectangles. The extent
  is now pinned to a fixed world span (`GRID_SPAN_MM`) independent of the
  step, and the line count per direction is derived from it, so both
  directions always cover the identical square region.
- **9 (step 25 — other sketches invisible in the canvas)** — `RenderBridge`
  drew only the one `Sketch` handed to it, so entering a sketch hid every
  other sketch in the document. `full_sync` now takes an optional array of
  reference sketches drawn first, in a dimmed colour
  (`COLOR_REFERENCE`), with the active sketch drawn over them. `AppRoot`
  supplies the other live sketch features that share the active sketch's
  plane. Reference geometry is display-only in M2 — it is not in the snap
  index and not hit-testable (step 26); making it snappable is **M15**.

- **8b (step 20 — the real cause: lines too dim to survive thin coverage)** —
  fix **8** corrected a genuine asymmetry in the mesh, but it was not what the
  user was seeing, and the lines kept dropping out. The actual cause was
  colour, not geometry. `COLOR_GRID_MINOR` was alpha **0.05**: against
  `COLOR_BG` that is ~11/255 of contrast at FULL pixel coverage, and a grid
  line seen near edge-on covers a fraction of a pixel, scaling that to 1-2/255
  — which quantises to nothing. Whole runs of receding lines vanished while
  the perpendicular set (nearer to face-on, so better covered) survived, which
  is exactly why the cells read as rectangles.
  Raised to 0.22/0.40, which survives thin coverage, and the brightness that
  buys is paid back by a real distance fade in a small shader
  (`GRID_SHADER`): radial from the grid origin so it dissolves evenly instead
  of ending at a visible square edge, AND by distance from the camera, which
  is what stops a grazing view stacking hundreds of receding lines into a
  solid mat at the horizon. The span also became a step COUNT
  (`GRID_SPAN_STEPS`) rather than a fixed mm figure, so the grid scales with
  the zoom-driven step instead of ending mid-screen when zoomed out.
  Verified by screenshot at the home view and at a grazing angle.
- **10 (step 25 — the 3D model was invisible while sketching)** —
  `SketchView._draw` filled its whole rect with an OPAQUE `COLOR_BG`, and the
  3D viewport sits directly behind it, so opening a sketch hid every solid in
  the model: you could not see the part you were drawing on. The fill is now a
  veil at `MODEL_VEIL_ALPHA`, so the model reads through, knocked back, the
  way Fusion shows it. Because the veil colour IS the 3D background, an empty
  model looks exactly as it did before.
- **11 (step 25a — sketches unnamed and not hideable)** — the browser had only
  Origin and Bodies, so sketches were anonymous and could not be got out of
  the way. Added a **Sketches** folder listing each sketch by name with an eye
  tick, and highlighting whichever is open. The tick drives `CadWorld`'s new
  `_sketch_hidden` set, which gates BOTH the 3D line mesh and the sketch-mode
  reference geometry, so one tick means the same thing in either mode.
- **8c (step 20 — the SKETCH grid, which is a different grid)** — fixes **8**
  and **8b** were both real, and both were applied to the 3D ground grid in
  `CadWorld`. The screenshot showing missing minor lines was the **2D sketch
  canvas**, drawn by `SketchView._draw`, which kept its own copy of the
  constants at the old 0.05/0.11 — so it was never touched by either pass.
  Worse, fix **10**'s veil is drawn underneath it, eating into the little
  contrast those alphas had. `SketchView` now aliases `CadWorld`'s colours
  exactly as it already aliases the step ladder and the background, so the two
  surfaces cannot drift apart again. Lesson recorded because it cost two
  rounds: "the grid" is two grids, and a fix has to name which.
- **12 (step 25 — the model hung in place like a ghost)** — fix **10** made the
  3D model visible behind the sketch, but the two had entirely independent
  cameras: panning or zooming the sketch moved the 2D geometry while the solid
  behind it stayed exactly where it was, so it read as an image stuck to the
  screen rather than as part of the drawing. `_sync_camera_to_sketch_view`
  now points the 3D camera at the sketch's pan centre, square onto the sketch
  plane, from the distance that makes its on-screen scale match the 2D zoom
  (derived from the camera FOV and viewport height). Run on every
  `view_changed` and once when the fly-in lands, since that signal does not
  fire on entry. It deliberately does nothing while the entry tween is running,
  which would otherwise snap the camera to the destination mid-animation.

- **8d (step 20 — the ACTUAL cause, after three wrong ones)** — the grid step
  itself was wrong. `SketchView.step_for` scaled a running value UP until it
  exceeded the target and only then consulted the 1/2/5 ladder, which made
  `mult = 1.0` always win and left 2 and 5 as unreachable dead code. Results
  overshot the requested spacing by up to **8.5x**. At the default 800 mm
  camera distance the target is 48 mm and it returned **254 mm** — a 10 inch
  minor spacing, wider than the viewport — so near the origin only MAJOR lines
  ever appeared and the grid read as though lines were missing.
  Rewritten to work in units rather than mm: take the largest power of ten at
  or below the target, then step up through 1/2/5. The home view now picks
  50.8 mm (2 in) instead of 254 mm — five times denser — and every step lands
  within 1.0-1.7x of target. Because both surfaces share `step_for`, this fixes
  the 2D canvas at the same time.
  Recorded plainly because the three earlier passes were guesses at the symptom
  (line alpha, mesh symmetry, then the 2D copy of the colours) and never
  touched the arithmetic that actually chooses the spacing. The lesson: dump
  the generated geometry and read the numbers before theorising about why it
  looks wrong. Regression test: `tests/m02_grid_step.gd`, verified to FAIL
  against the old implementation.
- **8e (step 20 — line PRIMITIVES were the cause all along)** — four passes had
  gone after alpha, mesh symmetry, the 2D copy of the colours, and the step
  ladder. Every one of those was a genuine bug, and none was what the
  screenshots showed. The answer came from measuring pixels instead of looking:
  scanning DOWN the screen across a single family of lines, where the spacing
  must grow smoothly toward the viewer, gave `12, 15, 14, 18, 15, 24, 48, 19,
  40, 23` — a 48 followed by a 19 means whole runs of lines simply absent.
  `PRIMITIVE_LINES` rasterises a hairline exactly one pixel wide with no
  antialiasing, so at the raking angles a ground plane is normally viewed at,
  lines fall between pixel centres and are dropped. No amount of colour, span,
  fade or spacing arithmetic can fix that, because the geometry was always
  correct — the rasteriser was throwing it away.
  The grid is now ONE QUAD with the lines computed per fragment, using
  screen-space derivatives (`fwidth`) so a line is never thinner than a pixel
  and antialiases itself. Distant lines fade smoothly instead of flickering
  out. The same scan now reads `12, 15, 13, 19, 15, 24, 16, 31, 19, 41, 22,
  54` — monotonic, with two more lines present than before.
  Also fixed while here: grid density keyed off camera DISTANCE, which is
  proportional to apparent size under perspective but meaningless under the
  orthographic camera sketch mode now uses — the 3D grid came out four times
  coarser than the 2D canvas beneath it. It keys off `view_height_mm()` now, so
  both grids agree. Measured after: the sketch canvas shows 17 lines at a
  regular 50-52 px, exactly the predicted 50.8.
  Recorded at length because the repeated failure had one cause: I kept
  reasoning about why the picture looked wrong instead of measuring what was
  actually on it.
- **13 (step 25 — perspective was faking a 2D view)** — sketch mode flew a
  PERSPECTIVE camera onto the plane and drew the 2D canvas over it, which is an
  approximation that only holds at the centre of the screen: parallel lines
  converge, a square drawn off-centre renders as a trapezoid, and the model
  behind the canvas drifted out of register with the geometry drawn on top the
  further out you looked. The rig now switches to an ORTHOGRAPHIC projection
  sized so one world mm covers exactly `zoom` pixels — the same mapping
  `SketchView.world_to_screen` uses — so the two agree at every pixel rather
  than one. Model mode switches back to perspective on Finish, where depth cues
  are wanted. (`Camera3D.near` also dropped to 0.05 mm: an orthographic camera
  projects from -size/2, so a 1 mm near plane would slice through geometry when
  the eye sits close to the sketch plane.)

- **14 (step 21a — grid spacing popped between zoom levels)** — the spacing is
  chosen off a discrete 1/2/5 ladder, and only the chosen rung was ever drawn.
  Crossing a rung therefore added or removed every intermediate line on a
  single frame, which reads as a jarring snap while zooming. Blender solves it
  by drawing TWO adjacent levels and cross-fading, and so do we now:
  `SketchView.step_levels` reports the rung, the next finer rung, their ratio,
  and a `blend` that ramps 0 to 1 across the interval — on a LOG scale, because
  the ladder is multiplicative and the 2->5 gap is wider than 1->2, so a linear
  ramp would fade unevenly. Both surfaces draw the finer level at `blend`
  opacity beneath the settled one, so subdivisions arrive gradually and hit
  full strength precisely as the ladder hands over. The 3D grid does it in the
  shader (two `line_cover` evaluations); the 2D canvas draws the fading level
  first, and skips it once it would be denser than a line per two pixels, where
  it is a grey wash rather than a grid.
  Two wiring details that would each have silently reinstated the pop: the
  blend changes continuously even when the rung does NOT, so `update_grid` can
  no longer early-out on an unchanged step; and setting `camera.size` does not
  emit the rig's `moved` signal, so sketch-mode zooms push the update directly.
  Measured across a zoom sweep, the intermediate lines climb 49 -> 54 -> 59 in
  brightness rather than switching on. Regression test:
  `tests/m02_grid_fade.gd`, verified to FAIL without the cross-fade.

- **15 (step 21a — the cross-fade drew DOUBLED lines)** — fix **14** faded
  between adjacent rungs of the 1/2/5 ladder, which is wrong whenever the two
  levels do not nest. The 5 -> 2 rung has a ratio of 2.5, so a 127 mm coarse
  level ran against a 50.8 mm fine level: coarse lines at 127/254/381, fine at
  50.8/101.6/152.4. 101.6 and 127 land 25.4 mm apart, and at the zoom where
  that rung is active that is a few pixels — every line got a twin beside it.
  The fine level is now derived by SUBDIVIDING the coarse one (by 5 on the "5"
  rung, by 2 elsewhere) rather than by stepping down the ladder, so it always
  divides exactly and every fine line sits on a coarse line or evenly between
  them. Both divisors also land on real ladder values, so the fading lines
  still read as a measurement (1 in, 0.5 in) rather than an odd fraction.
  A second bug fell out of that and is worth recording separately: the fade
  interval and the subdivision ratio are NOT the same number. The rung is
  active across a 2 or 2.5 span, while the subdivision is 2 or 5; measuring the
  first against the second left the fade only ~56% complete at handover, so
  44% of it still popped. `blend` now uses the rung span, `ratio` the
  subdivision.
  Regression test: `tests/m02_grid_align.gd` asserts the levels nest exactly
  (every coarse line has a fine line ON it) and is verified to FAIL on the 2.5
  ratio; `tests/m02_grid_fade.gd` continues to guard the handover.
  Two wrong turns on the way, recorded so they are not retried: rounding the
  2.5 ratio to 3 makes it an integer but divides an inch into thirds, and
  eyeballing "tight gaps" in a scanline cannot tell a doubled line from normal
  perspective compression at a grazing angle — the geometric nesting property
  is what actually distinguishes them.

Regression test: `tests/m02_qa_fixes.gd` covers the cube's world isolation,
the plane gate + browser override, body pick/select/hide, the shared
background, the camera view round-trip, the grid's plane tracking, density
ladder, and toggle, the boot-time cube sync, the fixed grid span, and
reference-sketch rendering.

## §M3 — Automation API

Status: PENDING sign-off

- [x] 1. Launch `godot --path . -- --automation-port=4777`, then run
   `python3 tests/rpc/demo_tour.py`. **Expect:** the app visibly orbits,
   zooms, clicks "Create Sketch", clicks a plane, pans around the sketch,
   finishes the sketch — all with smooth, human-looking pointer motion; the
   script prints the timeline at the end.
- [X] 2. While the app is open with the server on, run
   `python3 tests/rpc/test_shell.py` (ECHOCAD_PORT=4777). **Expect:** all
   checks print `ok`, app quits itself at the end. **Issue:** two checks fail
   and the run aborts:
   ```
   FAIL  clicking a plane enters sketch mode
   FAIL  Sketch1 feature created
   client.RpcError: bad_state: not in sketch mode
   ```
   Fixed — see fix log **1**.
- [x] 3. Launch WITHOUT `--automation-port`. **Expect:** no server, no listening
   port, app behaves normally.

Fix log:
- **1 (step 2 — plane click misses)** — the test clicked the middle of the
  window with the comment "the XY plane fills the view center at the home
  camera". That stopped being true when the origin planes became
  positive-quadrant quads with their corner ON the origin (M2 fix 2
  follow-up): window centre now projects onto the world origin, which is the
  shared *corner* of all three quads — a knife-edge that the `0..PLANE_SIDE`
  hit test rejects as often as it accepts. Rather than hardcode a new pixel
  (the same trap again), the server gained `query.plane_point`, which projects
  a point given in a named origin plane's own u/v mm coordinates to screen
  pixels. The test now asks for the middle of the XY quad
  (`u = v = PLANE_SIDE/2`) and clicks that, so it keeps working through any
  future camera-home or plane-size change.

**DECIDED (policy): stop investing in human-like automation.** Testing effort
goes to plain API tests from here on. The human-like path did earn its keep
twice — it found the M10 flow-container bug (buttons past 1280 px unreachable;
the handler was fine, only the *route* to it was broken) and this section's own
plane-click regression — but both are input-routing bugs, and paying for a slow,
timing-sensitive suite to catch that class occasionally is a bad trade. API
tests are cheaper, deterministic, and give far better failure messages.

Consequences, so this is not re-litigated later:
- `tests/rpc/*.py` stay as they are and keep running; they are already written
  and they pass. They are not to be extended with new click-driven flows.
- New coverage goes to `tests/*.gd` (headless, direct) or to `action.*`/
  `query.*` RPC calls, never to synthetic pointer paths.
- `demo_tour.py` survives as a demo, not a test.
- The gap this accepts: nothing automatically checks that a control is
  reachable and hit-testable at a given window size. Manual QA covers it, which
  is what the M10 entry's step 6 is for.

## §M4 — Line tool, snapping, inference

Status: PENDING sign-off

- [x] 1. Enter a sketch. **Expect:** toolbar shows Select / Line / Point; Select
   active; status bar shows cursor coordinates in inches as you move.
- [x] 2. Press L, click, move roughly horizontally. **Expect:** rubber-band line;
   when within ~4° of horizontal it locks flat and a green "H" glyph shows.
- [x] 3. Click to commit, continue near-vertical, click. **Expect:** "V" glyph and
   lock; chain continues from each committed point.
- [x] 4. Hover an existing endpoint. **Expect:** green square marker; clicking
   there ends the segment exactly on that point (creates a Coincident
   constraint — verify via `query.constraints` or later the badge UI).
- [X] 5. Press Esc. **Expect:** chain ends; further clicks start a new chain.
   Esc after only one click leaves no debris (no lone point). **Expect (new):**
   Esc also drops back to the Select tool, Fusion-style. **Issue:** the chain
   ended but the Line tool stayed armed. Fixed — see fix log **2**.
- [x] 6. Ctrl+Z repeatedly. **Expect:** one segment removed per undo.
- [X] 7. Toggle grid snap off with the **Snap** checkbox in the sketch tool bar,
   draw. **Expect:** free placement; with it on, endpoints stick to grid
   intersections. (**Infer** next to it toggles H/V inference the same way.)
   **Issue:** the only way to toggle it was `action.set_pref` over RPC — no UI,
   so this was unverifiable by hand. Fixed — see fix log **3**.
- [x] 8. Point tool (P): click places a point marker (cross preview, square dot).
- [x] 9. Select tool (V): click a line — it highlights yellow with its endpoints;
   drag an endpoint — geometry follows, one undo step per drag; Esc clears
   the selection.
- [x] 10. Draw a rough rectangle of 4 chained segments closing on the start
    point. **Expect:** closing click snaps to the start point and ends the
    chain automatically.
- [X] 11. Draw a line. Start a SECOND line by clicking exactly on the first
    line's endpoint (green square shows), draw away, commit. Now drag that
    shared endpoint with Select. **Expect:** BOTH lines follow it — they share
    one point. **Issue:** they came apart. Two separate points were created
    and merely tied by a Coincident constraint, and the chain's *first* click
    was never constrained at all. Fixed — see fix log **1**.
    **Second issue:** ending a line on another line's EDGE (not its endpoint)
    made no constraint at all — the join was cosmetic and separated as soon as
    anything moved. Fixed — see fix log **4**.
- [X] 12. Repeat step 11 but join to a MIDPOINT snap instead of an endpoint.
    **Expect:** the new endpoint stays on that line's midpoint as the line
    moves (a Midpoint constraint, not a weld — there is no point there to
    share).
    **Issue:** the snap positioned the endpoint but created no constraint, so
    the midpoint join broke on the first move. Fixed — see fix log **4**.

Fix log:
- Removed window stretch (canvas_items) — precise automation clicks and UI
  now share one pixel space; desktop CAD UI should not scale anyway.
- **1 (step 11 — endpoints not welded)** — `LineTool._commit_segment` always
  minted a fresh `SketchPoint` for the new endpoint and, when the click had
  snapped to an existing point, added a Coincident constraint between the two.
  That is not a weld: it leaves two independent points that only *tend* to
  agree, and they visibly separate under a drag (the drag pins one of them, so
  the solver moves the other and the constraint fights the pin). The chain's
  first click was worse — a comment conceded it was "applied through position
  only", i.e. no constraint whatsoever. Both now **reuse the snapped point's
  id** outright: no new entity, no constraint, one point genuinely shared by
  both lines, exactly as Fusion does. The Coincident-constraint path remains
  only for snaps where there is no point to share.
- **2 (step 5 — Esc leaves the tool armed)** — `AppRoot.handle_app_key`
  forwarded Esc to the active tool and stopped once the tool consumed it.
  Tools that end a gesture on Esc therefore stayed active. Esc now falls
  through to Select whenever the active tool is a *drawing* tool, matching
  Fusion; Select's own Esc still just clears the selection, so repeated Esc
  does not cycle.
- **4 (steps 11/12 — edge and midpoint snaps made no constraint)** — welding
  (fix **1**) covered a click on an existing POINT, but the snap engine reports
  two other entity snaps and `LineTool` used only their POSITION: a line ended
  on another line's edge, or on its midpoint, looked joined and came apart the
  instant either line moved, because nothing recorded the relationship. A snap
  the user SAW must become a constraint — the same principle welding follows.
  An on-curve snap now adds POINT_ON (the endpoint slides along that entity but
  never leaves it) and a midpoint snap adds MIDPOINT. Both constraint types
  already existed in the solver; nothing was creating them. Skipped when the
  endpoint welded, since it is then already tied to real geometry and a second
  rule would only fight the first. Verified by dragging the base line and
  measuring the join: it stays 0.0007 mm off the line instead of separating.
- **3 (step 7 — no way to toggle snapping)** — added "Snap" and "Infer"
  checkboxes to the sketch tool bar, bound to the same `app.prefs` entries
  `action.set_pref` already wrote, so the hand path and the RPC path share one
  state.

## §M5 — Rectangle + circle

Status: PENDING sign-off

- [x] 1. Rectangle (R): click two corners. **Expect:** live preview; result is 4
   lines with shared corner points; top/bottom horizontal, sides vertical
   (drag a corner later with Select — shape shears only as constraints
   allow once the solver lands).
- [x] 2. While the second corner rubber-bands, W/H boxes follow the cursor
   showing live sizes in inches; type `2`, Tab, `1`, Enter. **Expect:**
   exact 2in x 1in rectangle; typed field highlights while active.
- [x] 3. Center Rect: first click is the center (cross marker), second a corner;
   typed W/H are FULL sizes centered on the first click.
- [x] 4. Circle (C): click center, move (live R readout), type `0.5`, Enter.
   **Expect:** exact 0.5in radius. Or click the rim to size by eye.
- [x] 5. 3-Pt Circle: click three points; after the second, the preview circle
   passes through both picks and the cursor. Collinear third click is
   refused (no commit).
- [x] 6. Esc mid-shape cancels with no debris; one undo step per finished shape.
- [x] 7. Unit suffixes work in fields: `10mm`, `1.5in`.

Fix log:
- (none yet)

## §M6 — Arcs + constraint solver

Status: PENDING sign-off

- [x] 1. 3-Pt Arc (A): click start, end, then a bulge point — preview follows the
   third pick, arc lands through all three. Winding matches the bulge side.
- [x] 2. Center Arc: click center, click start (radius locks), sweep the cursor —
   the preview follows the direction you wind, past 180° if you keep going;
   third click commits.
- [x] 3. Tangent Arc: first click must land on a line ENDPOINT (green square when
   snapped); the preview arc always leaves tangent to the line; second
   click commits. Result carries Tangent + Coincident constraints.
- [X] 4. Select tool: drag the free end of a line that has a tangent arc — the
   arc's start follows (coincident) and tangency re-solves live during the
   drag. Ctrl+Z once reverts the entire drag (drag + re-solve = one step).
   **Issue:** the arc grows without bound, the app lags hard, and the lag
   PERSISTS after deleting the offending arc — only a restart clears it.
   Still broken after the first pass: a perfectly-built tangent arc, dragged a
   few pixels, threw the whole drawing apart. Fixed — see fix log **2**
   (explosion), **3** (persistent lag) and **2b** (the real cause), then
   **2c** — the arc's FAR end was still unconstrained, so closing it onto
   existing geometry looked joined but came apart on the first move.
- [x] 5. Drag an arc endpoint: the opposite endpoint keeps the same radius (arc
   implicit coupling), no kinks or explosions.
- [X] 6. Over-constrain something (e.g. two different distances between the same
   points via RPC): geometry stays bounded, no vibrating explosion.
   **Expect (new):** the redundant dimension is reported as *driven* and the
   user is told. **Issue:** it stayed bounded (good) but nothing told the user
   which constraint was redundant or that it had stopped driving. Fixed —
   see fix log **4**.
- [x] 7. `query.dof` over RPC reports sensible numbers ("N DOF remaining" /
   "Fully constrained") and lists conflicts when you create one. (Yes — the
   readout on the right of the status bar is exactly this; RPC and status bar
   read the same `DofAnalyzer` result.)
- [~] 8. Watch CPU load while dragging geometry with constraints. **Expect:** one
   solve per rendered frame at most; no core pegged. **Issue:** one core
   saturated and CPU temperature rose ~20 °C during sustained drags. Fixed —
   see fix log **1**.
    Re-measured: moving a line takes total load 3%->7% and 59C->76C, with one
    core near maximum. Better than before but still one core saturated — the
    solve is synchronous on the main thread, which is **M16**.
- [X] 9. Dimension a point to the sketch ORIGIN and fully constrain a shape.
   **Expect:** the origin is a real, snappable, selectable point at (0,0) that
   dimensions and constraints can reference, as in Fusion. **Issue:** no such
   entity existed — the origin was only painted axes, so nothing could ever
   reach "Fully constrained". Fixed — see fix log **5**.
   **Second issue:** a FULLY CONSTRAINED shape could still be dragged, which
   mangled it and left the status bar reading "Conflicting constraints" when
   the user had done nothing wrong. Fixed — see fix log **7**.
- [X] 10. With Select (or Dimension, or any tool that picks) active, hover a
    line, then a point. **Expect:** Fusion-style pre-highlight — whatever is
    under the cursor and would be picked brightens and thickens. **Issue:**
    no hover feedback at all; you only learned what you hit after clicking.
    Fixed — see fix log **6**, then **6b** (points, and every picking tool),
   then **6c** — the point highlight was drawn UNDER the point marker, so it
   was invisible however correct the hit test was.
- [~] 11. Drag a large, heavily constrained sketch (100+ constrained entities).
    **Expect:** interactive. **Deferred:** the solver is single-threaded and
    fix **1** only removes the *wasted* work; moving the solve to a worker
    thread as `echo_vector` does is written up as **M16 — Threaded solver**.

Fix log:
- Snap-index rebuilds triggered mid-drag by command pushes were clobbering
  the gesture's self-exclusion, so a dragged point could snap back to its
  own origin and collapse the undo batch. Exclusions now persist until the
  gesture ends.
- **2b (step 4 — the REAL cause: the arc was never welded to the line)** —
  fixes **2** and **3** bounded the damage but did not stop it: a tangent arc
  built perfectly tangent (error 0.00000) still had its centre thrown **1.7 m**
  by a 5 mm drag, ending up LESS tangent than it started. Reproducing it
  through the real tools rather than a hand-built fixture is what exposed it —
  the hand-built one started 13 mm out of tangency, so the solver's large
  corrections there were correct and the reproduction was lying.

  The tangent arc tool minted a NEW point for the arc's start and tied it to
  the line's endpoint with a COINCIDENT — the same non-weld the line tool had
  in M4. Three rules then took turns undoing each other every round: the
  tangency projection moved the arc's centre to close its gap; the solver's
  rigid ride-along carried the rim along with the centre, reopening the gap by
  exactly the amount just corrected; and the Coincident hauled the twin back.
  The system was unsatisfiable by construction, so it never converged (200
  rounds every time) and pushed harder each round.

  Four changes, in the order they were found:
  1. **The tangent arc tool now WELDS** its start onto the line's endpoint —
     one shared point, no twin, no Coincident. There is nothing left to
     reconcile.
  2. **Anchored rims do not ride along.** A rim another entity holds — by a
     Coincident, or by being shared outright — is not free to be translated as
     a side effect of the centre moving. Keying this on Coincident alone
     missed every *welded* rim, which is now the common case; it keys on
     sharing too.
  3. **One-end-held only.** An arc with BOTH rims shared (a slot's end cap) is
     meant to ride rigidly — that is how driving a slot's length preserves its
     width — so only the one-end-held case is anchored. Getting this wrong
     broke `tests/m09_slot.gd`, which is what caught it.
  4. **Tangency now rotates the arc about the weld point** instead of sliding
     the centre along the normal. The radius IS the centre-to-rim distance, so
     translating the centre changes the radius, changes the error, and asks
     for another translation — the centre marches off while the error
     converges to the radius rather than to zero. Rotating preserves the
     radius exactly. Resizing the arc dropped to a last resort (used only when
     the centre is pinned) because shrinking an arc to a point satisfies
     tangency trivially, and the solver was happily collapsing a 59 mm arc to
     0.001 mm and calling it solved.

  Verified against hand-computed geometry: the centre now tracks
  (17.7, 76.0) → (11.5, 77.6) over an 8 mm drag, exactly the analytic answer,
  with tangency at 0.00000, the radius steady at 58.7, and the solve
  converging in ~10 rounds instead of burning all 200.
  Regression test: `tests/m06_tangent_drag.gd`.
- **6b (step 10 — hover only worked for lines, only in Select)** — the hover
  pass had no `"point"` case, so hovering a point drew nothing (points are
  drawn as small squares, and an outline traced ON one is invisible — they now
  get a ring instead). And the overlay asked the Select tool specifically for
  its hover, so no other tool could ever show one. `hover_id` moved onto the
  base `SketchTool` with a shared `update_hover` helper, and the overlay reads
  it from whichever tool is ACTIVE, so Dimension — and any picking tool added
  later — pre-highlights without further work.
- **7 (step 9 — a fully constrained shape could still be dragged)** — nothing
  checked whether the points under the cursor were already determined, so the
  drag and the dimensions each demanded a different position, the solver was
  handed a system with no solution, and the sketch came apart while the status
  bar blamed the user with "Conflicting constraints". `SelectTool` now refuses
  the gesture when every point it would move is in the DOF analysis's
  `constrained_points` — the same set the status bar reports, so what blocks a
  drag is exactly what the user was told is fully constrained — and says why.
  Status hints also became sticky for a few seconds (`HINT_HOLD_MS`), because
  the live cursor readout previously overwrote any such message on the very
  next mouse move, making a refusal look like nothing had happened.
- **2c (step 4 — the arc's FAR end was never constrained)** — fix **2b** welded
  the arc's START onto the line endpoint it launches from, but `_commit` still
  minted a fresh, unconstrained point for the closing end and used only the
  POSITION of the second click's snap. So an arc closed onto existing geometry
  sat exactly on top of it and was attached to nothing: move either piece and
  they parted. The closing click now welds the same way the opening one does.
- **6c (step 10 — the point highlight was drawn underneath the point)** — the
  hit test was right all along (verified directly: hovering an endpoint returns
  its id), but the overlay drew the hover pass BEFORE the point markers, so the
  5 px marker painted straight over the highlight and hovering a point appeared
  to do nothing. The highlight is now a larger FILLED square drawn first, with
  the marker on top — the point visibly grows and brightens, and the marker
  stays crisp inside it. A thin ring at hover's half-alpha was tried first and
  read as noise around so small a target.
- **1 (step 8 — one core pegged while dragging)** — `SelectTool.pointer_move`
  ran the full pipeline on **every mouse-motion event**, and motion events
  arrive far faster than frames: push `CmdMovePoints`, which fires
  `stack.changed`, which rebuilds the snap index, re-runs `DofAnalyzer`, and
  re-rasterizes the whole canvas — then `solve_followers` ran
  `ConstraintSolver.solve` (up to `MAX_ROUNDS` = 200 sweeps over every
  constraint) on top. Several such pipelines per displayed frame is the
  entire cost, and all of it past the first is thrown away. Drag updates now
  **coalesce to one per frame**: `pointer_move` records the target and
  requests a flush, and the flush runs once in `_process`. Same visual
  result, same undo semantics (still one sealed batch), a fraction of the
  work. The solver itself was left alone — it is not the bug, its call rate
  was.
- **2 (step 4 — tangent arc explodes)** — reproduced in isolation first: one
  drag of a line whose endpoint is coincident with a tangent arc's start took
  the radius from 20 mm to **13.4 million mm**. Three things were wrong, and
  the first two guesses about it were wrong too, so the sequence is worth
  recording:
  1. The arc's radius is *implied* by center-to-rim distance, so it grows with
     no radius projection running at all. The tangency pushes the CENTER away
     each round while the coincidence holds the rim on the dragged geometry.
     A guard that clamped rim points therefore did nothing — the rim is the
     pinned end in exactly this case. The clamp now pulls whichever end is
     free, preferring the center.
  2. A drag is not one solve, it is one solve per frame, each re-anchored to
     the last result — so any per-solve growth factor `f` compounds to `f^n`.
     A "safe-looking" 3× became 3^40 within a single gesture. `MAX_RADIUS_GROWTH`
     is now a deliberate rate limit (2.0 — the smallest value that still lets
     `tests/m06_arc_tools.gd`'s legitimate tangent-arc drag re-solve), which
     bounds how fast divergence can show up but is explicitly NOT the hard stop.
  3. The hard stop is new: `solve` now sanity-checks its own result and
     **discards the whole solve** when any coordinate is non-finite or beyond a
     generous multiple of the sketch's own reach. A stiff, unsatisfiable system
     can still go numerically unstable in a single round no matter how each
     projection is damped; refusing that result costs one frame's re-solve and
     leaves the geometry where it was, which is the honest outcome when the
     constraints cannot all be met. `_tangent_line_circle`'s radius pathway also
     picked up the standard `RELAX` damping while here.

  Measured after: the same 14-drag abuse run that produced a 799 mm radius
  leaves it at **24 mm**, and the app stays responsive throughout (see fix
  **3** for why the lag used to outlive the arc).
- **3 (step 4 — lag persists after deleting the arc)** — the runaway radius
  reached values whose screen-space arc spanned millions of pixels;
  `RenderBridge` tessellates arcs for ThorVG and `AppRoot._draw_selected_entity`
  called `draw_arc` on it, so each frame built an enormous path. That part
  ends when the arc is deleted. What did NOT end: `ImmediateMesh` grid
  rebuilds and the ThorVG canvas kept the last, vast view box, so every
  subsequent render still worked at that scale. Both are now bounded — the
  canvas view box is clamped to the zoom limits, and the arc tessellation
  segment count is capped by on-screen radius rather than growing with it.
  With fix **2** the radius no longer explodes in the first place; this is
  the belt-and-braces half, so any future divergence degrades gracefully
  instead of poisoning the session.
- **4 (step 6 — redundant constraints should say so)** — `DofAnalyzer`
  already distinguished redundant from conflicting rows, but nothing surfaced
  it. Redundant *dimensional* constraints are now auto-marked `driven` when
  they are created into an already-determined system: they measure and
  display in parentheses instead of fighting, exactly as step 7 of §M8
  specifies, and the status bar says which one was demoted and why.
- **5 (step 9 — no origin point)** — every `Sketch` now owns an immutable
  origin `SketchPoint` at (0,0), minted at construction and restored on load
  (older files gain one on open). It is pinned in the solver the way a FIX
  operand is, is offered by the snap engine like any other point, and is
  selectable, so distances and constraints can reference it and a shape can
  actually reach "Fully constrained". It cannot be deleted or dragged.
- **6 (step 10 — no hover pre-highlight)** — `SelectTool` only hit-tested on
  click. It now hit-tests on motion too, storing the entity under the cursor,
  and the overlay draws that entity thicker and brighter beneath the selection
  pass (selection still wins where both apply). The hit test is the same
  `SketchGeometry.entity_at` the click uses, so what pre-highlights is exactly
  what a click would pick.

## §M7 — Constraint palette + DOF UI

Status: PENDING sign-off

- [X] 1. In a sketch, the constraint bar shows Coincident/H/V/Parallel/
   Perpendicular/Collinear/Equal/Midpoint/Concentric/Tangent/PointOn/Fix/
   Symmetry. With nothing (or the wrong things) selected, clicking one
   prints a reason in the status bar ("Cannot apply: needs two lines").
- [~] 2. Ctrl-click two lines, click Parallel. **Expect:** lines rotate to
   parallel; a ∥ badge appears near each... (badge sits by the operands'
   midpoint); one Ctrl+Z undoes constraint + motion together.
    **Issue A:** one badge appeared between the two lines instead of one on
    each (same for Equal and every other multi-operand constraint). Fixed —
    see fix log **2**.
    **Issue B:** Shift did not extend a selection, only Ctrl did. Fixed — see
    fix log **3**.
    **Issue C (OPEN):** dragging one of two parallel lines rotates and moves
    the other, including its unselected endpoint. Fusion instead refuses to
    let a drag change a rotation the constraints have fixed. This needs the
    solver to distinguish "this DOF is determined" per-degree rather than
    per-point, which the current whole-point check cannot express — written up
    as **M17 — Per-DOF drag refusal** in `docs/MILESTONES.md`.
- [X] 3. Constraint badges: green = satisfied, amber = redundant, red =
   conflicting. Click a badge to select it (yellow outline); Delete removes
   it; Esc deselects.
- [X] 4. Status bar shows "N DOF remaining"; it drops as you constrain. Fully
   constrain a line (Fix an endpoint + Horizontal + a Distance via RPC for
   now): the line and its points render GREEN and status reads "Fully
   constrained".
- [X] 5. Create a conflict (two different distances on the same pair): badges go
   red, status reads "Conflicting constraints"; geometry stays calm (no
   vibration). Deleting one distance clears it.
- [X] 6. Delete key with entities selected deletes them plus their constraints in
   one undo step; constraints referencing them vanish.
    **Issue:** deleting a line left its two endpoints behind as loose dots AND
    left any dimension on it alive on screen. Fixed — see fix log **4**.

Fix log:
- Conflict detection now flags every violated constraint once redundancy
  exists — the iterative solver satisfies whichever duplicate ran last, so
  the violated one is often NOT the redundant one.
- **2 (step 2 — one badge instead of one per operand)** — `anchor_of` averaged
  every operand into a single point, so a Parallel between two lines drew one
  glyph in the space BETWEEN them, visibly belonging to neither. Split into
  `anchors_of`, which returns one anchor per operand; the badge pass draws and
  hit-tests each, all mapping back to the same constraint index so clicking
  any one selects it. `anchor_of` stays for dimension labels, which genuinely
  do want a single point.
- **3 (step 2 — Shift did not multi-select)** — only Ctrl extended a
  selection. Ctrl-click is the CAD convention and Shift-click is the
  everything-else convention; both are now accepted, since users reach for
  whichever their hands know.
- **4 (step 6 — delete left debris and stale dimensions)** — deleting a line
  removed the line and pruned constraints that referenced IT, but a distance
  dimension references the two POINTS, not the line, so it survived and went
  on measuring geometry that no longer existed — and the endpoints themselves
  were left as loose dots. Deletion now also takes any point that would be
  left with nothing referencing it, which prunes the orphaned dimension as a
  consequence rather than as a special case. Points still used by surviving
  geometry (a shared corner, a welded joint) are explicitly kept, and the
  origin is never removed. Still one undo step.
  Regression test: `tests/m07_delete_badges.gd`, which covers the negative
  case too — deleting one of two welded lines must NOT take the shared point.

## §M8 — Dimensions + parameters

Status: PENDING sign-off

- [X] 1. Smart Dimension (D): click a line — a live dimension follows the cursor
   showing its length; click empty space to park it. Extension lines,
   dimension line with arrowheads, value chip at the parked spot.
- [X] 2. After parking, type `2` Enter — the line drives to exactly 2 in and the
   whole flow is ONE Ctrl+Z.
- [X] 3. Pick two points → distance; a circle → ⌀ diameter with leader; an arc →
   R radius; two angled lines → angle arc with degrees; two parallel lines
   → gap. Wrong combos just restart the pick. **Issue:** the angle ARC was
   drawn on the wrong side of the apex, so an angle dimension looked like it
   was measuring the reflex angle somewhere else. The constraint itself was
   always created correctly. Fixed — see fix log **2**.
- [X] 4. Select tool: drag a dimension label — it parks where you drop it (world-
   anchored: pans/zooms with the sketch); geometry never moves.
- [X] 5. Click a label to select it (yellow), type a new value, Enter — drives.
   `10mm` and `0.5in` suffixes work. Delete removes the dimension.
   **Issue:** typing a value and pressing Enter did nothing at all — the whole
   edit path was dead. Fixed — see fix log **3**.
- [~] 6. Expressions: type `width / 2` into a dimension after creating parameter
   `width` (RPC action.set_parameter for now) — label shows the formula;
   changing the parameter re-drives every dependent dimension and re-solves
   in one undo step. Typos ("wdith") are refused with a message, nothing
   changes. **Issue:** math operators were filtered out of the input field as
   you typed, so expressions could not be entered at all; and see step 5 for
   why nothing committed. Fixed — see fix log **3** and **4**. (Creating a
   parameter still needs `action.set_parameter` over RPC — a Parameters
   dialog is not built yet, so this step cannot be fully hand-verified.)
- [~] 7. Driven dimensions render in parentheses/grey and never move geometry.
    See earlier issues outlining this
- [X] 8. Dimension from a point to the sketch origin (see §M6 step 9).
   **Expect:** the origin behaves as any other point for dimensioning.

Fix log:
- SketchConstraint.make now copies its operand array — the smart dimension
  tool cleared a shared array on reset and gutted the stored constraint.
- **2 (step 3 — angle arc on the wrong side)** — `_angle` swept the arc between
  the two lines' stored p0->p1 directions. That is an authoring detail, not
  geometry: a line's stored direction may point back THROUGH the apex, and then
  the arc was drawn on the opposite side from the angle being dimensioned. The
  arms are now measured outward from the apex (toward whichever endpoint is
  further from it — the side the line visibly occupies), and the sweep takes
  the short way round.
- **3 (step 5 — editing an existing dimension did nothing)** — three separate
  faults stacked, which is why it looked completely untouched:
  1. `AppRoot.handle_app_key` intercepted ENTER and routed it straight to
     `tools.handle_commit()`, so the active tool's `key_input` — which is what
     applies a typed dimension value — never saw it. The digits were collected
     into the field and then silently discarded. Enter now offers itself to
     `key_input` first and only falls through to `handle_commit` if unused.
  2. `CadExpression.is_literal` accepted only a bare float, so "10mm" and
     "1.5in" were sent to the EXPRESSION evaluator, which read the suffix as a
     variable and refused the entry with "unknown name: mm". It now treats a
     unit-suffixed value as the literal it is.
  3. The canvas grabbed keyboard focus once, when the sketch opened. Clicking
     a toolbar button afterwards moved focus away and the canvas went deaf.
     Clicking the canvas now takes focus back.
  Regression test: `tests/m08_dim_edit.gd` drives a dimension through the real
  key-routing path with a bare number, both unit suffixes, and an expression.
- **4 (step 6 — math operators could not be typed)** — `DimFields.key_input`
  filtered keystrokes against the literal string "0123456789.-inmfct ", which
  has no `*`, `/`, `+`, `(` or `)`. Operators were swallowed as you typed, so
  "2*1.25" arrived as "21.25" — the field appeared to work while quietly
  mangling the input. The accepted set is now digits, operators and letters
  generally; whether the result means anything is the expression evaluator's
  judgement, not a keystroke filter's.

## §M9 — Slot tool

Status: PENDING sign-off

- [X] 1. Slot (S) — center-to-center: click two center points, move the cursor
   off-axis (live outline + W readout follows), click to set width. Result:
   two side lines + two end caps, tangent everywhere, no seams.
    Arcs facing wrong direction when drawing slot. when finalized arcs do appear in correct orientation. some constraints showing as orange, not sure if that's normal
- [X] 2. Type-in: after the two clicks, type `0.5` Enter for an exact 0.5 in
   width. Suffixes work.
- [X] 3. Slot (Overall): the two clicks are the OUTER extremes; caps inset so the
   total length matches the clicks.
- [X] 4. Slot (Center Pt): first click is the slot's midpoint, second an end
   center; the other end mirrors automatically.
- [X] 5. One Ctrl+Z removes the whole slot.
- [X] 6. Dimension the center distance (D, click both centers) and drive it —
   the slot stretches, width unchanged, caps stay tangent. Dimension an end
   arc radius — width drives. Drag a center with Select — the slot follows
   as a slot.
- [X] 7. Esc mid-placement leaves nothing behind.

Fix log:
- Solver: damped Gauss-Seidel (RELAX 0.6) + arc rims ride rigidly with
  their center each round + arc tangency gets a radius pathway — the slot's
  stiff constraint loop exploded (or collapsed its width) without these.
  (The radius pathway is what §M6 fix **2** had to bound; the slot case is
  covered by `tests/m09_slot.gd`, which now also asserts the bound.)
- **1** Live preview drew each end cap on the wrong half (A's cap bulged
  toward B and vice versa); the two screen-angle ranges were swapped in
  `SlotTool._draw_slot_preview`. Committed geometry was always correct.
- **1** Orange badges: that is the REDUNDANT colour, and for a slot it is
  expected — 4 tangencies + equal radii over-describe the shape (any three
  imply the fourth), so the DOF analyzer flags the surplus. Harmless; the
  constraints still hold. Not a bug.

## §M10 — Modify tools

Status: PENDING sign-off

- [X] 1. Trim (T): draw crossing geometry; hovering a piece highlights exactly
   the doomed span (red, thick) between its nearest intersections; click
   removes it. Lines split; a crossed circle becomes an arc; arcs shorten.
   One Ctrl+Z per trim.
    Does trim, but leaves vertex / point at end of line that was just trimmed
    Line that was crossed into another then trimmed so that new line endpoint lays on edge of the other line isn't constrained to the line, thus if we move the other line, this one gets disconnected
    When i do this now, it does add a constraint that keeps the lines together, but it seems that it auto adds two constraints, and now there is an over constraint. there should just be one instead. it creates two badges, and asa i move hte lines they go from red to green to red to green seemingly at random
- [X] 2. Extend (X): hover a line near the endpoint that faces other geometry —
   green preview shows the extension to the nearest hit; click applies.
    Does work, but as described above, line isn't constrained, so it isn't really attached to the line
    Same with above that it seems to over constraint the new junction

- [X] 3. Offset (O): click a line/circle/arc, move the cursor to choose side and
   distance (live preview), click or type `0.5` Enter for exact. Offset does seem to work, but no indication that 
    what's under mouse will be enabled for offset. must be like dimension where when tool is armed, whatever is under 
    the mouse grows in thickness to indicate and changes in color
    Also, unable to offset multiple lines / shapes at once. if geometry is selected (more than one line) then it should properly offset from that geometry, like what you'd expect in fusion or illustrator
- [X] 4. Mirror (M): select entities with V (Ctrl-click for several), press M,g
   click the axis line. Mirrored copies appear with live Symmetry
   constraints — drag an original point and the mirror follows.
    Seems to work when axis is another line, but no indication of what's happeneing like in above message. we also need to be able to click on origin axis, not just lines we place in the world
- [X] 5. Fillet (F): type a radius (or accept 0.25 in), click a sharp corner
   where exactly two lines meet: tangent arc replaces the corner, lines
   shorten to the tangency points, corner point disappears. Undo restores
   the sharp corner. Over-large radius refuses with a message.
    Adding a works if we click on a corner vertex. but adjusting the radius causes all geometry to move
- [X] 6. Tool rows wrap (flow) — every button stays reachable at any window
   width.

Fix log:
- Tool/constraint bars are flow containers now; a single row overflowed
  1280 px and made tail buttons unreachable (automation caught it — the
  Python client now refuses clicks outside the window instead of silently
  missing).
- **1** Trim no longer sheds debris: endpoints of the trimmed entity that
  nothing references any more are deleted in the same undo step, and
  circle/arc trims REUSE the original center point instead of minting a
  duplicate and stranding the old one.
- **1/2** Trim and Extend now constrain the new/moved endpoint onto the
  entity it landed on (POINT_ON), so the joint survives dragging the other
  line. (`tests/m10_qa_fixes.gd`)
- **1/2 round 2** The "two constraints / over-constrained / badges flip
  red-green" junction had three roots, all fixed:
  (a) Extend re-applied at an already-tied junction added a DUPLICATE
  POINT_ON — the redundant copy is what made the analyzer flag violations
  during drags. Extend now skips the tie when the tip is already tied or
  welded to the hit entity.
  (b) Trimming the OTHER line of a junction deleted it and PRUNED the
  first trim's POINT_ON with it — the joint silently unhooked. POINT_ONs
  now retarget onto whichever kept piece the point lies on.
  (c) T-joints were invisible to trim: the solver leaves the touching
  endpoint ~0.0005 mm off the line, the exact segment intersection missed
  it, and trim deleted the WHOLE line instead of cutting at the junction.
  Trim now also counts another entity's endpoint within 0.02 mm as a cut.
- **3** Offset pre-highlights what a click would pick (same amber hover as
  Select/Dimension; points excluded). A multi-entity selection made with V
  now offsets as a CHAIN: one distance, one side, shared corners
  re-intersected, tangent line/arc joints preserved, offset arcs/circles
  share the source's center point (concentric by construction).
- **4** Mirror pre-highlights the axis line under the cursor, and the
  ORIGIN X/Y axes are now clickable as the axis: a pinned construction
  line is created along the axis (same undo step) so the SYMMETRY
  constraints stay live.
- **5** Driving a fillet's radius dimension re-solved by pushing the rims
  radially off their lines, and the tangency corrections then rippled
  through everything — the whole sketch drifted. The solver now recognises
  the fillet pattern (each rim welded to its own non-parallel line) and
  solves the radius change analytically: rims slide ALONG the lines to the
  new tangency points, the center re-seats on the corner bisector, far
  geometry does not move. Parallel-line arcs (slot caps) keep the old
  pathway, which is what preserves slot behaviour.
- **5 round 2** (triangle screenshots) Driving 0.25 in -> 1 in still
  collapsed the sketch. Three more solver causes:
  (a) the anti-runaway radius ceiling (2x entry radius per solve) clamped
  a legitimate 4x dimension jump, yanking the centre back every round —
  the ceiling now grows to cover an explicit driving radius/diameter
  dimension;
  (b) the arc's equal-radius coupling pushed the fillet's rims radially
  OFF their lines — with both rims welded to lines it now moves the
  CENTRE onto the rims' perpendicular bisector instead;
  (c) a radius too large for the legs pushed a rim PAST the line's far
  end, inverting the line and flipping the corner every round — the rim
  now stops just short of the far end, so the radius tops out at what the
  lines can carry and geometry stays sane (dimension reads unsatisfied
  instead of destroying the sketch).

## §M11 — Timeline

Status: PENDING sign-off

- [X] 1. The timeline bar (above the status bar) shows one chip per feature in
   order, with the ‖ rollback marker after the last.
- [X] 2. Create two sketches with content. Drag the marker left of Sketch2 —
   Sketch2's geometry vanishes from the 3D view and its chip dims to
   "(Sketch2)". Drag back — it returns. One Ctrl+Z per drag.
- [X] 3. With the marker rolled back, Create Sketch inserts the new feature AT
   the marker; downstream features shift right and stay rolled back.
- [X] 4. Right-click a chip: Edit Sketch / Suppress / Delete. Suppress dims the
   chip and hides the geometry without moving the marker; all three are
   undoable.
- [X] 5. Double-click a sketch chip to edit it; Finish returns to model mode
   with edits applied.
- [X] 6. Save, reopen: order, marker position, and suppressed flags survive.
    No file save system currently in place

Fix log:
- **6** Save/Open now exist in the UI: Save + Open buttons in the top bar,
  Ctrl+S (save, or Save-As dialog when the document has no path yet),
  Ctrl+Shift+S (always Save As), Ctrl+O (open). Files are `.ecad` via the
  existing Serializer; opening replaces the document and clears history.
  Round trip covered by `tests/m10_qa_fixes.gd`.

## §M12 — Extrude

Status: PENDING sign-off

- [X] 1. Sketch a closed rectangle on XY, Finish, click Extrude, then click
   inside the rectangle in the 3D view. **Expect:** a distance dialog;
   type `1in`, OK — a shaded solid appears; Extrude1 lands on the timeline
   after Sketch1.
- [X] 2. Orbit around the solid: caps and walls shaded correctly, no missing
   faces at any angle.
    Caps are present, but there's no colored edges, so impoissible to tell what the shape is. also there's no shading, so model looks all exact same color. no depth clues
    Now the 3d model is transparent. makes it hard to determine what faces we're looking at. 
- [!] 3. Open profiles and empty space refuse the pick (status hint keeps
   asking); Esc cancels picking.
    Don't know what that is
- [X] 4. Edit Sketch1 (double-click its chip), drive the rectangle wider, Finish.
   **Expect:** the solid updates to the new profile (replay).
- [X] 5. Drag the timeline marker before Extrude1 — the solid vanishes; back —
   it returns. Ctrl+Z after creating an extrude removes it.
- [X] 6. A circle extrudes to a cylinder. Triangle to a prism.
- [X] 7. Save/reopen: solids rebuild identically.
    No current way in ui to save / load


Fix log:
- **2** The extrude mesh carried no normal array, so lighting had nothing
  to shade by and the solid rendered one flat tone. Flat per-face normals
  added, and a second PRIMITIVE_LINES surface draws dark edge lines (cap
  outlines + wall edges at sharp profile corners — smooth circle walls get
  no fake seams), so the silhouette reads at any angle. Bodies now use
  per-surface materials instead of `material_override`.
- **2 round 2** "Now the 3D model is transparent" — two separate causes,
  both fixed (verified by screenshot):
  (a) the ground grid and origin axes rendered with `no_depth_test`, so
  they painted straight OVER solids — grid lines through a body read as
  transparency. The grid now depth-tests (still never writes depth) and
  sits 0.05 mm below its plane so coplanar axes/sketch lines still win;
  the axes are plain depth-tested lines again and hide behind solids.
  (b) a CLOCKWISE profile polygon turned every extrude face INWARD —
  front faces were back-face-culled and you saw the shell's interior
  ("inverted normals"). `build_mesh` now normalizes the profile to CCW,
  and a NEGATIVE distance (extrude below the plane) mirrors the windings
  too instead of building inside-out. Audited numerically: signed volume
  positive + every face normal outward on all three planes, both
  windings, both distance signs (`tests/m10_qa_fixes.gd`), and verified
  by orbiting screenshots from above, below, and behind.
- **2 round 3** Reported again from a running instance. The full UI path
  (plane pick -> rect tool, both click orders and quadrants -> profile
  click -> distance dialog, +/-, all three planes: 15 cases) audits
  outward in the current build, so the sighting matched a stale app
  instance launched mid-fix (Godot never hot-reloads scripts). Two
  belt-and-braces changes so it cannot present again and stale builds are
  obvious: body materials are now DOUBLE-SIDED (a closed outward shell
  hides the back faces via depth anyway, so this is free — but a solid
  can never render see-through even with a reversed winding), and the
  window title now carries a build stamp (`AppRoot.BUILD`, currently
  2026-08-16-r4) — check the title bar to confirm which build a window
  is running.
- **3** Not a bug — clarification: an "open profile" is a loop that does
  not close (e.g. three sides of a rectangle). Extrude's profile pick must
  refuse clicks there and in empty space; the status bar keeps asking for
  a closed profile until Esc.
- **7** Save/Open UI added — see §M11 fix **6**.

## §M14 — Orbitable sketch view

Status: PENDING sign-off

- [X] 1. Enter a sketch (any plane), draw a rectangle, pan/zoom somewhere
   deliberate. Shift+MMB drag. **Expect:** the view orbits away from the
   plane; the sketch renders as lines in 3D on its plane; the toolbar and
   constraint bar disappear; the status bar says how to get back.
- [X] 2. While off-axis: tool shortcuts (L, D...) and Delete do nothing;
   LMB clicks create nothing; plain MMB pans, wheel zooms, Shift+MMB keeps
   orbiting.
- [X] 3. Ctrl+Z / Ctrl+Shift+Z while off-axis: the 3D sketch lines update in
   place; the app stays off-axis in the sketch.
- [X] 4. Click the sketch plane's face on the view cube. **Expect:** the
   camera flies back square onto the plane (reads as a fly-back, not a
   snap) and the 2D canvas returns at the exact pan/zoom you left.
- [X] 5. Orbit away again, click a DIFFERENT cube face: the view reorients
   but stays off-axis. Esc flies home like the plane face does.
- [X] 6. Grid/axes stay legible at grazing angles while off-axis.
- [X] 7. Finish Sketch while off-axis returns to model mode cleanly.

Fix log:
- **note ("tools should work off-axis")** Implemented — Fusion's workflow.
  Off-axis, the toolbar and constraint bar stay up, tool shortcuts work, and
  clicks ray-cast onto the ORIGINAL sketch plane, so geometry, dimensions and
  constraints all land in the sketch exactly as they would square-on. The
  canvas stays hidden (the sketch renders as 3D lines, chrome via the
  overlay); Esc first cancels the active tool gesture, and only returns to
  the locked view when there is nothing left to cancel. Item 2's "tools do
  nothing" behaviour is obsolete — retest with item 8.
- [ ] 8. While off-axis: press L, click twice on the plane — a line lands at
   those plane points; D + two picks places a dimension; Delete removes a
   selected entity; Esc mid-gesture cancels the tool (staying off-axis),
   Esc again flies home. Geometry drawn off-axis is exactly where the
   locked 2D view shows it after returning.

## §M15 — Project / reference geometry

Status: PENDING sign-off

- [X] 1. Sketch a rectangle on XY, Finish. New sketch on XY — the rectangle
   shows dimmed. Click Project, hover the dimmed edges. **Expect:** amber
   pre-highlight on the edge a click would take.
- [X] 2. Click an edge. **Expect:** a magenta copy appears in the active
   sketch (2 points + line); one Ctrl+Z removes all of it. Clicking the
   same edge again is refused with a status message.
- [X] 3. Project the adjoining edge: the shared corner is ONE point, not two.
- [X] 4. Projected geometry snaps: start a line on a projected corner — it
   welds; dimension from a projected point works.
- [X] 5. Projected points read as constrained (no DOF added); dragging a
   projected point refuses to move it.
- [X] 6. Finish. Edit the source sketch, drag a corner, Finish. **Expect:**
   the projection in the other sketch follows the source.
- [X] 7. Edit the source and delete the projected edge, Finish. **Expect:**
   status message says the link broke; the projected copy stays as
   ordinary (blue) geometry; no crash.
- [X] 8. Project all 4 edges into a sketch, Finish, Extrude inside the
   projected rectangle: the profile is found and extrudes.
- [X] 9. Save, reopen: projections still linked (edit source → copy follows).

## §M16 — Threaded solver

Status: PENDING sign-off

- [~] 1. Build a heavily constrained sketch (100+ entities: rects, slots,
   fillets, dimensions). Drag an under-constrained point around fast.
   **Expect:** the drag stays interactive — no stutter, no rubber-banding
   lag; CPU load spread across cores rather than one pegged.
    One core still pegged, and temp rose 20c when moving one line
- [X] 2. Release the drag mid-motion. **Expect:** geometry lands exactly
   where the cursor let go (final solve is exact), constraints hold.
- [X] 3. One Ctrl+Z reverts the entire drag including all re-solves.
- [X] 4. Drag a tangent-arc construction and a slot: tangency and
   slot-shape survive fast dragging, same as before the threading.

Fix log:
- **1** ("one core still pegged, +20 °C moving one line") The heat was not
  the solver — that already ran on the worker thread — but the per-frame
  DERIVED work each stack change triggered: a full DOF analysis (an O(n^3)
  Jacobian rank pass over every constraint) plus the projection refresh, on
  every pointer frame of the drag. Both are now deferred while a gesture is
  streaming (`AppRoot.live_gesture`) and run once when the drag ends, so a
  drag costs the solve + raster only. Retest with the same 100+ entity
  sketch: the DOF readout freezes during the drag and updates on release.

## §M17 — Per-DOF drag (rails)

Status: PENDING sign-off

- [X] 1. Two lines, Parallel between them. Drag an endpoint of one around.
   **Expect:** it slides along the line's direction; the OTHER line never
   rotates or moves. The status bar says it is sliding along the
   remaining freedom.
- [X] 2. Horizontal line: drag an endpoint diagonally — it slides in x only;
   drag it straight up — it sticks (the line never translates from an
   endpoint drag). Dragging the LINE (not an endpoint) still moves it
   freely.
- [X] 3. Rectangle (auto H/V): drag a corner — it follows the cursor, the
   two adjacent corners slide along their edges, the opposite corner
   stays put. One Ctrl+Z reverts the whole drag.
- [X] 4. Point with a Fix constraint (or the origin): dragging refuses with
   a reason in the status bar.
- [ ] 5. Point-On a circle: dragging the point slides it AROUND the circle.
    ~~When drgging point off circle most of the time the badge shows invalid
    constrain, sometimes its green valid. even with snap disabled~~
    (fix 5b below — retest: badge should stay green for the whole gesture)
- [X] 6. Drags feel like rails, not lurches: no geometry the cursor never
   touched jumps during any of the above.

Fix log:
- **5** The substep walk along a CURVED rail is first-order per step, so a
  long slide around a circle drifted a few microns off it — past the DOF
  analyzer's 0.001 mm violation tolerance, which is exactly the flickering
  "invalid constraint" badge. Every drag update is now Newton-polished: a
  clone of the sketch is solved with everything except the walked points
  pinned (and untouched circles' RADII pinned too, so the correction cannot
  be absorbed by quietly growing the circle) at a tightened convergence
  threshold. Residual after a quarter-turn drag is < 0.0005 mm — covered by
  `tests/m17_dof_drag.gd`. Retest: badge stays green for the whole slide.
- **5b** (2026-08-17 retest note: "badge shows invalid constrain" while
  pulling the point off the circle) Two causes, both fixed:
  (a) Badge colors were re-read from live residuals every repaint. Mid-drag,
  the per-frame sub-solves legitimately leave transient sub-tolerance
  residuals on a heavy sketch, so the badge flashed grey. The satisfied
  state is now FROZEN during a live gesture and re-read at rest — the same
  treatment `live_gesture` already gave the DOF analysis, and what Fusion
  does (glyphs never flash mid-drag).
  (b) APPLYING Point-On split the error between the point and the circle's
  radius — a r=20 mm circle grew to r=34 mm on apply, so the fixture itself
  was wrong before the drag even started. The apply-time solve now pins all
  radii first and moves the under-constrained point onto the circle,
  falling back to the free solve only when a radius genuinely must change
  (a driving Radius dimension). `tests/m17_apply_prefer_points.gd`.
  Retest 5: apply Point-On — the circle must NOT grow; drag the point
  around and off — the badge stays green throughout.

## §M18 — Extrude holes + booleans

Status: PENDING sign-off

- [X] 1. Sketch on XY: rectangle, then a circle inside it. Finish. Extrude,
   hover/click the RING between rect and circle. **Expect:** the extrude
   lands as a plate with a real hole — orbit it and look through the hole.
    Does work as described, but:
    When hovering over a sketch in 2d / 3d mode, it doesn't have any indication that we are able to perform actions on it (like extruding)
    When a sketch is 'closed' it should have a filled in area like in fusion
    Fixed — see fix log **1**. Re-test.
- [X] 2. Same sketch: extrude again, this time clicking INSIDE the circle.
   **Expect:** a solid disc body appears in the hole (it is its own
   region, not part of the ring).
- [X] 3. New sketch on the plate's plane, small rectangle over the solid.
   Extrude → in the dialog pick **Cut**, distance deeper than the plate.
   **Expect:** a rectangular pocket is carved out of the plate; orbit to
   confirm the cut walls are closed (no see-through faces).
    Unable to select rectangle, or it's not working correctly. extrude of any size is making the original extruded 'ring' disapear
    Fixed — see fix log **2**. Re-test.
    Update: Still issue with left over faces. see prompt image
    Fixed — see fix log **7** (lateral skin). Re-test.
- [X] 4. Another sketch, a rectangle overlapping the plate's footprint.
   Extrude → **Join**, same height. **Expect:** plate and boss become ONE
   body (click one — both highlight together as a single selection).
- [X] 5. Extrude a far-away rectangle as **New Body**. **Expect:** it stays
   a separate body; the browser lists it on its own; clicking it does not
   highlight the plate.
- [X] 6. Ctrl+Z through the above one step at a time. **Expect:** each
   boolean unwinds cleanly — the pocket refills, the boss detaches — with
   no ghost geometry left behind.
    ctrl + z made some geometry disapear, ctrl + shift + z did not bring it all back. 
    even though it's still set as visible in the outliner. there is a maybe related error
    󰣇  [tones] nixos:~/godot/echo-cad/  main   godot --path ./
    Godot Engine v4.7.1.stable.official.a13da4feb - https://godotengine.org
    OpenGL API 3.3.0 NVIDIA 595.71.05 - Compatibility - Using Device: NVIDIA - NVIDIA GeForce RTX 4080

    [godot-geometry] extension initialized; GeometryOps registered.
    [godot-thorvg] extension initialized; TVGCanvas registered.
    ERROR: Index p_surface = 0 is out of bounds (surface_override_materials.size() = 0).
       at: set_surface_override_material (scene/3d/mesh_instance_3d.cpp:376)
       GDScript backtrace (most recent call first):
           [0] _apply_bodies (res://src/app/world_3d.gd:665)
           [1] _rebuild_bodies (res://src/app/world_3d.gd:630)
           [2] build (res://src/features/body_builder.gd:91)
    Fixed — see fix log **3**. Re-test.
    󰣇  [tones] nixos:~/godot/echo-cad/  main   godot --path ./
    Update: Still has errors, se prompt
    Fixed — see fix log **6** (null bake crash + z-fighting ghost). Re-test.
- [X] 7. Save, reopen. **Expect:** holes, cuts, and joins all rebuild
   identically (operations persist in the file).
- [X] 8. A **Cut** whose profile touches no body. **Expect:** nothing is
   removed; the status bar explains what Cut does.
    Cut makes certain geometry fail, like if same height, it will leave cap. maybe z fighting? unsure. 
    Also causes model to disapear until saved / reopened Fixed — see fix log **4** (cap skin) and **3** 
    (disappearing). Re-test. 
    Update: Error on loading
      󰣇  [tones] nixos:~/godot/echo-cad/  main   godot --path ./
      Godot Engine v4.7.1.stable.official.a13da4feb - https://godotengine.org
      OpenGL API 3.3.0 NVIDIA 595.71.05 - Compatibility - Using Device: NVIDIA - NVIDIA GeForce RTX 4080

      [godot-geometry] extension initialized; GeometryOps registered.
      [godot-thorvg] extension initialized; TVGCanvas registered.
      SCRIPT ERROR: Cannot call method 'get_surface_count' on a null value.
                at: build (res://src/features/body_builder.gd:89)
                GDScript backtrace (most recent call first):
                    [0] build (res://src/features/body_builder.gd:89)
    Fixed — see fix log **6**. Re-test.

Additional:
  3d meshes seem to spawn with different lighting . some appear as if lit from top, some appear as if lit from botom or back. it's not cohesive. also don't see outlines in the models edges making it somewhat hard to tell exactly what were' looking at. that is a regression
  Fixed — see fix log **5**. Re-test.
  update:
   Lighting appears to be coming from down to top rather than top to down

Fix log:
- **1 (extrude affordance)** — closed sketch regions now render as
  translucent filled faces in BOTH views, Fusion-style: `SketchView._draw`
  fills every closed region under the geometry lines (2D), and `CadWorld.
  rebuild_sketches` adds a fill mesh per sketch, sunk 0.02 mm below the
  plane so it never z-fights lines or body caps (3D). While "Extrude" is
  waiting for a profile click, mouse motion pre-highlights the region the
  click would take (`CadWorld.set_profile_hover`, amber, drawn on top) —
  hovering now says "this is extrudable" before you commit. The fill
  carries `sketch_fill_for` meta, NOT `feature_id`, so it is never
  body-pickable; the browser eye tick hides fill and lines together.
- **2 (wrong profile picked)** — `AppRoot._profile_under_ray` scanned
  sketches in TIMELINE order and returned the first containing the hit, so
  with two sketches on the same plane a click inside the new rectangle
  resolved to the PLATE's outer profile — the "cut" then carved the plate's
  own footprint and the whole ring vanished. It now takes the NEAREST ray
  hit, and on a tie (coplanar sketches) the LATEST sketch wins. Regression
  test in `m18_extrude_booleans`.
- **3 (bodies vanishing; surface-override error)** — two halves. (a) The
  CSG combiner's shape rebuilds via a deferred call after entering the
  tree; depending on when the rebuild was kicked off (an undo, a coalesced
  rebuild) one frame was not always enough and `bake_static_mesh()` came
  back with ZERO surfaces — `BodyBuilder.build` now re-bakes across up to 8
  frames before believing "empty". (b) A genuinely empty bake (a cut that
  consumes the body) is legal: the builder drops surfaceless meshes from
  the body list and `CadWorld._apply_bodies` guards against them, which is
  exactly the `set_surface_override_material` index-out-of-bounds error in
  the report.
- **4 (same-height cut leaves a cap)** — only HOLE prisms were extended
  past the caps; a cut prism exactly as tall as its target left coplanar
  faces for the CSG classifier to z-fight over, leaving a zero-thickness
  cap skin. Cut prisms now overhang both caps by the same `EPS_MM` (0.05 mm)
  the holes use. Regression test: same-height pocket volume is exact.
- **5 (lighting/outlines regression on boolean bodies)** — single-part
  bodies mesh through `ExtrudeFeature.build_mesh` (flat normals + an
  edge-line overlay surface); CSG-baked boolean bodies kept whatever
  normals the classifier left behind (smoothed across seams, occasionally
  inward) and had NO edge overlay — hence the incoherent lighting and the
  missing silhouettes. `BodyBuilder._finish_csg_mesh` now rebuilds every
  bake into the same shape: outward winding enforced by signed volume,
  flat per-face normals, and an edge surface at sharp dihedrals (same 15°
  threshold as plain extrudes) and open boundaries.
- **6 (round 2: null bake crash, stuck builds, z-fighting ghost)** —
  `bake_static_mesh()` can also return NULL (shape not yet built — e.g. the
  first build after a document load), and the unguarded call crashed the
  `BodyBuilder.build` coroutine mid-flight. That crash left
  `_bodies_building` stuck true, so NO body rebuild ever ran again — and the
  scratch CSG combiner it abandoned kept rendering its raw brushes over the
  real body mesh, which is exactly the z-fighting striped ghost in the
  §M18.6 screenshot. The retry loop now guards null (a null that survives
  the retries counts as empty), and scratch combiners are `visible = false`
  from birth — they exist only to be baked and must never draw.
- **7 (round 2: flush cut leaves a roof/wall skin)** — the EPS overhang in
  fix **4** only covered the caps; a cut sharing an EDGE with the target's
  outer profile puts a cut side wall exactly ON a body wall, and that
  lateral coplanar pair left the skin roofing the notch in the §M18.3
  screenshot. Cut profiles now also inflate EPS_MM (0.05 mm) SIDEWAYS
  (`Geometry2D.offset_polygon`, miter), with kept islands (holes in the cut
  region) shrunk by the same hair. Cuts therefore over-cut by 0.05 mm at
  their side walls — invisible, and the price of clean engine-CSG booleans.
  Regression tests: flush-edge notch volume exact; interior cut volumes in
  the m18/RPC tests account for the inflation.

## §M19 — Modify-tool constraint upkeep

Status: PENDING sign-off

- [X] 1. Rectangle, then Offset (O) and a single click on ONE edge.
   **Expect:** the whole rectangle offsets as a ring, not just that edge;
   the preview follows the cursor to either side; a distance dimension
   appears on the offset.
- [X] 2. Double-click that gap dimension and type a new value. **Expect:**
   the offset copy re-drives to the new gap, staying parallel edge-for-edge.
    Only that one edge changes size, not all
    Fixed — see fix log **1**. Re-test.
- [X] 3. Drag a corner of the SOURCE rectangle. **Expect:** the offset copy
   follows (parallel + gap hold); nothing explodes.
    Only source rectatngle moves, offset shape does not
    Fixed — see fix log **1** and **2**. Re-test.
- [X] 4. Draw a horizontal line (H badge), cross it with two verticals, Trim
   the middle span. **Expect:** BOTH kept pieces still carry the H badge and
   stay horizontal when dragged.
- [X] 5. Circle with a radius dimension, crossed by a line; trim half the
   circle away. **Expect:** the kept arc still carries the radius dimension,
   and editing it resizes the arc.
- [!] 6. Tangent line on a circle; trim the circle's far side. **Expect:** the tangency survives on the kept arc (drag the line — the arc follows).
    Tangent constraint breaks, badges turn orange, and line is able to move independently of arc. 
    also to test this i had to draw two lines, one tangent, and another also tangent on another quadrant, or intercepting circle, so there could be geometry to trim arc. just an observation
    Fixed — see fix log **3** (retarget) and **4** (undo-batch corruption, the
    likely source of the orange badges and the decoupled line). Re-test.
    Update round 2 (screenshot with two tangent lines): orange badges +
    detachable line reproduced and root-caused — see fix log **5** (false
    "redundant" at exact tangency), **6** (trim tie let the joint slide),
    **7** (touch cuts shadowed by intersection cuts). Re-test.
    Update round 3: unable to trim circle with tangent constraints when the
    tangent lines' endpoints sit OFF the circle. Fixed — see fix log **8**.
    Re-test.
    Update round 4: a tangent ARC (line -> Tangent Arc -> line) grew in size
    on EVERY dimension edit — adding a dimension, changing a `width`-driven
    one, or adding lines each nudged the arc bigger, until it visibly crossed
    its own tangent line. Fixed — see fix log **9**. Re-test.
    Update round 5 (screenshots: width/2 -> width on a separate line): editing
    a dimension on an UNRELATED line still resized the arc. Fixed — see fix
    log **10**. Re-test.
    Still fails, see prompt for image
- [X] 7. Center Rectangle: **Expect:** a construction diagonal + center point appear; drag a corner — the center point stays centered; the Line tool
   snaps to the center point.
- [X] 8. Each of the above is ONE undo step (offset+constraints, trim+
   retargets, center rect+scaffolding).
    Sometimes when dragging a corner / line it seems that it requires multiple undo steps to fully undo
    Fixed — see fix log **4**. Re-test.

Fix log:
- **1 (offset ring under-constrained)** — the offset used to carry PARALLEL
  per line plus ONE point-to-line gap on the first edge: three of the four
  edges had no gap, so driving the dimension moved one edge (§M19.2) and a
  source drag left the copy behind (§M19.3). Every offset line now carries a
  LINE_DIST to its source (the solver's parallel-gap constraint — parallelism
  and gap in one), and all of them share a new dimension GROUP
  (`SketchConstraint.group`, serialized): the overlay shows one dimension for
  the group, editing it re-drives every member, deleting it deletes the
  group. The ring is fully determined against its source, Fusion-style.
- **2 (drag never recruited coupled geometry)** — `DragFilter.plan` only grew
  its column set when the dragged point had NO freedom at all; a drag whose
  request projected to (nearly) zero — the rails perpendicular to the cursor
  — just stuck, which is why the source could not tow its offset, and why
  m06's tangent-arc drag had quietly done NOTHING since M17 (its test passed
  vacuously). Two changes: `_expand` also hops through constraints (an offset
  ring shares no entity with its source, so the entity hop never reached it),
  and a near-zero projected motion now recruits geometry reachable through
  COUPLING constraints (2+ operands) and retries. Single-operand shape
  constraints (H/V) never recruit — a purely vertical drag on a Horizontal
  line still sticks, per the locked M17 rule.
- **3 (trim dropped tangency)** — TANGENT retargeting kept the constraint
  only if some kept piece's live residual was under 0.05 mm; a sketch a hair
  off converged silently dropped it. Tangency depends only on the infinite
  line / the circle's center+radius, and every kept piece preserves those
  (collinear line pieces, same-circle arcs) — so the retarget is now
  UNCONDITIONAL, aimed at the piece nearest the tangency point.
- **4 (drag undo-batch lifecycle)** — two leaks. An Esc or tool switch
  mid-drag left the gesture's CmdMergeBatch OPEN on the stack, silently
  absorbing every later command into one undo step — after which Ctrl+Z
  undid mixed blobs of edits and re-solves (the "multiple undos to unwind",
  and a plausible source of §M19.6's broken-looking constraints). And a drag
  that never moved anything sealed an EMPTY batch: a phantom undo step that
  eats a Ctrl+Z doing nothing. Batches now seal on EVERY exit path
  (pointer-up, cancel, deactivate) and a sealed no-op batch is dropped from
  the stack (`CommandStack.drop_if_noop`).
- **5 (round 2: amber badges at exact tangency)** — the screenshot's orange
  badges were `DofAnalyzer` false alarms: at an EXACT tangency the tangent
  and point-on gradients align, and the numeric rank test cannot tell
  "dependent everywhere" (a real duplicate) from "degenerate right here" (a
  singular configuration). Flagged constraints are now CONFIRMED at a
  jittered state — golden-angle per-point directions, since a shared
  direction is a rigid translation every constraint is invariant under —
  and only constraints still dependent there stay flagged. The tangency
  reads green; true duplicates still read amber.
- **6 (round 2: joint could slide)** — a trim cut made AT another entity's
  ENDPOINT (touch cut) tied the kept piece to the cutter with POINT_ON,
  which left the joint free to SLIDE along the cutter — the tangent line
  "moving independently". Touch cuts now weld COINCIDENT to the touching
  endpoint (the joint is a real corner), and a POINT_ON made redundant by
  the new weld is pruned instead of retargeted. m10's T-joint test updated
  to the weld semantics.
- **7 (round 2: welds never fired)** — the same junction is often found
  BOTH as a touch cut (with the endpoint id) and as a segment intersection
  (without); the intersection version won the span scan, so the weld in fix
  **6** never triggered. Touch cuts now take precedence and coinciding
  intersection cuts are dropped.
- **8 (round 3: tangent contacts are not "intersections")** — a tangent line
  only GRAZES the curve, so the segment intersector finds zero, one or two
  phantom points there depending on which side of exact the solver settled;
  with both contacts tangential the circle often had under two cuts and trim
  refused entirely. Tangency points implied by TANGENT constraints are now
  first-class CUTS (`_tangent_cuts`), computed exactly (foot of
  perpendicular / center line) and bounded to the partner's actual span;
  grazing phantom intersections from the same entity are deduped against
  them. The trimmed-off span ties its new endpoints POINT_ON the tangent
  lines and both tangents retarget onto the kept arc.
- **9 (round 4: arc radius ratchet)** — the relax solver finds *a*
  satisfying state, not the NEAREST one, and on an under-constrained
  tangent-arc chain the equilibrium slid a little outward on every re-solve:
  ten dimension edits took a 15.4 mm arc to 17.3 mm, and mid-ratchet states
  are what put the arc visibly across its own tangent line. The solve now
  takes a one-shot MINIMAL-CHANGE pass at first convergence
  (`_restore_arc_radii`): every arc whose radius no dimension drives gets
  its centre pulled back onto the rim chord's bisector at its ENTRY radius,
  then the rounds continue so the constraints can object — and if they
  cannot re-converge, the pre-restore state (which had converged) is what
  applies. Same ten edits now hold the radius flat. Regression test in m19.
- **10 (round 5: unrelated edits leak into the chain)** — every dimension
  edit re-solved the WHOLE sketch, and the relax solver nudges everything it
  visits by residual dust; on a stiff under-constrained tangent-arc chain
  (whose radius is geometrically a function of where its weld points sit)
  those nudges moved the chain sideways and the radius followed — an arc
  resizing because a line it shares nothing with changed length. Solves
  after dimension add/edit/delete/driven-toggle and parameter changes are
  now SCOPED: geometry outside the edited constraint's constraint-connected
  component is pinned (`AppRoot._pins_outside_components`), so unrelated
  geometry cannot move at all — the chain now stays bit-for-bit identical
  under unrelated edits. Regression test in m19.

## §M20 — Marquee selection + Parameters dialog

Status: Signed off 2026-08-17

- [x] 1. Sketch with several entities. Drag LEFT-TO-RIGHT on empty space
   around some of them. **Expect:** a blue band with a solid edge; on
   release only entities ENTIRELY inside are selected (one poking out is
   not).
- [x] 2. Drag RIGHT-TO-LEFT across the same geometry. **Expect:** a green
   dashed band; everything the band merely TOUCHES selects.
- [x] 3. Ctrl+band adds to an existing selection; plain click on empty
   space still deselects everything; Esc mid-band cancels it.
- [x] 4. Band over a dimension label / constraint badge area. **Expect:**
   bands select geometry only — labels and badges are not kidnapped.
- [x] 5. Toolbar "Parameters": dialog lists name / expression / value.
   Add `width = 2` (in). **Expect:** it appears with value 2 in.
- [x] 6. Dimension a line, double-click it, type `width`. **Expect:** the
   line drives to 2 in. Change width to 3 in the dialog — the line follows.
- [x] 7. Try to delete `width` while the dimension uses it. **Expect:**
   refused with a message naming the user. Delete the dimension, then the
   parameter deletes fine.
- [x] 8. Type a bad expression (`width +`) in the dialog. **Expect:** the
   error shows inline; nothing is applied.

## §M21 — DXF export

Status: PENDING sign-off

- [ ] 1. Sketch with a line, circle, arc, slot, and a construction line
   (select any curve and press **X** to toggle it construction — fix 1).
   "Export DXF", save somewhere. **Expect:** file dialog defaults to .dxf;
   status bar confirms the path.
   	~~Does work, however don't know how to create a construction line~~
   	~~now construction line is made, but when selected, can't tell it's
   	constructino line because outline is non dashed.~~ (fix 4)
   	~~Also toggling x during line drawing should turn it into construction
   	line. right now only way is creating the line, selecting it, then
   	pressing x~~ (fix 5)
   	~~While drawing a construction line, make the ghost / psuedo line /
   	shape / geometry also dashed to show it's geometry~~ (fix 8)
- [X] 2. Open the exported file in any DXF viewer (eMachineShop viewer,
   LibreCAD, an online viewer, or Fusion insert-DXF). **Expect:** geometry
   matches the sketch exactly — arc directions included; construction
   geometry sits on its own CONSTRUCTION layer and renders DASHED.
   ~~Does work, with exception that i don't know how to test construction line~~
   	~~Works as inteded, however construction line in DXF is not dashed.~~
	~~We also need a way to export / not export construction lines during
	dxf export~~ (both fix 6)
- [X] 3. Check units in the viewer: a 1 in line measures 25.4 (mm).
- [X] 4. In model mode with several sketches: click a sketch in the browser,
   then "Export DXF". **Expect:** the dialog opens titled with THAT
   sketch's name and exports it. With NO sketch selected, the status bar
   explains how to pick one.
   	~~It does state it, however i don't see a way to select what sketch to
   	export. if i click on a sketch and click export button, it still
   	reports same error.~~ (fix 2)
- [X] 5. Right-click a sketch in the browser. **Expect:** a context menu
   with "Edit Sketch" and "Export DXF..." — export writes the right-clicked
   sketch even if another row was selected. Double-clicking a sketch row
   opens it for editing. (fix 3)
- [X] 6. Construction toggle round-trip: select a line, press X — it goes
   violet/dashed and stops counting for profiles (extrude ignores it);
   X again restores it; each press is one undo step. NOTE: the Extend
   tool's shortcut moved from X to **E** to make room for this.
   ~~Construction line doesn't appear as construction (dotted / purple) in
   the 3d view. only when editing that sketch~~ (fix 7)
- [X] 7. Selected/hovered construction geometry keeps its dashes: click a
   construction line — the yellow highlight is DASHED, so it still reads
   as construction while selected. Same for construction circles/arcs.
- [ ] 8. Construction MODE: with nothing selected press X (or tick the new
   "Construction" checkbox in the toolbar) — the status bar announces the
   mode, and every line/circle/arc drawn from then on comes out
   construction. Works mid line-chain: segments clicked after the toggle
   are construction, earlier ones untouched. X again (nothing selected)
   turns it off. While the mode is on, the drawing PREVIEW itself renders
   violet and dashed (line rubber band, rect/circle/arc/slot ghosts), so
   what you see is what will commit.
- [ ] 9. Export dialog: an "Include construction geometry" checkbox sits in
   the file dialog. Untick it — the exported DXF contains no construction
   entities; tick it — they export on the dashed CONSTRUCTION layer.
- [ ] 10. Finish the sketch and orbit in model mode: construction geometry
   shows violet and dashed in the 3D view, clearly distinct from normal
   sketch lines.

Fix log:
- **1** (2026-08-18, "don't know how to create a construction line") There
  was no way — PLAN.md promised Fusion's X toggle but it was never built;
  only tools (mirror axis, center-rect scaffolding) made construction
  geometry. **X** now toggles the selected curves between normal and
  construction (`CmdSetConstruction`, one undo step, status-bar
  explanation; points are skipped). The Extend tool, which sat on X, moved
  to **E**.
- **2** ("no way to select what sketch to export") Export DXF resolved only
  the ACTIVE sketch or a sole sketch — clicking a browser row never fed it.
  The target now resolves active sketch -> browser-selected sketch -> only
  sketch, and the dialog title names which sketch it will write.
- **3** ("right click a sketch in the outliner to export") The browser's
  sketch rows now carry a context menu (Edit Sketch / Export DXF...), and
  double-click opens the sketch for editing, as the code always claimed.
  `tests/m21_qa_fixes.gd` covers all three.
- **4** (2026-08-18 retest, "when selected, can't tell it's construction")
  The selection/hover highlight painted a SOLID stroke over the entity, so
  the dashes vanished exactly when the user was looking at it. Highlights
  on construction geometry now draw dashed (lines via draw_dashed_line;
  circles/arcs via a dashed-arc helper — item 7).
- **5** ("toggling x during line drawing should turn it into construction")
  X with nothing selected now toggles construction MODE (also a
  "Construction" toolbar checkbox): drawing tools stamp new curves with it,
  so X mid-chain flips the segments still to come — Fusion's sticky toggle.
  Copy tools (offset/mirror/trim/project) deliberately ignore the mode and
  preserve their source's flags (item 8).
- **6** ("construction line in DXF is not dashed" + "way to export / not
  export construction lines") The DXF now declares a DASHED linetype in its
  LTYPE table and the CONSTRUCTION layer references it, so viewers render
  it dashed. The export file dialog gained an "Include construction
  geometry" checkbox (default on); `action.export_dxf` takes
  `construction: false` for the same (item 9).
- **7** ("doesn't appear as construction in the 3d view") The 3D sketch
  mesh drew every entity with one material. Each entity is now its own
  surface: construction entities render violet with real dashed segments
  (3D lines have no dash support, so the dashes are geometry — item 10).
  All covered by `tests/m21_qa_fixes.gd`.
- **8** (2026-08-18 retest, "make the ghost also dashed") While
  construction mode is on, every drawing tool's GEOMETRY preview now
  renders violet and dashed — the line rubber band, rect outlines, circle/
  arc ghosts, and slot walls/caps — via construction-aware preview helpers
  in the tool base (`preview_line`/`preview_arc`/`preview_rect`). Guide
  chrome (radius spokes, pick markers) stays as it was, since it never
  becomes geometry.
