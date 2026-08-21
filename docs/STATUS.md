# EchoCAD — Status

Updated: 2026-08-20. M0–M36 + the CHANGES round + **M38 (Manifold kernel)**
+ **M39 (face identity, explicit targets, feature dialogs)** + **M40
(extrude extents/taper, chip editing, hole wizard)** + **M41 (fillet /
chamfer on any edge)** + **M42 (shell, combine, split, press-pull)** + **M43 (inspection)** + **M44 (3MF / mesh import / OBJ / SVG)** + **M46 (document safety)** + **M47 (incremental rebuild + fuzz)** + **M48 (UX: body context menu,
double-click edit, rename, shortcut sheet)** + **M49 (release
engineering: version, presets, CI, samples, user guide)** on `main`; M45
(components) deferred past the alpha. **M50 (alpha gate) is manual QA:**
`docs/MANUAL_QA3.md` §M38–§M50 await sign-off before tagging
`v0.1.0-alpha`. Volume 3 (`docs/MILESTONES3.md`, M38–M50 + polish rounds) is the
alpha plan; manual QA for it lives in `docs/MANUAL_QA3.md`. Solids are now
computed by Manifold (`MeshSolid` in `addons/geometry`): exact booleans
(no more EPS-inflated cuts), synchronous rebuilds, face ids on every
triangle, edge overlay on every body, per-feature rebuild errors shown as
red timeline chips. M39: TopoRef face references (sketch-on-face planes
follow their face; lost refs are amber warning chips), explicit boolean
targets + Intersect, one ordered BodyBuilder pass (moves before cuts
count, pattern/mirror of a cut feature re-cuts per instance), and the
shared `FeatureDialog` shell (docked top-right, inline errors, Pick…
rows) behind Extrude/Revolve/Sweep/Loft/Pattern/Mirror. M40: extrude
extents (symmetric, two-sided, to object, to next, through all) + taper,
every extrude/hole editable from its chip, Hole wizard (simple /
counterbore / countersink, ISO + unified tables, through/blind, drill
tip, cosmetic or modelled thread) with face pick + snapping placement.
M41: fillet/chamfer any edge chain of any body (hole rims, concave
edges, ball corners), edit from the chip. M42: shell (inside/outside, open faces), combine, split by plane/face,
press-pull. M43: mass properties + materials, section analysis,
interference, print check, model-mode measure. M44: 3MF + OBJ export, STL/OBJ/3MF import as bodies, SVG sketch export.
M46: autosave + crash recovery, unsaved guard, recent files, start panel,
newer-schema refusal. M47: incremental rebuild from per-feature
snapshots. M49: samples + release scaffolding. 73 headless tests + 35
RPC suites green.

Earlier history: M0–M25 implemented and merged to `main`.
Volume 2 (M26–M35, `docs/MILESTONES2.md`) is IMPLEMENTED on a chain of
branches (m26-ui-shell → … → m35-fillet-chamfer, each atop the previous)
with 54 headless tests + 28 RPC suites green at the tip; merges to `main`
wait on the §M26–§M35 manual QA sign-offs in `docs/MANUAL_QA2.md`.
Automated coverage: 43 headless tests (`tools/run_tests.sh` /
`tools\run_tests.ps1`) + 18 RPC suites (`tools/run_rpc_tests.sh` /
`tools\run_rpc_tests.ps1`), all green on Windows (run RPC suites HEADLESS=1
when unattended — windowed runs on a live desktop flake from real mouse
interference).

Manual QA: `docs/MANUAL_QA.md` (closed volume, §M2–§M21) — §M2–§M12 signed
off 2026-08-15/16; §M14–§M17 hand-tested 2026-08-16, §M17 item-5b fix
awaits retest; §M18–§M21 PENDING sign-off. `docs/MANUAL_QA2.md` (volume 2,
M22 onward) — §M22–§M25 PENDING sign-off.

Windows: self-contained — vendored addons carry Linux + Windows x86_64
binaries. The PS runners were hardened 2026-08-17 for stock PowerShell 5.1
(encoding, stderr wrapping, Store-stub python resolution). macOS/web
binaries still pending in the sibling repos.

