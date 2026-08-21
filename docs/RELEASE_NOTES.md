# EchoCAD 0.1.0-alpha

First alpha: a parametric CAD that can model, check and export functional
parts.

## Highlights

- **Manifold solid kernel** — exact, watertight booleans with face
  identity; sketches on faces, holes and fillets follow their faces through
  edits; red/amber timeline chips explain anything that cannot compute.
- **Modelling** — extrude with every extent (to object / to next / through
  all / symmetric / two-sided / taper), revolve, sweep, loft, hole wizard
  (standard tables, counterbore/countersink, modelled threads), fillet and
  chamfer on any edge (ball corners), shell, combine, split, press-pull,
  move/copy/mirror/pattern of bodies *and* of single cut/join features,
  explicit boolean targets.
- **Inspection** — measure, section analysis, mass properties with
  materials, interference, print check.
- **Exchange** — 3MF / STL / OBJ export, STL / OBJ / 3MF import as bodies,
  DXF and SVG for sketches, reference images.
- **Safety** — autosave with crash recovery, unsaved-work guard, recent
  files, start panel, incremental rebuilds.
- **UI** — themed ribbon with tool stacks, docked feature dialogs,
  arm-first picking with hover feedback everywhere, context menus,
  shortcut sheet, light and dark themes as JSON files.

## Platforms

Linux x86_64 and Windows x86_64 (the geometry addon ships both). macOS and
web builds need the addon compiled for them first.

## Known limitations

See `docs/USER_GUIDE.md` — single component documents, no STEP, best-effort
fillets on free-form faces, spline modify tools.

## Samples

`samples/` holds the five benchmark parts the alpha was tested against
(L-bracket, enclosure + lid, flange, spacer stack, vendor fit); they are
listed on the start panel.
