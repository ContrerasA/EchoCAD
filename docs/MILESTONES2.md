# EchoCAD — Milestones, volume 2 (M26–M35) — DRAFT

Same rules as `docs/MILESTONES.md`: one branch per milestone (`m26-…`),
merged to `main` only with headless tests + RPC tests green and the manual
section signed off in `docs/MANUAL_QA2.md`. Internal unit stays mm; unit
conversion only at the UI boundary.

## Where the project is now

M0–M25 merged: full constrained 2D sketching (line/rect/circle/arc/slot,
trim/extend/offset/mirror/fillet, dimensions + parameters, marquee), feature
timeline, construction planes + sketch-on-face, extrude + revolve with
booleans (Godot CSG), threaded solver with per-DOF drag, DXF export/import,
STL export, TCP JSON-RPC automation with 18 Python suites + 43 headless
tests. Open debt before starting volume 2: MANUAL_QA §M18–§M21 and
MANUAL_QA2 §M22–§M25 sign-off, §M17 item-5b retest.

## Scope of volume 2

Two tracks, interleaved:

1. **App polish** — the UI grows from "engineer panel" to product: tool
   shelf + icons + themes, camera projection modes, look-at, unit switching,
   measure.
2. **Modeling depth** — sketch splines and patterns, reference images and
   SVG import, body transforms, solid mirror/patterns, sweep, loft,
   3D fillet/chamfer.

Out of scope for this volume (M36+ backlog, see end): shell/thicken, hole
wizard, sketch text, section views, drawings/sheets, 3MF/STEP, assemblies.

## Tooling needed to get there

- **Nothing new for M26–M33.** Godot themes + SVG-imported icon textures
  cover the UI work; existing CSG covers booleans; the SVG importer is a
  pure-GDScript parser modeled on `dxf_importer.gd`.
- **Sweep/loft/fillet (M34–M35)**: mesh generation in GDScript feeding the
  existing BodyBuilder "solid-feature part" protocol (exact mesh + CSG node
  + AABB). No new addon *required*; if robustness stalls (self-intersecting
  sweeps, fillet blends), the escape hatch is extending the vendored
  `godot-geometry` addon with the Manifold library (rebuild in the sibling
  repo, re-copy `addons/geometry`).
- **SVG path extraction alternative**: `godot-thorvg` already parses SVG
  (`load_svg_file`) but exposes no path getter; if the GDScript parser
  proves insufficient, add `get_svg_paths(handle)` to the addon instead.
- Solver: splines add fit points as ordinary solver points — damped
  projection expected to hold; planegcs remains the fallback.

---

## M26 — Tool shelf, icons, themes  (branch: `m26-ui-shell`)

The UI stops being buttons-in-a-row. Ships:

- **Icon set** — monochrome SVG icons (Godot imports SVG natively) for every
  existing tool/action; one source folder, tinted by theme so a single set
  serves light and dark.
- **Tool shelf** — Fusion-style grouped toolbar per mode: Sketch mode gets
  Create / Modify / Constraints / Dimension groups, model mode gets Solids /
  Construct / Inspect / Export. Collapsible groups, tooltips with shortcut
  labels, overflow menu on narrow windows. Tool activation still goes
  through the existing ToolManager — the shelf is a view.
- **Theme (light / dark)** — two Godot `Theme` resources + a viewport
  palette (background, grid, sketch line/construction/selected/constrained
  colors, badge colors) that RenderBridge reads from one ThemeService.
  Toggle in a new Preferences dialog, persisted in `user://settings.cfg`.

- **Automated**: `tests/m26_ui_shell.gd` — every registered tool has a shelf
  entry + icon resource; theme switch flips theme resource and viewport
  palette; settings persist across restart (write + reload). RPC
  `tests/rpc/test_ui_shell.py` — activate tools through shelf buttons via
  human-like clicks.
- **Manual**: §M26 — visual pass over both themes, hover states, tooltips.

## M27 — Viewing: projection, look-at, units, measure  (branch: `m27-viewing`)

Camera + inspection quality-of-life:

- **Perspective / orthographic** toggle (keyboard + view-cube context menu),
  framing preserved on switch (fit distance from frustum height). Ortho is
  the CAD default going forward; persisted per preferences.
