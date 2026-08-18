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

## M13 — Z-up world + orbit pivot modes  (branch: `m13-zup-orbit`)

Deferred out of the M2 QA pass. Switch the world to the Z-up convention used
by Blender and Fusion (+Z up, XY ground); rebuild sketch plane bases
right-handed around it. OrbitCamera stores yaw about world +Z plus pitch so
the horizon never rolls; frame_view sweeps the short way around the yaw
circle. Orbit pivot modes: BODY_CENTER (Fusion default), ORBIT_POINT
(surface point under cursor), VIEW_CENTER — model-relative modes fall back
to the world origin on an empty document. The MMB gesture is sticky
(releasing Shift mid-drag keeps orbiting).

- **Automated**: `tests/m13_zup_orbit.gd` — plane bases, roll-free orbit,
  gesture stickiness, empty-document origin fallback, three pivot modes
  distinct.
- **Manual**: folded into §M2 (items 1, 3, 3a, 3a2).

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

## M18 — Extrude holes + booleans  (branch: `m18-extrude-booleans`)

Phase-2 backlog. Profile detection becomes REGION detection, Fusion-style: a
loop wholly inside another with no connecting geometry is the outer face's
hole — clicking the ring between a rect and an inner circle picks
rect-minus-circle, clicking inside the circle picks the disc. Extruding a
holed region meshes the ring (caps triangulated around the holes via
bridge-splicing, hole walls wound outward).

Extrude gains Fusion's operation dropdown: **New Body** stands alone,
**Join** unions into every body its prism touches, **Cut** carves its prism
out of them (touching nothing: join starts a new body, cut is a no-op).
Booleans evaluate through the engine's CSG (`bake_static_mesh`), which bakes
a frame after the model change; documents without booleans keep the exact
synchronous mesher, edge overlay included. Bodies are derived state rebuilt
on every settled change — undo/redo and rollback need no special handling.

- **Automated**: `tests/m18_extrude_booleans.gd` — hole regions, net areas,
  ring extrusion volume, cut/join/no-target-cut volumes, undo/redo through a
  boolean, operation serialization. RPC `tests/rpc/test_booleans.py` — the
  same through real input plus `query.bodies` and the dialog's op dropdown.
- **Manual**: §M18 — hover/click regions with holes, cut and join by hand,
  orbit the carved solid.

## M19 — Modify-tool constraint upkeep  (branch: `m19-modify-upkeep`)

Phase-2 backlog: the modify tools produced geometry that immediately forgot
where it came from. Three upgrades:

- **Offset**: a single click picks the WHOLE connected chain (one edge of a
  rectangle offsets the rectangle, Fusion-style). The copies are constrained:
  each offset line is PARALLEL to its source and one driving point-to-line
  dimension holds the gap — editing it re-drives the offset; arcs/circles
  reuse the source center, concentric by construction.
- **Trim**: constraints on the trimmed entity move to its kept pieces
  instead of dying — directional constraints (H/V/parallel/perpendicular/
  collinear) to every kept line piece, radial ones (concentric/equal/radius/
  diameter) to the kept arc, TANGENT to whichever piece still touches the
  tangency. Length-type constraints still die (a piece is shorter).
- **Center rectangle**: emits Fusion's center scaffolding — a construction
  diagonal and a construction center point MIDPOINTed onto it, so the center
  stays the center through drags and is snappable/dimensionable.

- **Automated**: `tests/m19_modify_upkeep.gd` — chain census + parallels +
  gap-dim drive; H and RADIUS surviving trims; center point riding a corner
  drag. All existing modify suites unchanged.
- **Manual**: §M19 — offset feel with the new pick, gap dimension editing,
  trim on constrained geometry, center-rect snap.

## M20 — Marquee selection + Parameters dialog  (branch: `m20-marquee-params`)

Phase-2 backlog: the two daily-driver gaps left in the UI.

- **Marquee selection**: pressing empty space and dragging opens a band.
  Fusion semantics — left-to-right is a WINDOW select (blue, solid edge:
  only entities entirely inside), right-to-left is a CROSSING select
  (green, dashed edge: touching counts). Ctrl/Shift adds to the current
  selection; a plain empty click still deselects; Esc cancels a band.
- **Parameters dialog**: a real window (toolbar "Parameters") over the
  parameter model that action.set_parameter has driven since M8 — table of
  name/expression/value, add/update with unit choice (in/mm/scalar),
  expression errors surfaced inline, delete refused while a parameter is
  still referenced by another parameter or a dimension. RPC gains
  `action.delete_parameter` with the same protection.

- **Automated**: `tests/m20_marquee_params.gd` — window/crossing/additive
  band censuses, empty-click deselect, parameter upsert/drive/protected
  delete, dialog commit + error surfacing. RPC `tests/rpc/test_marquee.py`
  — the same through real pointer input and the RPC actions.
- **Manual**: §M20 — band feel and colors, dialog UX.

## M21 — DXF export  (branch: `m21-dxf-export`)

Phase-2 backlog. Minimal DXF R12 (ASCII) writer for a sketch: lines, arcs,
circles, and lone points in sketch-plane millimetres ($INSUNITS = 4).
Regular geometry on layer "0", construction geometry on "CONSTRUCTION" so
CAM tools can filter it; cw arcs swap ends for DXF's ccw convention; the
sketch origin and entity-owned points do not export. "Export DXF" button
(file dialog) exports the active sketch — or the document's only sketch
from model mode; `action.export_dxf {path, sketch?}` for automation.

- **Automated**: `tests/m21_dxf_export.gd` — parses the emitted DXF back:
  units header, layer split, coordinates, radii, arc angle spans (cw swap),
  lone-point rule, file API extension handling.
- **Manual**: §M21 — open an exported file in a second CAD/viewer.

