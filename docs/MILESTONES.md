# EchoCAD — Milestones

One git branch per milestone (`m01-model`, `m02-shell-3d`, …), merged to `main`
when its automated tests pass and its manual checklist is signed off. Every
milestone ships: code + headless tests + (from M3 on) RPC tests + manual test
additions to `docs/MANUAL_QA.md`.

Test-runner conventions (established in M0):
- `tools/run_tests.sh` — runs every `tests/*.gd` headless, prints `FAIL <name>`
  per failure, non-zero exit on any failure.
- After adding any `class_name`, run `godot --path . --editor --quit --headless`
  once to register globals (echo_vector gotcha).

---

## M0 — Scaffold  (branch: `m00-scaffold`)

Copy `addons/thorvg/` and `addons/geometry/` from sibling repos. Directory
skeleton per PLAN.md. `tools/run_tests.sh`. Smoke test proving both extensions
load headless (`ClassDB.class_exists("TVGCanvas"/"GeometryOps")`). CLAUDE.md
with build/test commands.

- **Automated**: `tests/m00_smoke.gd` — extensions load, TVGCanvas renders a
  line to an Image, GeometryOps boolean returns ok.
- **Manual**: project opens in editor with no errors; both extensions listed.

## M1 — Core model, commands, serialization  (branch: `m01-model`)

Typed entities (point/line/arc/circle), constraint model (full 22-type
vocabulary as data), parameters/expressions port, unit converter (mm canonical,
inch default display), feature list + `SketchFeature`, command stack +
merge-batch port, `.ecad` serializer v1 with migration scaffold.

- **Automated**: entity CRUD + stable ids; constraint ref remap on entity
  delete; command undo/redo round-trips model to identical JSON; serializer
  save→load→save byte-identical; expression whitelist rejects unknown names;
  unit conversions (`1in` ↔ `25.4mm`).
- **Manual**: none (no UI yet).

## M2 — 3D shell + sketch mode  (branch: `m02-shell-3d`)

Main scene: 3D viewport, orbit/pan/zoom camera, view cube, origin planes +
axes, mode manager. Create Sketch → pick origin plane → sketch mode: camera
locks normal, adaptive 2D grid, ThorVG raster pipeline (RenderBridge port +
CanvasView-style re-raster on view change), screen-space overlay Control,
Finish Sketch returns to model mode; sketch shows as line mesh in 3D.

- **Automated**: headless — instantiate main scene, enter/exit sketch mode,
  assert camera transform, mode state, world↔screen round-trip at several
  zooms; grid spacing adapts to zoom.
- **Manual**: orbit/pan/zoom feel; view cube faces/corners; click each origin
  plane to sketch; grid readable at all zooms; no drift between raster and
  overlay while zooming.

## M3 — Automation API  (branch: `m03-automation-api`)

`AutomationServer` autoload (TCP line-delimited JSON, `--automation-port`),
input injection with human-like pointer paths, `query.*`/`action.*`/`app.*`
families, screenshot capture, Python client `tests/rpc/client.py`, runner
`tools/run_rpc_tests.sh` (launches app, runs scripts, kills app).

- **Automated**: RPC — launch app, query mode, activate sketch via RPC clicks
  only (no `action.*` shortcuts), drag-orbit and verify camera changed,
  screenshot non-blank, malformed request returns error not crash. Headless —
  server unit tests over a loopback socket.
- **Manual**: run demo script `tests/rpc/demo_tour.py`, watch it drive the app.

## M4 — Line tool + snapping + inference  (branch: `m04-line-tool`)

Line tool (click-click chained, Esc/Enter/close ends chain, preview segment),
snap engine port + grid/increment snap + endpoint/midpoint snaps, Fusion-style
inference for H/V/coincident with glyph preview, sketch-point tool. Blue
(free) vs constrained entity coloring starts here.

- **Automated** (RPC + headless): draw 3-segment chain → query entities: 3
  lines, 4 points, expected coords within tolerance; near-horizontal draw →
  HORIZONTAL constraint exists; endpoint click on existing point → COINCIDENT;
  Esc mid-gesture leaves model unchanged; undo removes whole chain per rules.
- **Manual**: glyphs visible before click; inference toggle works; snap feel at
  high/low zoom; cursor coordinates readout.

## M5 — Rectangle + circle  (branch: `m05-rect-circle`)

2-point rectangle and center rectangle (each = 4 lines + auto H/V + coincident
corners, one undo step), center-radius circle, 3-point circle. Numeric
type-while-drawing for size (Tab between fields, Fusion-style).