| Milestone | State | Notes |
|---|---|---|
| M0 scaffold | merged | thorvg + geometry addons vendored, runners |
| M1 core model | merged | typed entities, constraints, commands, .ecad |
| M2 3D shell | merged | orbit rig, view cube, plane pick, sketch mode |
| M3 automation API | merged | TCP JSON-RPC, human-like input, Python client |
| M4 line tool | merged | snap engine, H/V/coincident inference |
| M5 rect + circle | merged | type-while-drawing W/H/R fields |
| M6 arcs + solver | merged | 3pt/center/tangent arcs, solver + DOF |
| M7 constraints UI | merged | palette, badges, conflicts, green = done |
| M8 dimensions | merged | smart dimension, expressions, parameters |
| M9 slot | merged | all three Fusion variants |
| M10 modify | merged | trim, extend, offset, mirror, fillet |
| M11 timeline | merged | chips, rollback marker drag, suppress |
| M12 extrude | merged | profile finder, anchored replay, solids |
| M13 Z-up + orbit pivots | merged | Z-up world, roll-free orbit, 3 pivot modes |
| M14 sketch orbit | merged | off-axis orbit inside a sketch, cube-face return |
| M15 project | merged | linked projections, source-follow, broken links |
| M16 threaded solver | merged | drag re-solves on a worker thread, newest-only |
| M17 per-DOF drag | merged | drags project onto remaining freedom (rails) |
| M18 holes + booleans | merged | hole regions, extrude New Body/Join/Cut via CSG |
| M19 modify upkeep | merged | chain offset + constraints, trim retarget, center rect |
| M20 marquee + params | merged | window/crossing bands, Parameters dialog |
| M21 DXF export | merged | R12 writer, layers, mm units, RPC action |
| M22 construction planes | merged | offset/chained planes, sketch on body faces |
| M23 revolve | merged | lathe solids, line/axis pick, booleans via CSG spin |
| M24 STL export | merged | binary + ASCII, per-body / visible bodies, mm |
| M25 DXF import | merged | R12 + LWPOLYLINE/bulge, welds, $INSUNITS, layers |

## Known limitations / backlog

- (closed by M39) booleans may name their targets; Auto keeps the AABB
  rule. Body moves now happen in timeline order, so later booleans see
  the moved body.
- (closed by M38) CSG-baked bodies have no edge-line overlay — every body
  now draws its edges from the kernel mesh.
- Offset constraints are Fusion-lite: parallels + one driving gap dimension,
  not a rigid whole-chain offset constraint; the copy keeps some freedom.
- Trim drops length-type constraints (EQUAL/dimensions) on split lines by
  design; only directional/radial/tangent constraints retarget.
- Solver is damped iterative projection — adequate so far; planegcs
  (vendored via the godot-geometry SConstruct pattern) remains the fallback
  if convergence quality hits a wall.
- DXF export is R12 lines/arcs/circles/points (no splines, no
  dimensions/annotations); import reads the same subset plus polylines —
  text, dimensions, splines, and blocks are skipped with a count. SVG
  export writes splines as polylines.
- STEP import/export is not available (needs a B-rep kernel) — 3MF/STL/
  OBJ are the interchange formats.
- (closed by M39) face planes are parametric TopoRef links; pre-M39
  snapshot planes adopt a matching face on the first rebuild.
- Revolve booleans share extrude's AABB target picking when Targets is
  Auto; pick explicit targets (M39) when the swept AABB is too generous.
- Fillets on free-form faces (sweep/loft walls) are best-effort: the
  sweep follows the mesh normals; very tight or self-intersecting cases
  flag the chip amber instead of applying.
- macOS/web builds need addon binaries built in the sibling repos first.

## Flakes to watch

- One windowed RPC suite run failed once (unreproduced); if it recurs,
  capture which test with `tools/run_rpc_tests.sh 2>&1 | tee /tmp/rpc.log`.
