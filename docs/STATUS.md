# EchoCAD — Status

Updated: 2026-08-16. Milestones M0–M13 implemented and merged to `main`.
Automated coverage: 29 headless tests (`tools/run_tests.sh`) + 10 RPC
suites (`tools/run_rpc_tests.sh`), all green (run RPC suites HEADLESS=1
when unattended — windowed runs on a live desktop flake from real mouse
interference). Manual QA sections in `docs/MANUAL_QA.md`: §M2–§M12 hand
signed off 2026-08-15/16.

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
| M15 project | merged | linked projections, source-follow, broken-link handling |
| M16 threaded solver | merged | drag re-solves on a worker thread, newest-only |
| M17 per-DOF drag | merged | drags project onto remaining freedom (rails) |

## Known limitations / phase-2 backlog

- Extrude has no hole support (nested loops are separate profiles); no
  boolean joins/cuts between solids.
- Offset creates unconstrained copies (no offset constraint yet); chains
  offset one entity at a time.
- Trim prunes constraints on split entities rather than remapping them.
- Solver is damped iterative projection — adequate through slot-driving, but
  planegcs (vendored via the godot-geometry SConstruct pattern) is the
  designated fallback if convergence quality hits a wall.
- Rectangle/center-rect don't yet emit a center point or symmetry; center
  rect type-in measures full size (documented in tool).
- No DXF/PDF export; no marquee (rubber-band) selection; parameters dialog
  is RPC-only (action.set_parameter) — no editor window yet.
- macOS/web builds need addon binaries built in the sibling repos first.

## Flakes to watch

- One windowed RPC suite run failed once (unreproduced on the very next
  runs); if it recurs, capture which test with
  `tools/run_rpc_tests.sh 2>&1 | tee /tmp/rpc.log`.
