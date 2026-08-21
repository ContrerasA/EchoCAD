# EchoCAD — Milestones, volume 3 (M38–M50): the alpha  — DRAFT

Same rules as volumes 1–2: one branch per milestone (`m38-…`), merged to
`main` only with headless + RPC tests green and the manual section signed
off in `docs/MANUAL_QA3.md`. Internal unit stays mm. Arm-first/pick-after
and hover feedback on every pick stage are mandatory (CLAUDE.md).

## Where the project is now

M0–M36 plus the 2026-08-20 CHANGES round are on `main`: constrained 2D
sketching with the full 2D toolbox (splines, patterns, chamfer, polygon),
timeline, construction planes, sketch-on-face, extrude / revolve / sweep /
loft with booleans, body move/copy/mirror/pattern, prismatic fillet /
chamfer, reference images, DXF + SVG import, DXF + STL export, theme
files, ribbon shell, measure (sketch), TCP automation (63 headless tests,
28 RPC suites).

## Why this volume exists

You can draw anything, but you cannot yet **trust** a part. The blockers
for modelling real functional parts are all in the same place — the
solid stage is built on the engine's deferred CSG with AABB-guessed
targets and no face identity:

| Limitation today | Consequence for a functional part |
|---|---|
| Booleans target every body whose AABB touches | a cut for a pocket eats the neighbouring body |
| Godot CSG: deferred, slow, occasionally non-manifold | STL slices with holes; 20+ features lag |
| No persistent face/edge identity | sketch-on-face planes are snapshots; fillet can't pick edges; nothing survives an edit upstream |
| Extrude = single signed distance | no *to next*, *through all*, *symmetric*, *two-sided*, no draft |
| Fillet/chamfer only on plain single-extrude bodies | can't round a bracket after the holes are cut |
| No holes / threads / shell / combine / split | enclosures, bosses, bolt patterns are manual |
| No mass properties, section, interference, wall check | can't verify the part before printing |
| STL only, no mesh import | can't fit around a vendor part, no 3MF for slicers |
| No autosave, recovery, recent files, error chips | unacceptable for a release |

Volume 3 fixes the kernel first, then builds the missing features on top,
then polishes into an alpha.

## Alpha definition of done

Five benchmark parts, each scripted end-to-end through RPC as a
regression suite (`tests/rpc/parts/`) **and** built by hand in manual QA,
exported to 3MF and STL, sliced without repair warnings:

1. **L-bracket** — extrude, through-all hole pattern, fillet after cuts,
   chamfered mounting holes, mass properties match hand calc ±1 %.
2. **Enclosure + lid** — shell, lip via combine/cut, counterbored screw
   bosses, section check of wall thickness, interference check of lid fit.
3. **Flange** — revolve, circular bolt-hole pattern that *re-cuts* per
   instance, tapped center hole (modelled thread), draft on the hub.
4. **Spacer stack** — components: two bodies in separate components,
   moved, measured, exported as multi-object 3MF.
5. **Vendor fit** — import an STL of a bearing, cut its pocket *to object*,
   verify with interference check, export.

Plus: the app starts in < 2 s, recovers an unsaved document after a kill,
never loses theme/prefs on update, and every feature failure shows as a
red timeline chip with a reason instead of a crash or a silent no-op.

## Tooling needed to get there

- **Manifold** (github.com/elalish/manifold, Apache-2) vendored into the
  sibling `godot-geometry` repo the same way Clipper2/Skia are, exposed
  as a `MeshOps` GDExtension class: boolean (union/diff/intersect), split
  by plane, hull, volume / surface area / centroid / inertia, watertight
  check, and **face-ID propagation** (Manifold's `originalID` + per-face
  run index) so every output triangle knows which feature face it came
  from. Linux + Windows x86_64 rebuilt and re-copied into
  `addons/geometry`. This is the one new dependency of the volume.
- Nothing else new. Hole tables, thread profiles, 3MF (zip + XML) and
  mesh import (STL/OBJ/3MF) are pure GDScript.
- Escalations kept in reserve: planegcs for the sketch solver (unchanged
  status), STEP export stays out (needs a B-rep kernel; decision point
  after alpha).

## Cadence: feature milestones + polish rounds

Volume 2 taught us that the `docs/CHANGES.md` list-driven round is the
most effective polish mechanism. Volume 3 makes it a fixture: after every
two feature milestones a **polish round** (`P1`–`P4`) consumes a fresh
user-written `docs/CHANGES.md` (UX papercuts, visual, QA findings) and is
committed item-by-item on `main` with a QA section. Polish rounds have no
fixed scope — their scope is whatever the list says — but each one also
carries a standing checklist (below).