## M22 — Construction planes + sketch on faces  (branch: `m22-planes`)

Phase-2 backlog ("face/offset planes come with phase 2" — sketch_feature.gd).
Sketches escape the three origin planes:

- **PlaneFeature** — a timeline feature (kind `"plane"`) in two flavors:
  *offset* (base = origin-plane name or another plane feature id, plus a
  signed offset in mm along the base normal) and *custom* (a stored basis +
  origin snapshot, minted by face picking). Live planes render as pickable
  quads like origin planes, get browser rows under a "Construction" folder
  (eye toggles), timeline chips, suppress/rollback/undo like any feature.
- **Sketch on them** — `SketchFeature.plane` may now hold a plane feature id;
  resolution goes through the document (features resolve in timeline order,
  so a plane is always defined before the sketches that use it). Everything
  downstream (extrude, bodies, DXF export, projection) works unchanged.
- **Sketch on a body face** — while picking a sketch plane, hovering a flat
  body face highlights it; clicking mints a *custom* PlaneFeature on that
  face (snapshot, not a parametric link — documented limitation) and starts
  the sketch there. Extrude cap faces are the target case.
- **UI**: model-mode "Offset Plane" button → pick base plane → type distance
  (unit-suffixed); double-click a plane chip/browser row to edit the offset.
- **RPC**: `action.create_offset_plane {base, offset}`, plane list in
  `query.timeline`; `action.create_sketch` accepts a plane feature id.

- **Automated**: `tests/m22_planes.gd` — offset-plane transform math (all
  three bases + chained offsets), sketch on an offset plane world-positions
  correctly, extrude from it lands at the right height, custom plane from a
  face transform, suppress/rollback hides dependent sketch geometry,
  serialization round-trip. RPC `tests/rpc/test_planes.py` — create plane,
  sketch on it, draw, extrude, query body volume/AABB.
- **Manual**: §M22 in `docs/MANUAL_QA2.md`.

## M23 — Revolve  (branch: `m23-revolve`)

The second solid feature. `RevolveFeature` mirrors extrude's anchor pattern:
sketch id + anchor uv re-finds the region on replay; the axis is a sketch
LINE entity id (typically a construction line) or the sketch's own X/Y axis;
angle in degrees (default 360); the same operation dropdown (New Body / Join
/ Cut) evaluated through BodyBuilder.

- Mesh: lathe of the region polygon (holes revolve into their own wall
  loops); partial angles get flat start/end caps triangulated with holes;
  profile points on the axis weld (no degenerate quads). Edge-line overlay
  surface like extrude's.
- Booleans: BodyBuilder generalizes from "extrude parts" to "solid-feature
  parts" — each solid feature supplies its own exact mesh, CSG node
  (CSGPolygon3D MODE_SPIN for revolve), and AABB.
- UI: "Revolve" button in sketch + model mode (like extrude), dialog with
  axis pick prompt, angle field, op dropdown, live region highlight.
- RPC: `action.revolve {sketch, at, axis, angle, op}`.

- **Automated**: `tests/m23_revolve.gd` — full-ring volume vs analytic
  (Pappus), partial-angle volume ratio, axis-touching profile watertight,
  hole ring volume, cut/join through BodyBuilder, serialization. RPC
  `tests/rpc/test_revolve.py` — dialog-driven revolve through real input.
- **Manual**: §M23 in `docs/MANUAL_QA2.md`.

## M24 — STL export  (branch: `m24-stl-export`)

The "make a real part" exit ramp: bodies → binary STL (mm units, the 3D
printing default). Exports every visible body or one chosen body; mesh comes
straight from the body list (exact meshes for plain extrudes/revolves,
CSG-baked for booleans), triangles re-wound outward and normals recomputed.
"Export STL" button in model mode + browser body context menu;
`action.export_stl {path, body?}` for automation. ASCII STL as a checkbox
option for diffable output.

- **Automated**: `tests/m24_stl_export.gd` — parse the binary back: header,
  triangle count, volume within tolerance of the body mesh, normals unit
  length and outward; ASCII variant parses; body filter; construction-only
  sketch exports nothing gracefully.
- **Manual**: §M24 in `docs/MANUAL_QA2.md` — print-check an exported STL in
  an external slicer/viewer.

## M25 — DXF import  (branch: `m25-dxf-import`)

Round-trips M21 and reads real-world 2D DXF: LINE, CIRCLE, ARC, POINT,
LWPOLYLINE and R12 POLYLINE/VERTEX/SEQEND (with bulge arcs) from the
ENTITIES section; $INSUNITS-aware scaling to mm (default mm; inches
honored); layer CONSTRUCTION → construction flag. Import creates a NEW
sketch feature on a chosen origin plane (XY default), one undo step.
Endpoints within tolerance weld into shared SketchPoints so imported
profiles extrude immediately. "Import DXF" button (file dialog) +
`action.import_dxf {path, plane?}`.

- **Automated**: `tests/m25_dxf_import.gd` — export→import census identical
  (lines/arcs/circles/points, construction flags, coordinates); inch-unit
  file scales ×25.4; polyline-with-bulge becomes lines+arcs welded into a
  loop; profile detection finds the imported loop; malformed file → error,
  document untouched. RPC `tests/rpc/test_dxf_import.py`.
- **Manual**: §M25 in `docs/MANUAL_QA2.md` — import a file exported from
  another CAD.

---

## Milestone order rationale

Automation API lands at M3, before any drawing tool, so every tool ships with
RPC tests from day one. Arc precedes the constraint palette because tangency is
the hard solver work. Slot comes after dimensions since its variants are
dimension-driven. Timeline UI is late but the *data model* is feature-based
from M1 — the UI is a view over structures that already exist.
