# EchoCAD — Plan

Fusion 360–style parametric CAD built in Godot 4.7. Phase 1 (this plan): fully
dimensioned, constrained 2D sketches with a feature timeline, living on planes in a
real 3D viewport. Phase 2: extrude/modify into solids.

## Locked decisions

| Decision | Choice |
|---|---|
| Foundation | Fresh project. Cherry-pick proven modules from `../echo_vector` (solver, DOF, geometry kernel, command stack, tool protocol, snap engine, test harness pattern). No wholesale fork — we skip the 5.5k-line `editor_root.gd` god object and the Illustrator feature set. |
| Sketch data model | **Typed entities** — `SketchPoint`, `SketchLine`, `SketchArc`, `SketchCircle` — not bezier paths. Arcs/circles are first-class solver citizens (center/radius/endpoints are solver variables). Bezier conversion happens only at the render boundary. |
| Constraint inference | **Fusion-style auto-inference while sketching** (H/V, coincident, tangent, parallel, perpendicular, midpoint) with glyph preview before commit. Toggleable. This deliberately reverses echo_vector's "explicit only" principle. |
| Timeline | **Feature timeline from day one.** Document = ordered feature list (`Sketch1`, `Sketch2`, later `Extrude1`…). Rollback marker; editing a rolled-back feature replays downstream. Undo/redo is a separate layer on top (command stack), and timeline operations themselves are undoable commands. |
| Units | Internal canonical unit = **mm** (stored numbers). Default *display* unit = **inch**. Unit conversion only at UI boundary (echo_vector `unit_converter.gd` pattern). All numeric inputs accept unit suffixes (`1.5in`, `10mm`) and expressions. |
| 3D shell | **Early** (M2). Sketches live on planes in 3D space. Orbit camera + view cube in model mode; entering a sketch locks the camera normal to the sketch plane and switches to 2D editing UI, exactly like Fusion. |
| Testing | **Two layers.** (a) In-process headless `SceneTree` test scripts (echo_vector pattern — exit code is the assertion) for fast CI. (b) An `AutomationServer` (TCP JSON-RPC autoload) so external runners launch the real app, inject human-like input, query document state, take screenshots, and compare against expected results. |
| Slot tool | All three Fusion variants: center-to-center, overall, center-point. |
| Rendering | Sketch-mode artwork rendered by ThorVG (`TVGCanvas`) to a texture, re-rasterized on view change (always crisp — echo_vector `CanvasView` pattern). Editor chrome (handles, glyphs, dimensions, previews) drawn on a screen-space `Control` overlay. 3D-mode sketch display uses simple line meshes. |
| Undo | Custom command stack with gesture merge batches, ported from echo_vector (`command.gd`, `command_stack.gd`, `cmd_merge_batch.gd`). A drag plus its constraint re-solve = one undo step. |

## Reference projects

- `../echo_vector` — primary reference. Working 22-type constraint solver
  (`src/model/ev_constraint_solver.gd`), DOF analysis with numeric Jacobian
  (`ev_constraint_dof.gd`), dimension annotations (`src/app/constraint_overlay.gd`),
  parameters/expressions, snap engine, command stack, tool protocol, and a
  115-file headless test suite. Its docs (`docs/CAD.md`, `docs/DESIGN.md`,
  `docs/HANDOFF.md`) explain every design decision.
- `../godot-thorvg` — `addons/thorvg` GDExtension: `TVGCanvas` retained-mode CPU
  vector rasterizer + `TVGShapes` path generators (arcs/circles via cubics).
  Prebuilt Linux/Windows x86_64. Copy the addon folder in verbatim.
- `../godot-geometry` — `addons/geometry` GDExtension: `GeometryOps` — Skia
  path booleans (curve-preserving), Clipper2 offset/stroke-to-fill. Needed later
  for profile ops and offset; also the vendoring template if we ever need a C++
  solver (planegcs) or mesher.

## Architecture

```
src/model/       Sketch entities, constraints, geometry kernel, units
src/solver/      Constraint solver + DOF analysis (ported & extended from echo_vector)
src/features/    Feature base, SketchFeature, Timeline (ordered list + rollback/replay)
src/commands/    Command, CommandStack, CmdMergeBatch + concrete commands
src/tools/       Tool base, ToolManager, one file per drawing/modify tool
src/render/      RenderBridge (only code touching TVGCanvas), overlays, 3D sketch meshes
src/app/         App root, 3D viewport, view cube, sketch-mode UI, panels, snap engine
src/automation/  AutomationServer (TCP JSON-RPC), input injection, state queries
src/io/          Serializer (.ecad versioned JSON, cumulative migrations)
tests/           Headless SceneTree scripts (unit + UI-flow)
tests/rpc/       Python client + RPC test scripts + golden files
docs/            This plan, milestones, testing spec, manual QA checklist
```