Standing polish checklist (re-audited every round):
- every pick stage has hover feedback; every operand tool arms first;
- every dialog: Enter confirms, Esc cancels, fields are unit-suffixed,
  tab order sane, focus lands on the first field;
- every feature error surfaces as a timeline chip reason + status line;
- no hardcoded colour/metric regression (`tests/m36_shell_qa.gd`);
- both themes, both projections, all five display units spot-checked.

```
M38 kernel ─ M39 identity+targets ─ P1 ─ M40 extents+holes ─ M41 fillet ─ P2 ─
M42 shell/draft/combine/split ─ M43 inspect ─ P3 ─ M44 exchange ─ M45 components ─
P4 ─ M46 document safety ─ M47 perf+robustness ─ M48 UX polish ─ M49 release eng ─ M50 alpha
```

---

## M38 — Manifold kernel  (branch: `m38-manifold-kernel`)

Replace the engine CSG stage in `BodyBuilder` with `MeshOps`. Ships:

- **Addon**: `MeshOps` class in `godot-geometry`: `boolean(a, b, op)`,
  `split_by_plane`, `hull`, `properties(mesh) -> {volume, area,
  centroid, inertia, aabb, watertight}`, `decimate` (optional), all over
  `ArrayMesh`/`PackedVector3Array + PackedInt32Array` with a parallel
  `PackedInt32Array face_ids` in and out. Meshes in mm, double precision
  inside Manifold, `reloadable = true` kept.
- **BodyBuilder**: every solid feature's part (extrude, revolve, sweep,
  loft, edge-treat) feeds Manifold directly; no scratch CSG tree, no
  deferred brush update, no coplanarity margin hack. Result per body is
  one manifold mesh with face ids; the rebuild is synchronous and
  deterministic.
- **Input hygiene**: every generator's exact mesh is checked watertight
  before it enters a boolean; a non-manifold part fails *its own* feature
  (red chip, M46 surfaces it) instead of poisoning the body.
- **Edge overlay for every body** (carried limitation closed): sharp
  edges computed from the manifold mesh (dihedral threshold from theme
  metric) — CSG-baked bodies finally draw their edges.
- **Fallback**: if `MeshOps` is missing on a platform (macOS/web until
  those binaries exist) the old CSG path stays behind a flag so the app
  still opens documents; the status bar shows a "legacy kernel" badge.
- **Automated**: `tests/m38_manifold_kernel.gd` — box ∪ box / − / ∩
  volumes analytic; every existing solid test re-run (volumes unchanged
  within tolerance); watertight after 50 random boolean chains (seeded
  fuzz); face-id survival through a cut; rebuild time budget for a
  30-feature document. All 28 RPC suites green unchanged.
- **Manual**: §M38 in `docs/MANUAL_QA3.md` — open every sample document
  from volumes 1–2, compare.

## M39 — Face identity + explicit targets  (branch: `m39-topology-refs`)

The face ids from M38 become the reference system the rest of the volume
builds on:

- **TopoRef** — `{feature_id, face_tag, ordinal}` persistent reference to
  a face or edge of a body (face_tag = cap_top / cap_bottom / side:i /
  seam, ordinal disambiguates splits). Resolved against the current
  rebuild; unresolved refs flag the dependent feature (yellow chip:
  "reference lost — re-pick").
- **Face planes become parametric** — `PlaneFeature` from a face stores a
  TopoRef instead of a snapshot; editing the extrude moves the sketch
  (the M22 limitation closed). Old documents migrate: snapshot planes are
  re-resolved to the nearest matching face on load, else stay snapshots
  with a warning.
- **Explicit boolean targets** — extrude/revolve/sweep/loft Join/Cut/
  Intersect take a target body list (arm-then-pick bodies with hover
  highlight; default = the auto AABB set, shown as chips in the dialog
  so the guess is visible and editable). `Intersect` op added.
- **Pattern/mirror of features re-cuts per instance** — instancing moves
  *before* boolean resolution: a patterned Cut is applied N times to the
  target (M33 limitation closed). Body-level patterns stay instanced
  meshes for speed.
- **Copy/move after boolean** stays as built; moved bodies now target by
  their *current* transform.
