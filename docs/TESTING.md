# EchoCAD — Testing

Two layers. Both must pass before a milestone branch merges.

## Layer 1 — In-process headless tests

Pattern taken from echo_vector (no framework — custom `extends SceneTree`
scripts, exit code is the assertion):

```gdscript
extends SceneTree
func _init() -> void:
    quit(0 if _run() else 1)

func _run() -> bool:
    # build model / instantiate ui/main.tscn, drive it, assert
    ...
```

- Failures: `push_error("...")` + exit 1. Success prints `"<NAME> OK: <desc>"`.
- Two tiers: pure model tests (document + command stack, no scene) and UI-flow
  tests (instantiate the real main scene, feed synthetic `InputEvent`s to the
  ToolManager).
- Runner: `tools/run_tests.sh` — iterates `tests/*.gd`, `godot --headless
  --path . --script res://tests/<t>.gd`, prints `FAIL <t>` on non-zero exit.
- Gotcha: after adding a `class_name`, run
  `godot --path . --editor --quit --headless` once to register globals.

## Layer 2 — External automation API (RPC)

Simulates a human driving the real app and returns comparable results.

### Transport

- `AutomationServer` autoload. Disabled unless launched with
  `--automation-port=<n>` (also `ECHOCAD_AUTOMATION_PORT` env).
- TCP, line-delimited JSON (one request/response object per line).
- Request: `{ "id": 1, "cmd": "input.click", "args": { ... } }`
- Response: `{ "id": 1, "ok": true, "result": { ... } }` or
  `{ "id": 1, "ok": false, "error": { "code": "...", "message": "..." } }`
- Requests processed on the main thread between frames; long gestures
  (interpolated drags) span frames and reply when finished.

### Command families

**input.** — injected via `Input.parse_input_event` so the real pipeline runs.
- `input.move {to:[x,y], steps?, duration_ms?}` — human-like interpolated path
- `input.down / input.up {button?}`, `input.click {at:[x,y]}`
- `input.drag {from, to, steps?, duration_ms?, modifiers?}`
- `input.key {key, modifiers?}`, `input.type {text}` — for numeric type-in
- Coordinates are window pixels; use `query.world_to_screen` to target model
  positions.

**query.** — read-only, never mutates.
- `query.document` — full document JSON (entities, constraints, params,
  features, timeline marker)
- `query.entities {sketch?}` / `query.constraints {sketch?}`
- `query.dof` — `{rank, dof, fully_constrained, redundant[], conflicts[]}`
- `query.selection`, `query.active_tool`, `query.mode` (model|sketch)
- `query.world_to_screen {p:[x,y]}` / `query.screen_to_world {p:[x,y]}`
  (sketch-plane coordinates, mm)
- `query.timeline`, `query.measure {a, b}` (distance/angle helper)

**action.** — setup shortcuts for steps *not* under test (a test of the line
tool clicks through the UI; a test of trim may use `action.*` to build its
fixture sketch quickly).
- `action.activate_tool {id}`, `action.enter_sketch {plane}`,
  `action.finish_sketch`, `action.new_document`, `action.open {path}`,
  `action.save {path}`, `action.undo`, `action.redo`,
  `action.set_pref {key, value}`, `action.build_fixture {name}` /
  `action.load_fixture {path}`, `action.set_theme {theme}` (M36)
- `query.theme` — active theme id, appearance, catalog of available themes,
  user theme dir (M36)
- `action.hole {body, face, uv:[[u,v]…], diameter?, depth?, extent?,
  hole_type?, cb_*?, cs_*?, tip_angle?, thread_mode?, thread_id?,
  targets?}` — hole wizard feature on a planar face (M40); `query.bodies
  {faces: true}` lists each body's planar faces `{face, normal, point,
  area}` (kernel face ids for `to_face` / holes); `action.extrude` takes
  `extent`, `distance2`, `symmetric_whole`, `taper_deg`, `to_face {body,
  face}`; `action.select_option {name, index}` drives OptionButtons;
  `query.project {p:[x,y,z]}` gives the window pixel of a world point.
- `query.mass_properties {body, material?}`, `query.interference
  {bodies?}`, `action.section {on, plane?, offset?, flip?, body?}`,
  `query.print_check {body, bed?, angle?}` (M43 inspection).
- `action.shell {body, thickness, direction?, remove?:[{body, face}]}`,
  `action.combine {target, tools, operation?, keep_tools?}`,
  `action.split_body {body, plane?}` / `{body, face:{body, face}}`,
  `action.press_pull {face:{body, face}, distance}` (M42).
- `action.edge_fillet {body, treat, size, near:[[x,y,z]…]}` — fillet /
  chamfer the edge chains nearest each point (M41); `query.edges {body}`
  lists a body's edge chains `{key, fa, fb, closed, convex, length, mid,
  points}`.
- `query.kernel` — `{kernel, manifold, errors}`: kernel name, whether the
  Manifold binary loaded, and `{feature_id: reason}` for every feature
  whose last rebuild failed (M38). `query.bodies` rows additionally carry
  `watertight`, `genus`, `surface_area`, `face_features` (ids of the
  features whose faces survive on the body).
- `query.control {name}` — rect (main-window pixels, even inside embedded
  popups), visible, disabled, `text` for Labels/Buttons (assert the status
  bar without reading pixels); `flyout_owner` names the ribbon stack button
  whose flyout holds the control (`client.click_control` right-clicks it
  first). `action.set_pref` also takes `tool_names` (ribbon titles).

**app.**
- `app.screenshot {path?}` — writes PNG, or returns base64 when no path
- `app.window {size?}` — get/set, `app.info` — version/godot/platform,
  `app.quit`

### Runner & comparison

- Python client `tests/rpc/client.py` (stdlib only: `socket`, `json`).
- Tests are Python scripts in `tests/rpc/`, run by `tools/run_rpc_tests.sh`,
  which launches the app (windowed or `--headless` where the test allows),
  waits for the port, runs the script, tears down.
- Numeric comparison: positions/lengths in canonical mm against expected
  values with explicit tolerance (default 1e-3 mm; solver-converged values use
  solver tolerance).
- Structural comparison: entity/constraint censuses against golden JSON in
  `tests/rpc/golden/` (id-insensitive: match on type + rounded geometry).
- Visual comparison: screenshots vs reference images with per-pixel diff
  budget — reserved for chrome-heavy features (glyphs, dimensions, timeline
  bar), since geometry is better asserted numerically.

### Human-simulation notes

- Drags interpolate with ease-in/out and configurable step count so
  hover-dependent code (snap previews, inference glyphs, trim highlight) runs
  exactly as with a mouse.
- Tests that verify inference must approach the snap target the way a person
  would (move within tolerance, pause a frame, click) — pointer teleports skip
  the code paths under test.

## Manual testing

`docs/MANUAL_QA.md` — cumulative checklist, one section per milestone,
windowed, hand-driven. Each milestone's section is written with the milestone
and signed off before merge. Format follows echo_vector's
`MANUAL_QA_CHECKLIST.md` (numbered steps, expected result per step, fix log).