- **Look At** — pick a face / construction plane / sketch and the camera
  animates to look straight down its normal (reuses the M14 cube-face
  return math). Also "Fit" (F) framing all visible bodies/sketches.
- **Named views** — save/restore camera bookmarks (browser folder), plus
  the existing home view.
- **Change units** — document display unit: mm / cm / m / in / ft. Only the
  UI boundary changes (dimension labels, type-in fields, status bar,
  Parameters dialog); model/RPC stay mm. Unit picker in Preferences +
  document setting saved in `.ecad`.
- **Measure tool** — model + sketch mode: point↔point distance, edge
  length, angle between edges/faces, circle/arc radius; body volume + AABB
  readout in a body properties popup (data already available via RPC).

- **Automated**: `tests/m27_viewing.gd` — ortho/persp switch preserves
  screen-space size of a probe at pivot; look-at aligns camera axis to face
  normal; unit switch changes formatted labels but not stored mm; measure
  math (distance/angle/radius) against analytic values. RPC
  `tests/rpc/test_viewing.py` — toggle projection, look-at a face, measure
  two points, query displayed unit.
- **Manual**: §M27.

## M28 — Sketch splines  (branch: `m28-splines`)

Bezier curves as first-class typed sketch geometry (rule intact: typed
entities in the model, bezier flattening only at boundaries):

- **SketchSpline** — cubic bezier chain through N fit points; each fit point
  is a real SketchPoint (draggable, constrainable, dimensionable); tangent
  handles stored per fit point, editable by drag, with smooth (G1) default
  and a per-point corner toggle.
- Solver: fit points participate like any point; handle drags merge via
  CmdMergeBatch. Tangent constraint between a spline end and a line/arc.
- Boundaries: RenderBridge draws the exact bezier; ProfileFinder and mesh
  paths consume an adaptive tessellation (chord tolerance in mm); DXF export
  writes the tessellation as LWPOLYLINE (documented); STL/extrude/revolve
  just work through the tessellation.
- Spline tool: click fit points, Enter/double-click to finish, Esc rules as
  other tools. Trim/extend/offset on splines explicitly refused with a
  status hint (documented limitation this volume).

- **Automated**: `tests/m28_splines.gd` — fit-point interpolation, G1
  continuity at smooth points, tessellation chord error under tolerance,
  constraint on a fit point solves, closed-spline profile extrudes to a
  plausible volume, serialization round-trip. RPC
  `tests/rpc/test_splines.py` — draw a spline through real input, drag a
  handle, extrude the closed profile.
- **Manual**: §M28.

## M29 — Sketch patterns, chamfer, polygon  (branch: `m29-sketch-patterns`)

Rounds out the 2D toolbox:

- **Rectangular pattern** — select entities, rows × cols with spacing
  dimensions; Fusion-lite like M19 offset: copies + two driving dimensions
  (row/col spacing) + count stored on a pattern group for later edit.
- **Circular pattern** — count + total angle around a picked center point.
- **Sketch chamfer** — two-line corner → chamfer line at distance (equal
  distance this round), sibling of the M10 fillet tool including the
  constraint upkeep rules.
- **Polygon tool** — inscribed/circumscribed n-gon (extra; cheap once
  patterns exist: it is a circular pattern of one edge).

- **Automated**: `tests/m29_sketch_patterns.gd` — pattern counts/positions,
  spacing dimension drives all copies, circular pattern angles, chamfer
  length + constraint retargeting mirrors fillet tests, polygon vertex
  math, undo collapses each pattern to one step. RPC
  `tests/rpc/test_sketch_patterns.py`.
- **Manual**: §M29.

## M30 — Reference images  (branch: `m30-ref-image`)

Trace-over workflow, the on-ramp for reverse-engineering real parts:

- **CanvasImageFeature** — PNG/JPEG placed on any plane (origin, offset, or
  face plane), rendered as a textured quad under sketch geometry. Image
  bytes embedded base64 in `.ecad` so documents stay portable.
- **Move / rotate / scale** by dragging handles; numeric width field.
- **Calibrate** — click two points on the image, type the real distance
  (unit-suffixed); whole image rescales about the first point. This is the
  "scale reference image" feature.