- **Automated**: `tests/m39_topology_refs.gd` — TopoRef survives an
  upstream dimension edit, a cut through the referenced face
  (ordinal), and a load/save; face-plane sketch follows its face; target
  list honoured (neighbouring body untouched); pattern-of-cut volume ==
  N holes; migration of a volume-2 document. RPC
  `tests/rpc/test_topology_refs.py` — pick targets by click.
- **Manual**: §M39.

## P1 — polish round 1

Consumes `docs/CHANGES.md` (expected: QA §M37 feedback + kernel
regressions). Standing checklist audit. QA §P1.

## M40 — Extents, draft, hole wizard  (branch: `m40-extents-holes`)

- **Extrude extents** — Distance / Symmetric (half or whole) / Two-sided
  (two distances) / **To Object** (pick face or body, hover feedback) /
  **To Next** / **Through All**; direction flip; **taper angle** (draft)
  via offset-profile loft. Same extent options on revolve angle
  (full / angle / two-sided / to face). Dialog + timeline chip + RPC
  `action.extrude {extent: {...}}`.
- **Hole feature** — `HoleFeature`: placement on a planar face by
  clicking (concentric snap to circular edges, hover ring) or on sketch
  points (one feature, N holes); types Simple / Counterbore /
  Countersink / Tapped; extents as above; standard tables (ISO metric
  coarse/fine, UNC/UNF, clearance close/normal/loose) in
  `res://data/holes/*.json`; thread as **cosmetic** (texture ring) or
  **modelled** (helical cut generated as a sweep of the thread profile,
  for printing). Holes are TopoRef-anchored so they follow their face.
- **Automated**: `tests/m40_extents_holes.gd` — each extent volume vs
  analytic on a stepped block, to-next stops at the first face, taper
  volume vs frustum, hole table lookup, counterbore/countersink volumes,
  modelled thread watertight + volume within tolerance of analytic,
  hole follows an edited face. RPC `tests/rpc/test_extents_holes.py`.
- **Manual**: §M40 — M3/M4/#6-32 holes sliced and test-fitted.

## M41 — Fillet + chamfer on any edge  (branch: `m41-edge-fillet`)

- **Per-edge picking** — hover highlights an edge chain (tangent-
  continuous run of sharp edges on the manifold mesh); click adds/
  removes; Shift-click selects a face's loop; arm-first or select-first.
  Works on any body, after any boolean.
- **Geometry** — chamfer: planar cut wedges booleaned out (exact).
  Fillet: rolling-ball between two planar faces and between a planar and
  a cylindrical face (hole rims, boss roots) generated as swept
  quarter-rounds with mitred/ball corners at vertices, unioned/subtracted
  through Manifold. Convex and concave edges. Other face pairs (free-form
  sweep/loft walls) refused with a status hint — documented limitation.
- **Parametric** — `EdgeTreatFeature` v2 stores TopoRef edge lists;
  multiple treatments per body; radius/distance in mm; replays after
  upstream edits, re-picks on lost refs.
- Sketch fillet/chamfer unchanged.
- **Automated**: `tests/m41_edge_fillet.gd` — convex/concave fillet
  volumes vs analytic, chamfer volume, hole-rim fillet, fillet after a
  cut, three-edge corner watertight, ref survives upstream edit,
  refusal path. RPC `tests/rpc/test_edge_fillet.py` — hover + click edge
  chains.
- **Manual**: §M41 — fillet the L-bracket benchmark.

## P2 — polish round 2

`docs/CHANGES.md`, standing checklist. QA §P2.

## M42 — Shell, combine, split, press-pull  (branch: `m42-shell-combine`)

- **Shell** — pick faces to remove (hover, multi), thickness inside /
  outside / both. Implementation: offset every face along its normal,
  rebuild the offset solid through Manifold, subtract; exact for planar
  + cylindrical faces, tolerance-documented for free-form.
- **Combine** — Join / Cut / Intersect between existing bodies (tool +
  target pick, keep-tools option). Replaces the "draw a sketch to
  subtract" workaround.
- **Split body** — by plane, by face, by sketch profile (extended); both
  halves become bodies. **Split face** by plane (for later press-pull).
