# EchoCAD — Status

Updated: 2026-08-15. All planned milestones M0–M12 implemented and merged to
`main`. Automated coverage: 20 headless tests (`tools/run_tests.sh`) + 10 RPC
suites (`tools/run_rpc_tests.sh`), all green. Manual QA sections §M2–§M12 in
`docs/MANUAL_QA.md` are written but PENDING hand sign-off.

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