- Opacity slider, lock toggle (locked = not pickable), browser row under a
  "Canvases" folder with eye/lock, timeline chip, delete/undo/suppress.

- **Automated**: `tests/m30_ref_image.gd` — placement transform on each
  plane kind, calibrate math (two picks + distance → scale factor),
  serialization round-trips bytes + transform, locked image excluded from
  picking, suppress hides quad. RPC `tests/rpc/test_ref_image.py` — import,
  calibrate via clicks, query resulting size.
- **Manual**: §M30 — trace a photographed part, check draw-over feel.

## M31 — SVG import  (branch: `m31-svg-import`)

Second 2D interchange path (after DXF), aimed at logos/gaskets/laser work:

- Pure-GDScript SVG parser (mirrors `dxf_importer.gd`): XMLParser over
  `path` (`d` with M/L/H/V/C/S/Q/T/A/Z), `rect`, `circle`, `ellipse`,
  `line`, `polyline`, `polygon`; nested `transform` (translate/scale/
  rotate/matrix); `viewBox` + width/height units → mm (px at 96 dpi
  default, mm/in honored).
- Mapping: straight segments → SketchLine, arcs (`A`) → SketchArc, bezier
  segments (C/S/Q/T) → SketchSpline (M28 dependency); endpoint weld into
  shared SketchPoints like DXF so closed profiles extrude immediately.
- Import creates a NEW sketch feature on a chosen plane, one undo step;
  scale dialog (native size vs target width). "Import SVG" button +
  `action.import_svg {path, plane?, width?}`.
- Fallback documented: if the GDScript parser hits real-world files it
  can't handle, extend `godot-thorvg` with `get_svg_paths()` instead.

- **Automated**: `tests/m31_svg_import.gd` — hand-authored SVGs: rect +
  circle census, path with arcs + beziers lands as lines/arcs/splines
  welded closed, transforms compose, viewBox scaling to mm, malformed file
  → error with document untouched, imported profile extrudes. RPC
  `tests/rpc/test_svg_import.py`.
- **Manual**: §M31 — import an Inkscape and an Illustrator export.

## M32 — Move / copy bodies, appearance  (branch: `m32-move-bodies`)

"Move shape" plus body-level management:

- **TransformFeature** — timeline feature holding a body id + translation +
  rotation (axis/angle); parametric and editable like extrude. Applied by
  BodyBuilder after the body's boolean chain resolves. Point-to-point move
  (pick source vertex, pick destination) and free drag with axis-snap
  gizmo; numeric fields for exact offsets.
- **Copy body** — duplicate a body as a new independent body (its features
  re-rooted), optionally moved in the same gesture.
- **Appearance** — per-body color (albedo) in the browser context menu,
  serialized; groundwork for later materials. (Extra.)
- Known-limitation note carried forward: moved bodies still participate in
  AABB-targeted booleans; the explicit target-body picker stays backlog.