- **Press-pull** — drag or type an offset on a planar face: generates a
  `FaceOffsetFeature` (extrude of the face's loop, joined or cut).
- **Automated**: `tests/m42_shell_combine.gd` — shelled box volume
  analytic (inside/outside), shell with two faces removed, combine
  volumes, split halves sum to whole + watertight, press-pull ==
  extrude-join of the same face. RPC `tests/rpc/test_shell_combine.py`.
- **Manual**: §M42 — the enclosure benchmark.

## M43 — Inspection  (branch: `m43-inspect`)

- **Mass properties** — per body / selection: volume, area, mass (density
  from a material picker: PLA, PETG, ABS, Al, steel, custom), centre of
  mass (marker in viewport), principal inertia. Unit-aware.
- **Section analysis** — clip plane (origin/construction plane or free,
  dragged) with capped cross-section (Manifold split), hatch colour from
  theme; persists per document; toggles with a HUD pill.
- **Interference check** — pick bodies, report overlap volumes; results
  as transient red bodies + browser list.
- **Measure in model mode** — point/edge/face/body pairs: distance,
  min distance, angle, radius, edge length, face area; **wall thickness
  probe** (ray both ways from a face point); all unit-formatted.
- **Print check** — watertight report, min wall thickness scan (sampled),
  overhang angle shading vs a build direction, bounding box vs a bed
  size from Preferences.
- **Automated**: `tests/m43_inspect.gd` — mass props vs analytic,
  section area of a box at a known offset, interference volume of two
  overlapping boxes, min distance, wall probe on a shelled box,
  overhang classification. RPC `tests/rpc/test_inspect.py`.
- **Manual**: §M43.

## P3 — polish round 3

`docs/CHANGES.md`, standing checklist. QA §P3.

## M44 — Exchange  (branch: `m44-exchange`)

- **3MF export** — multi-object, units mm, per-body colour, component
  names, thumbnail PNG; validates against the core spec; per-body /
  visible / all.
- **Mesh import** — STL (binary/ascii), OBJ, 3MF → `MeshBodyFeature`:
  a body with no sketch, manifold-checked on import (repair: weld +
  remove degenerate; else imported as *reference only*, excluded from
  booleans with a badge). Participates in booleans, targets, measure,
  section, export. Scale/units dialog on import.
- **OBJ export** and **SVG export of a sketch** (cheap; laser workflow).
- STEP: explicitly deferred (decision note in backlog).
- **Automated**: `tests/m44_exchange.gd` — 3MF round-trip (export →
  import → volume equal), colour + names survive, STL/OBJ import volume,
  non-manifold input → reference-only, cut against an imported mesh.
  RPC `tests/rpc/test_exchange.py`.
- **Manual**: §M44 — open the 3MF in PrusaSlicer/Bambu/Cura.

## M45 — Components  (branch: `m45-components`)

- **Model** — a document owns N components; each owns sketches, bodies,
  features, planes, canvases; one *active* (browser dot); new features
  land in the active component. Root component = today's document
  (migration: everything moves into root).
- **Browser** — nested tree, activate / rename / hide / isolate /
  delete / ground; per-component transform (move tool reused) so parts
  can be positioned relative to each other; drag a body into a
  component ("Create component from body").
- **Timeline** — chips coloured/grouped by component; filter to active.
- **Cross-component references** — sketch-on-face and to-object extents
  may reference another component's faces (TopoRef gains a component
  id); booleans stay within a component unless the target picker says
  otherwise.
- Joints are **not** in this volume.
- **Automated**: `tests/m45_components.gd` — create/activate/land,
  transform composition, isolate/hide, serialization + migration of
  volume-2 documents, cross-component TopoRef. RPC
  `tests/rpc/test_components.py`.
- **Manual**: §M45 — the spacer-stack benchmark.

## P4 — polish round 4

`docs/CHANGES.md`, standing checklist. QA §P4.

## M46 — Document safety + feature errors  (branch: `m46-doc-safety`)

- **Autosave** — every N s (pref) to `user://autosave/<doc-hash>.ecad`
  on a thread; **crash recovery** prompt on next start; cleared on save.
- **Unsaved guard** on close/open/new; **Recent files** (File menu +
  start screen); **start screen** (new / open / recent / samples);
  document **tabs** (several open documents, one window).
- **Feature error chips** — a feature that fails to compute keeps its
  place, shows red with a reason tooltip; downstream features skip it;
  the timeline never crashes or silently omits. Yellow = lost reference
  (M39). "Edit feature" opens the dialog with the reason pre-filled.
- **Schema version** — `.ecad` carries `schema`; loader runs migrations
  (volume-1/2 → 3) with a test fixture per version; unknown newer
  schema refuses with a message instead of mangling.
- **Settings durability** — prefs file schema + defaults merge (the M37
  reset bug must be impossible by construction: a test writes an old
  prefs file and asserts nothing is lost).