### Sketch model

- `SketchEntity` base: stable id (`"e<n>"`, never reused), `construction: bool`.
- `SketchPoint {pos}` — every line/arc endpoint and every center is a real point
  entity. Coincidence is a constraint linking points (echo_vector handle model),
  not a topological merge.
- `SketchLine {p0, p1}` (point refs), `SketchArc {center, start, end, ccw}`,
  `SketchCircle {center, radius}`.
- Slot = composite geometry (2 lines + 2 arcs + tangent/equal/coincident
  constraints) plus a `slot_meta` record so its defining dimensions stay editable —
  same approach as echo_vector `shape_meta`.
- Constraint vocabulary ported from `EVConstraint` (22 types: coincident, H/V,
  parallel, perpendicular, collinear, equal, midpoint, concentric, tangent,
  symmetry, fix, point-on-entity + dimensional distance/x/y/angle/radius/
  diameter/line-dist/point-line-dist), with refs retargeted to typed-entity
  handles. `driven` flag and `expr` supported from the start.
- Parameters: named, unit-tagged, expression-backed (`EVParameter`/`EVExpression`
  port — whitelisted Godot `Expression`).

### Solver

Port `ev_constraint_solver.gd` (iterative projection, bounded rounds, graceful
over-constraint) and `ev_constraint_dof.gd` (numeric Jacobian → rank → DOF,
redundant/conflict detection). Extend for typed entities: radius as a solver
variable, arc endpoint/center coupling, line-arc and arc-arc tangency, and
rotation of rigid groups (echo_vector's known gap). If iterative projection hits
a quality wall, fallback plan is vendoring planegcs as a GDExtension using the
godot-geometry SConstruct pattern — the model/solver seam (`solve(entities,
constraints, pinned) -> new positions`) is kept narrow to allow that swap.

### Feature timeline

- `Feature { id, name, suppressed }`; `SketchFeature { plane, entities,
  constraints }`.
- `Timeline` owns the ordered features + rollback marker. Document state =
  replay of features up to the marker.
- Editing a sketch = enter sketch mode on that feature; on exit, downstream
  features replay.
- All timeline mutations (add/rename/suppress/rollback/reorder) are commands on
  the undo stack.

### Modes (Fusion parity)

- **Model mode**: 3D viewport, orbit/pan/zoom, view cube, origin planes visible,
  timeline bar at bottom. "Create Sketch" → pick plane → sketch mode.
- **Sketch mode**: camera locked normal to plane, 2D grid, sketch toolbar
  (Line L / Rectangle R / Circle C / Arc A / Slot S / Point / Dimension D /
  constraint palette), "Finish Sketch" button. Esc cancels current tool gesture,
  then deselects, then (on empty state) offers finish.

### Automation API (summary — full spec in TESTING.md)

Autoload `AutomationServer`, off by default, enabled via `--automation-port=<n>`
CLI arg or env var. Line-delimited JSON over TCP. Command families:

- `input.*` — pointer move/down/up/click/drag with human-like interpolated paths
  (configurable speed/steps), key press/type. Injected through
  `Input.parse_input_event` so the real input pipeline runs.
- `query.*` — document as JSON, entities, constraints, DOF summary, selection,
  active tool, mode, world↔screen transforms, timeline state.
- `action.*` — activate tool, set pref, open/save document, enter/exit sketch,
  timeline ops (for setup steps that aren't under test).
- `app.*` — screenshot (PNG path or base64), window size, quit.

Every response: `{ id, ok, result | error }`. Test runner is a small Python
client (`tests/rpc/client.py`) + per-test scripts comparing returned state to
golden JSON and screenshots to references.

## Fusion behaviors adopted (quick reference)

- Auto-constrain while sketching with glyph cues; snapping shows the inferred
  constraint before the click commits it.
- Smart Dimension (`D`): infers dimension type from what's selected/picked
  (point-point → distance, line → length, two lines → angle or gap, circle →
  diameter, arc → radius). Dimension label follows cursor until parked.
- Fully constrained geometry turns from blue (free) to black/green (locked);
  status readout shows remaining DOF / "Fully constrained".
- Dimensions accept expressions and named parameters (`width/2 + 0.25in`).
- Driven (reference) dimensions.
- Construction toggle (`X` key) — dashed rendering, excluded from profiles.
- Feature timeline with rollback + edit-and-replay.
- Rectangle creates 4 lines + auto H/V + coincident corners (it is *made of*
  lines/constraints, not a rect primitive).
