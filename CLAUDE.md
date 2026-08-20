# EchoCAD

Fusion 360–style parametric CAD in Godot 4.7. Phase 1: constrained/dimensioned
2D sketches on planes in a 3D viewport, feature timeline. Read `docs/PLAN.md`
(architecture + locked decisions), `docs/MILESTONES.md` (M0–M12, one git branch
each), `docs/TESTING.md` (test strategy + automation RPC spec) and
`docs/THEMING.md` (theme file format) before working.

## Commands

```bash
GODOT=/nix/store/9zi5r792h6gab0zw3z4xcmydgzjzdird-godot-4.7.1/bin/godot4.7.1

tools/run_tests.sh              # all headless tests; FAIL <name> per failure
tools/run_tests.sh m04          # filter by substring
HEADLESS=1 tools/run_rpc_tests.sh   # RPC suites (HEADLESS=1 when unattended)
"$GODOT" --headless --path . --script res://tests/<t>.gd   # single test, see output
"$GODOT" --path .               # run app windowed
"$GODOT" --path . --editor --quit --headless   # REQUIRED once after adding any class_name
```

Windows: the repo is self-contained — the vendored addons ship Linux AND
Windows x86_64 binaries, so clone + open in Godot 4.7 just works. Runners:
`tools\run_tests.ps1` / `tools\run_rpc_tests.ps1` (set `$env:GODOT` to the
Godot 4.7 exe if it is not on PATH; RPC tests need Python 3).
macOS/web still require binaries built in the sibling repos first.

## Rules

- Internal canonical unit is **mm**; default display unit is inch. Unit
  conversion happens only at the UI boundary — model, solver, commands, and
  RPC queries always speak mm.
- Sketch geometry is typed entities (SketchPoint/Line/Arc/Circle), never
  bezier paths. Bezier conversion only at the render boundary (RenderBridge).
- Every model mutation goes through a Command on the CommandStack; continuous
  gestures merge via CmdMergeBatch into one undo step (including their
  constraint re-solve).
- Only `src/render/render_bridge.gd` may touch `TVGCanvas`.
- **No hardcoded UI colors/sizes.** Every color, font size and chrome metric
  comes from the active theme file via `ThemeService.col/metric/font_size`
  (see `docs/THEMING.md`). New roles get a `FALLBACK_*` entry + a doc line;
  colors baked into materials are rebuilt in the owner's `apply_theme()`.
  Controls opt into the named type variations (`ToolButton`, `HudPanel`,
  …) instead of carrying `add_theme_*_override` literals.
- **Hover feedback is mandatory on every pick stage.** Any tool step that
  waits for the user to click something (profile, path, axis, plane, face,
  edge, body...) MUST pre-highlight the candidate under the cursor on mouse
  motion before the click — in every NEW tool and every UPDATED tool, no
  exceptions. A pick stage without hover feedback is a bug.
- Tests: `extends SceneTree`, `quit(0 if ok else 1)`, failures via
  `push_error`. Success prints `"<NAME> OK: <desc>"`.
- Milestone work happens on its `mNN-*` branch; merge to `main` only with
  tests green + manual QA section signed off in `docs/MANUAL_QA.md`.

## Reference projects (read-only siblings)

- `../echo_vector` — port source for solver (`src/model/ev_constraint_solver.gd`),
  DOF (`ev_constraint_dof.gd`), geometry kernel, command stack, tool protocol,
  snap engine. Its `docs/CAD.md` + `docs/HANDOFF.md` explain the designs.
- `../godot-thorvg`, `../godot-geometry` — source of the vendored
  `addons/thorvg` and `addons/geometry` GDExtensions (Linux/Windows x86_64
  binaries; rebuild happens in those repos, then re-copy the addon folder).