- **Automated**: `tests/m46_doc_safety.gd` — autosave written + restored
  after simulated kill, migrations per fixture, error chip state +
  downstream skip + recovery after fix, prefs merge. RPC
  `tests/rpc/test_doc_safety.py`.
- **Manual**: §M46 — kill -9 mid-edit, reopen.

## M47 — Performance + robustness  (branch: `m47-perf`)

- **Incremental rebuild** — per-feature part cache keyed by input hash;
  editing feature k recomputes k..end only, and only bodies it touches.
- **Threaded rebuild** — BodyBuilder runs on a worker (same newest-only
  pattern as the threaded solver); viewport shows the last good result +
  progress; cancellable.
- **Sketch scale** — 500-entity sketch: render, pick, solve budgets;
  spatial index in SnapEngine/ProfileFinder.
- **Fuzz** — seeded random feature chains (extrude/cut/fillet/hole/
  pattern) for 500 iterations must never crash, never produce a
  non-manifold body, and serialize round-trip.
- **Budgets as tests**: rebuild of each benchmark part < 500 ms warm,
  startup < 2 s, document open < 1 s.
- **Automated**: `tests/m47_perf.gd` (budgets, skip on CI slow flag),
  `tests/m47_fuzz.gd`.
- **Manual**: §M47 — feel pass on the largest sample.

## M48 — UX polish milestone  (branch: `m48-ux`)

The items polish rounds keep deferring because they are features:

- **Selection filters** (bodies / faces / edges / sketches / planes) in
  the HUD; **isolate / hide / show all**; **right-click context menus**
  on canvas, browser, timeline (edit, rename, suppress, delete, isolate,
  appearance, look-at).
- **Double-click** a body face → edit its sketch; double-click a chip →
  edit feature; **rename** features inline.
- **Keyboard shortcut editor** (Preferences, conflicts flagged); all
  actions routed through one action map.
- **Toasts + progress** — non-blocking notifications, progress bar for
  long rebuilds/exports; undo from a toast.
- **In-app help** — shortcut sheet (`?`), first-run tour overlay,
  tooltips with shortcut + one-line description on every ribbon button.
- **Dimension text drag**, dimension precision pref, **DOF readout**
  lists which entities are free (click to highlight).
- **Automated**: `tests/m48_ux.gd` — action map completeness (every
  ribbon button has an action + tooltip), shortcut conflict detection,
  filters affect picking, context menu entries per target. RPC
  `tests/rpc/test_ux.py`.
- **Manual**: §M48.

## M49 — Release engineering  (branch: `m49-release`)

- **Versioning** — `VERSION` file, About dialog, `--version`, build
  stamp; `.ecad` schema tied to it.
- **Export presets** — Linux x86_64 + Windows x86_64 (addons already
  vendored), macOS universal once the sibling repos build it; app icon,
  file association for `.ecad`, zip + Windows installer script.
- **CI** — GitHub Actions: headless tests + `HEADLESS=1` RPC suites on
  Linux and Windows per PR; release workflow builds + attaches exports.
- **Sample parts** — the five benchmark parts as `.ecad` in
  `samples/`, reachable from the start screen; each has its RPC script.
- **Docs** — `docs/USER_GUIDE.md` (first part in 10 minutes, every tool
  one paragraph, shortcuts), `docs/FILE_FORMAT.md`, release notes.
- **Crash log** — uncaught errors written to `user://logs/` with the
  document autosaved first; no telemetry.
- **Automated**: `tests/m49_release.gd` — version string consistency,
  every sample opens + rebuilds watertight, user guide mentions every
  registered tool.
- **Manual**: §M49 — fresh-machine install on Linux + Windows.

## M50 — Alpha  (branch: `m50-alpha`)

Not a feature milestone: the gate.

- Build the five benchmark parts by hand following the user guide only;
  every papercut found becomes a `CHANGES.md` item; fix or explicitly
  defer (documented in release notes).
- Run every manual QA section from volumes 1–3 once on the release
  build (both platforms, both themes).
- Tag `v0.1.0-alpha`, publish exports, release notes, known limitations.

---

## Milestone order rationale