- **Automated**: `tests/m32_move_bodies.gd` — transform applied to mesh +
  AABB, edit replays downstream, copy is independent (editing source
  doesn't touch copy), color serialization, undo. RPC
  `tests/rpc/test_move_bodies.py` — gizmo drag through human-like input,
  point-to-point snap, query AABB.
- **Manual**: §M32.

## M33 — Solid mirror + patterns  (branch: `m33-solid-patterns`)

The mass-production features; all three consume and emit through
BodyBuilder's part protocol so booleans keep working:

- **Mirror feature** — mirror bodies (or solid features) across an origin /
  construction plane; result merges (Join) or lands as new body.
- **Rectangular pattern** — bodies or solid features, 1–2 directions
  (direction = plane axis or edge), count + spacing in mm.
- **Circular pattern** — around an axis (revolve-style axis pick: line
  entity or plane axis), count + total angle.
- Pattern instances render as mesh instances of the source part (cheap),
  bake through CSG only when a boolean touches them. Timeline chips edit
  count/spacing; suppress hides all instances.

- **Automated**: `tests/m33_solid_patterns.gd` — mirrored volume equal +
  reflected AABB, pattern instance count/placement, pattern of a Cut
  feature subtracts at every instance, edit count replays, serialization.
  RPC `tests/rpc/test_solid_patterns.py`.
- **Manual**: §M33.

## M34 — Sweep + loft  (branch: `m34-sweep-loft`)

The two remaining bread-and-butter solid features; both are GDScript mesh
generators plugging into the M23 "solid-feature part" protocol:

- **Sweep** — profile region (extrude-style anchor uv) + path: a connected
  chain of lines/arcs/splines in another sketch, picked by click. Frames by
  parallel transport along the tessellated path (no twist), profile
  re-sectioned per frame, caps at both ends; holes sweep as inner wall
  loops. New Body / Join / Cut via CSGMesh. Self-intersection (bend radius
  < profile extent) detected and refused with a clear error.
- **Loft** — 2+ profile regions on different planes/faces picked in order;
  boundary loops resampled to a common vertex count, matched by nearest
  centroid-angle to avoid twist; ruled side walls, triangulated caps.
  Straight-line correspondence this round (no guide rails — documented).
- Both: dialog like extrude/revolve, timeline chips, RPC
  `action.sweep {profile_sketch, at, path_sketch, path_at, op}` /
  `action.loft {sections: [{sketch, at}…], op}`.

- **Automated**: `tests/m34_sweep_loft.gd` — straight-path sweep volume ==
  extrude of same profile, L-path sweep volume vs analytic, circle-to-circle
  loft == cone frustum volume, watertightness (edge manifold check),
  refusal on too-tight bend, booleans, serialization. RPC suites for both.
- **Manual**: §M34.

## M35 — 3D fillet + chamfer  (branch: `m35-fillet-chamfer`)

Prismatic-scope edge treatments — honest about what mesh CSG can do
without a B-rep kernel:

- Scope: edges of **extruded** bodies. Two edge classes:
  - *Lateral edges* (parallel to extrude direction): fillet/chamfer stored
    as per-corner radius/distance on the feature; applied by rounding /
    cutting the profile polygon corners before extrusion (exact, cheap,
    parametric — replays like everything else).
  - *Cap edges* (top/bottom rim): chamfer = loft between the profile and
    its inset offset (Clipper-style polygon offset in GDScript); fillet =
    quarter-round ring of loft sections (M34 machinery reused).
- Edge picking: hover highlights an edge chain on the body; click adds it
  to an EdgeTreatFeature (kind fillet|chamfer, radius/distance in mm).
  Revolve/sweep/loft edges and boolean-seam edges refused with a status
  hint this round — the general case is exactly the planegcs/Manifold-tier
  kernel work tracked in the backlog.
- RPC: `action.fillet_edges {body, edges, radius}` /
  `action.chamfer_edges {body, edges, distance}`.

- **Automated**: `tests/m35_fillet_chamfer.gd` — lateral fillet volume vs
  analytic (box minus corner quarter-cylinders), chamfer volume, cap
  fillet volume within tolerance, watertight after treatment, parametric
  edit replays, refusal on unsupported edges, serialization. RPC
  `tests/rpc/test_fillet_chamfer.py`.
- **Manual**: §M35 — fillet a real bracket, export STL, slice it.

---

## Milestone order rationale

UI shell first (M26–M27): every later feature ships its buttons into a shelf
that exists, and manual QA of the modeling milestones happens in the themed,
ortho-capable viewport users will actually run. Splines (M28) unlock SVG
import (M31) and better sweep paths (M34). Reference images (M30) precede
SVG so the "trace a part" and "import the vector" workflows land adjacent.
Body transforms (M32) precede solid patterns (M33) because patterns reuse
the instance-placement machinery. Sweep/loft (M34) precede fillet (M35)
because cap fillets are built from loft rings.

## M36+ backlog (not scheduled)

- Explicit target-body picker for booleans (carried from volume 1).
- Shell/thicken feature; hole wizard (counterbore/countersink/tap sizes).
- Sketch text (font outlines → profiles).
- Section view (clip plane) + interference check.
- 3MF export; STEP requires a real B-rep kernel — decision point with
  Manifold/planegcs escalation.
- Drawing sheets (2D projections + dimensions → DXF/PDF).
- Autosave + crash recovery, recent-files list, document tabs.
- Keyboard shortcut editor; edge-line overlay for CSG-baked bodies
  (carried); rigid whole-chain offset constraint (carried).
