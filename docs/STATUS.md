# EchoCAD — Status

Updated: 2026-08-17. Milestones M0–M21 implemented and merged to `main`.
Automated coverage: 38 headless tests (`tools/run_tests.sh` /
`tools\run_tests.ps1`) + 14 RPC suites (`tools/run_rpc_tests.sh` /
`tools\run_rpc_tests.ps1`), all green on Windows (run RPC suites HEADLESS=1
when unattended — windowed runs on a live desktop flake from real mouse
interference).

Manual QA in `docs/MANUAL_QA.md`: §M2–§M12 signed off 2026-08-15/16;
§M14–§M17 hand-tested 2026-08-16 — the remaining §M17 item-5 note (badge
flashing "invalid" while dragging a point-on point) was root-caused and
fixed 2026-08-17 (badge state now frozen during live gestures; applying
Point-On no longer inflates the circle — see §M17 fix 5b) and awaits
retest. §M18–§M21 (new) are PENDING sign-off.

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

## Known limitations / backlog

- Extrude booleans pick their targets by AABB overlap (join/cut hit every
  body whose bounds touch the prism) — no explicit target-body picker yet.
- CSG-baked (boolean) bodies have no edge-line overlay surface; plain
  new-body solids keep it.
- Offset constraints are Fusion-lite: parallels + one driving gap dimension,
  not a rigid whole-chain offset constraint; the copy keeps some freedom.
- Trim drops length-type constraints (EQUAL/dimensions) on split lines by
  design; only directional/radial/tangent constraints retarget.
- Solver is damped iterative projection — adequate so far; planegcs
  (vendored via the godot-geometry SConstruct pattern) remains the fallback
  if convergence quality hits a wall.
- No DXF *import*; export is R12 lines/arcs/circles/points (no splines,
  no dimensions/annotations).
- macOS/web builds need addon binaries built in the sibling repos first.

## Flakes to watch

- One windowed RPC suite run failed once (unreproduced); if it recurs,
  capture which test with `tools/run_rpc_tests.sh 2>&1 | tee /tmp/rpc.log`.