Kernel first (M38) because every later feature — explicit targets,
per-edge fillet, shell, section, interference, mesh import, 3MF
watertightness — needs robust booleans and face ids; building them on
Godot CSG would mean building them twice. Identity (M39) immediately
after, because holes (M40), fillets (M41) and shell (M42) must anchor to
faces to be parametric. Extents + holes (M40) before fillet (M41) because
fillets round hole rims. Inspection (M43) after shell so wall-thickness
checks have something to check. Exchange (M44) after inspection so
imported meshes are validated with the same tooling. Components (M45)
late because they touch the serializer once everything else has settled.
Document safety (M46) after the schema stops moving. Perf (M47) once
the feature set is final. UX milestone (M48) collects the polish-round
leftovers; release engineering (M49) last, alpha gate (M50).

## As-built notes

- **M38** (2026-08-20): Manifold 3.2.1 vendored (`MeshSolid`), winding
  consistency pass + 1 µm weld before import, kernel tolerance 1e-4 mm,
  cuts exact (no EPS inflation). Legacy CSG path kept behind
  `SolidKernel.available()` with a status-bar badge.
- **M39** (2026-08-20): face ids use the feature id's number as ordinal
  (stable across insertions); TopoRef heals by plane hint; face planes
  re-resolve inside ONE ordered BodyBuilder pass, which also moved body
  transforms/copies/mirrors/patterns into timeline order (closing the M32
  "booleans target pre-move AABB" limitation). Pattern/mirror of a
  feature = the source tool replayed per instance with the source's
  operation + targets; picked by clicking one of its faces (Source ▸
  Feature). `FeatureDialog` became the shared dialog shell (docked
  top-right, wraps to content, inline errors, Targets/Source Pick… rows)
  and Extrude/Revolve/Sweep/Loft/Pattern/Mirror moved onto it; Mirror
  gained a dialog (plane dropdown + viewport pick). RPC:
  `action.select_option`, `query.project`, `targets` on the four solid
  actions.

- **M40** (2026-08-20): extrude extents (symmetric/two-sided/to object/to
  next/through all) resolve in `prepare(doc, bodies)` during the ordered
  build; taper = per-vertex miter offset of the far cap (vertex count
  preserved, quads between). `edit_feature()` + "Edit…" in the chip menu;
  extrude and hole dialogs edit in place. Hole wizard: `HoleFeature`
  (lathe profile per hole, kernel-unioned; modelled thread = major-bore
  minus a helical ridge), `HoleTable` from `data/holes.json` (+
  `user://holes/*.json`), face pick + click placement with snaps to
  circle centres / sketch points, preview rings. Edit fields prefill with
  `UnitConverter.format_exact` (round-trip safe). RPC: `action.hole`,
  `query.bodies {faces}`, extent args on `action.extrude`, `input.click
  {double}`.

- **M41** (2026-08-20): `EdgeFilletFeature` — edges are kernel EDGE
  CHAINS (`SolidKernel.edge_chains`: mesh edges between two faces, chained,
  with per-vertex face normals and convexity), remembered by face pair +
  ordinal + midpoint hint and healed by hint. Tools are SWEEPS of the
  corner section along the chain (chamfer triangle / fillet arc), convex
  chains cut, concave chains join; ball corners where three picked convex
  straight chains meet (corner box − sphere − three cylinders). Works on
  any body after any boolean, including hole rims. Dialog docks top-right
  with arm-first edge picking (hover = whole chain); editing rebuilds the
  candidates from `BodyBuilder.build_before(doc, fid)` (the body as it was
  before the feature). Cuts are now fully exact (no cap overshoot —
  kernel tolerance handles flush caps). `edge_candidate` colour role.
  RPC: `action.edge_fillet`, `query.edges`. M35 `EdgeTreatFeature` stays
  loadable/editable; ribbon buttons route to the new flow.

## Deferred past alpha (beta backlog)

- STEP import/export (B-rep kernel decision: OpenCascade-lite via
  GDExtension vs staying mesh-only with 3MF as the interchange).
- Joints / assembly motion; as-built joints; contact sets.
- Drawing sheets (projections + dimensions → DXF/PDF).
- Sketch text (font outlines), emboss/deboss.
- Free-form fillet (sweep/loft walls), variable-radius fillet, full
  fillet; thicken surface; surface modelling generally.
- Rib / web, thread *feature* on external cylinders (modelled thread is
  hole-only in M40), coil/spring.
- Parameter table driven configurations; user parameters with units
  other than length (angles exist; mass/count next).
- Rigid whole-chain offset constraint; spline corner toggle + tangent
  constraints; trim/extend/offset on splines.
- Gizmo drag for body move (numeric dialog stays until then).
- macOS/web addon binaries (sibling repos).