- **Automated**: rect → query: 4 lines/4 points/4 coincident/2 H/2 V; typed
  `2in` width honored (query pos in mm = 50.8); circle center+radius exact;
  3-point circle through 3 clicked points; undo = one step per shape.
- **Manual**: drag preview correctness; type-in boxes focus/Tab order; circle
  radius drag feel.

## M6 — Arc + solver upgrade  (branch: `m06-arc`)

3-point arc, center-point arc, tangent arc. Solver extension: radius as
variable, arc center/endpoint coupling, line-arc + arc-arc tangency, equal
radius, concentric; rigid-group rotation DOF. DOF analysis covers arcs.

- **Automated**: solver unit tests — tangent line-arc converges; equal-radius
  pair; DOF counts for arc-containing sketches match hand-computed values;
  RPC — draw tangent arc off a line end, query TANGENT constraint exists,
  drag line and verify arc follows (positions re-queried after solve).
- **Manual**: tangent arc rubber-band preview; dragging under-constrained arc
  feels stable (no explosion).

## M7 — Constraint palette + DOF UI  (branch: `m07-constraints`)

Manual constraint toolbar/palette (all types), constraint glyph display on
geometry, click-to-select + delete constraints, conflict/over-constraint
feedback (amber/red), status bar "N DOF remaining" / "Fully constrained",
fully-constrained geometry color change.

- **Automated**: RPC — apply each constraint type to fixture sketches and
  verify solve result + DOF; create a conflict, query conflict list non-empty;
  delete constraint restores DOF.
- **Manual**: glyph hover/select/delete ergonomics; conflict coloring; green
  lock moment when sketch becomes fully constrained.

## M8 — Dimensions + parameters  (branch: `m08-dimensions`)

Smart Dimension tool (`D`): distance/aligned/angle/radius/diameter inferred
from picks; label follows cursor until parked; double-click to edit; driven
toggle; expression input; Parameters dialog; unit-suffixed entry everywhere.

- **Automated**: RPC — dimension a line `2.5in`, entity length = 63.5mm; angle
  dim between lines drives to set value; param edit re-solves dependents in one
  undo step; driven dim measures but never moves geometry; expression error
  surfaced in query.
- **Manual**: label drag/park; arrows/extension lines readable at all zooms;
  dialog UX; Fusion `D` muscle memory works.

## M9 — Slot tool  (branch: `m09-slot`)

Center-to-center, overall, and center-point slot variants. Composite output
(2 lines + 2 arcs + tangent/equal-radius/coincident constraints + slot_meta),
dimensions editable after creation.

- **Automated**: RPC — each variant: query entity census + constraint census +
  key measures (center distance / overall length / width) match input; slot is
  one undo step; slot deforms correctly when its dimension edited.
- **Manual**: preview during placement; width type-in; dragging slot keeps it
  slot-shaped.

## M10 — Modify tools  (branch: `m10-modify`)

Trim (hover highlights doomed span), extend, offset (GeometryOps-backed for
chains), mirror, sketch fillet (corner → tangent arc). Constraint refs survive
all of them (remap in same undo step — echo_vector pattern).

- **Automated**: trim splits entities correctly + constraints pruned/remapped;
  extend meets target within tolerance; fillet inserts tangent arc with both
  tangencies; mirror creates symmetric entities + symmetry constraints; every
  op = one undo step.
- **Manual**: trim hover highlight accuracy on crossing geometry; fillet radius
  type-in; offset direction flip.

## M11 — Timeline UI  (branch: `m11-timeline`)

Timeline bar (bottom, Fusion-style): feature icons, rollback marker drag,
right-click edit/rename/suppress/delete, edit sketch reopens it and replays
downstream on finish. Multiple sketches on different planes.

- **Automated**: RPC — create 2 sketches, roll back before #2, query visible
  entities excludes it; edit sketch #1, finish, #2 replays; timeline ops
  undoable; save/load preserves timeline + marker.
- **Manual**: marker drag feel; icons/labels; suppress dimming.

## M12 — Extrude (phase-2 gate)  (branch: `m12-extrude`)

Closed-profile detection (loop finding over sketch entities), profile
highlight on hover, basic extrude to `ArrayMesh` with distance input, extrude
as timeline feature. Opens phase 2.

- **Automated**: profile detection on fixture sketches (incl. holes via nested
  loops); extrude produces watertight mesh with expected volume (± tol); edit
  sketch → extrude replays with new profile.
- **Manual**: profile hover highlight; extrude preview drag; orbit the solid.

## M14 — Orbitable sketch view  (branch: `m14-sketch-orbit`)

Deferred out of the M2 QA pass. Today sketch mode is a locked 2D raster: the
camera is pinned normal to the plane and orbit is unavailable, so there is no
way to glance at the sketch in context and come back.

Target behaviour (Fusion's): Shift+MMB inside a sketch orbits away from the
plane, the sketch rendering in 3D on its plane while off-axis; clicking that
plane's view-cube face animates back to the locked, editable 2D view at the
pan/zoom the user left. Editing tools stay disabled while off-axis.

The work is a mode sub-state (locked-2D vs free-3D within `Mode.SKETCH`) plus
a 3D render path for the active sketch — `CadWorld.rebuild_sketches` already
draws live sketches as line meshes, so the in-edit sketch needs the same
treatment, and `SketchView` needs to yield the canvas while off-axis.
`OrbitCamera.capture_view`/`restore_view` (added in the M2 QA pass) already
provide the return-trip animation.

- **Automated**: entering sketch mode captures the plane view; orbiting sets
  the off-axis sub-state and disables tool input; the plane's cube face
  restores the exact pan/zoom captured on leaving; undo/redo unaffected.
- **Manual**: orbit feel inside a sketch; the return animation reads as a
  fly-back, not a snap; grid/axes stay legible at grazing angles.

## M15 — Project / reference geometry  (branch: `m15-project`)

Deferred out of the M2 QA pass. Sketch mode now DRAWS the other coplanar
sketches dimmed behind the one being edited (M2 fix 9), so you can see what is
already there — but that geometry is display-only: it is not in the snap index
and not hit-testable, so you cannot snap to it, constrain to it, or trim
against it.

Target behaviour (Fusion's "Project / Include"): explicitly project an edge,
face boundary, or another sketch's geometry into the active sketch, producing
real projected entities that are constrained to follow their source and update
when it changes. That is a model-level link, not a render trick, which is why
it is its own milestone rather than an extension of the dim rendering.

- **Automated**: projecting an entity creates a linked entity in the active
  sketch; moving the source re-solves the projection; deleting the source
  breaks the link with a reported message rather than a crash; projections
  survive save/load.
- **Manual**: projected geometry is visually distinct from drawn geometry;
  snapping to it works; it participates in profile detection for extrude.

## M16 — Threaded solver  (branch: `m16-threaded-solver`)

Deferred out of the M6 QA pass. The M6 fix coalesced drag updates to one solve
per frame, which removed the wasted work that was pegging a core — but the
solve itself still runs synchronously on the main thread, so a large, heavily
constrained sketch will still stutter under a drag.

Port `echo_vector`'s approach: run `ConstraintSolver.solve` on a worker thread
against a snapshot, apply the result on the main thread when it lands, and drop
stale results if the gesture has moved on. The solver is already static and
pure (reads a Sketch, returns proposed moves), which is exactly the shape this
needs — no shared mutable state to guard.

- **Automated**: solve results are identical threaded vs synchronous for the
  fixture sketches; a gesture that outruns the solver applies only the newest
  result; undo still collapses a whole drag to one step.
- **Manual**: drag a 100+ entity constrained sketch — interactive, no stutter,
  CPU spread across cores rather than one pegged.

## M17 — Per-DOF drag refusal  (branch: `m17-dof-drag`)

Deferred out of the M7 QA pass (step 2). Dragging one of two PARALLEL lines
currently rotates and translates the other, including endpoints the user never
touched. Fusion does not allow this: once a constraint fixes a degree of
freedom, a drag cannot change it — the geometry slides only along the freedoms
that remain.

M6 fix 7 added a refusal, but it is whole-point: a drag is blocked only when
EVERY point it would move is fully determined. That cannot express "this point
may translate but its line's rotation is fixed", which is exactly the parallel
case — the points are under-constrained while the angle between them is not.

The work is to read the DOF analysis per degree rather than per point:
`DofAnalyzer` already builds the Jacobian and knows the row space, so the
free directions at a point are recoverable from it. The drag then projects
the requested motion onto those directions instead of being allowed or refused
outright, which also gives the softer Fusion behaviour of geometry sliding
where it can rather than simply not moving.

- **Automated**: dragging a point of a parallel pair leaves the other line's
  angle unchanged; a point on a Horizontal line moves in x but never y; an
  unconstrained point still moves freely; undo still collapses to one step.
- **Manual**: dragging constrained geometry feels like it is sliding on rails
  rather than refusing or lurching; the status bar explains what is holding it.

---

## Milestone order rationale

Automation API lands at M3, before any drawing tool, so every tool ships with
RPC tests from day one. Arc precedes the constraint palette because tangency is
the hard solver work. Slot comes after dimensions since its variants are
dimension-driven. Timeline UI is late but the *data model* is feature-based
from M1 — the UI is a view over structures that already exist.
