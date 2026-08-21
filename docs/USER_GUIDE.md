# EchoCAD User Guide (0.1.0-alpha)

EchoCAD is a parametric, timeline-based CAD for functional parts: sketch on
a plane, turn sketches into solids, cut and round them, check them, export
them for printing or machining. Everything you do lands in the timeline at
the bottom and can be edited or undone later.

## Your first part in ten minutes

1. **Launch.** The start panel offers *New Sketch*, *Open…*, *Import
   Mesh…*, recent files and the shipped samples. Press **New Sketch** (or
   `N`) and click the XY plane in the viewport.
2. **Sketch.** In sketch mode the ribbon shows CREATE (line `L`, rect `R`,
   circle `C`, arc `A`, slot `S`, polygon, spline, point), MODIFY (trim `T`,
   extend `X`, offset `O`, mirror `M`, fillet, chamfer, patterns), CONSTRAIN
   and a dimension tool `D`. Draw a 40 × 30 rectangle: press `R`, click two
   corners. Type values while drawing (Tab switches fields). Press **Finish
   Sketch**.
3. **Extrude.** Press **Extrude**, click inside the rectangle (it
   highlights), type `10` (mm — or `0.5in`, units are understood) and OK. A
   body appears; *Extrude1* joins the timeline.
4. **Cut a pocket.** *New Sketch*, click the top face of the body, draw a
   smaller rectangle, Finish, Extrude ▸ Operation **Cut**, distance `-4`.
   The dialog's *Targets* row lets you name which bodies a cut or join
   touches; *Auto* hits everything the tool overlaps.
5. **Holes.** Press **Hole**, click the top face, click one or more
   positions (the ring under the cursor snaps to circle centres and sketch
   points), Enter. Pick *Size ▸ M4*, *Fit ▸ Normal clearance*, *Through
   All*, OK.
6. **Round the edges.** Press **Fillet**, click the edges (a click takes
   the whole smooth chain), Enter, size `2`, OK.
7. **Check it.** INSPECT ▸ *Properties* gives volume, mass (pick a
   material) and centre of mass; *Section* looks inside; *Print Check*
   reports watertightness, bed fit and overhangs.
8. **Export.** MAKE ▸ *Export 3MF* (slicers) or STL / OBJ. Save the
   document with `Ctrl+S` (`.ecad`, plain JSON).

## The screen

- **Menu bar** — File (new / open / recent / save / import / export /
  preferences), Edit (undo, redo, parameters), View (theme), Help
  (shortcuts `F1`, about). The document name and unsaved mark sit left,
  the display unit right.
- **Ribbon** — model mode: CREATE, MODIFY, INSPECT, CONSTRUCT, INSERT,
  MAKE; sketch mode: SELECT, CREATE, MODIFY, CONSTRAIN, OPTIONS, Finish.
  Buttons with a corner mark are stacks: right-click or hold for the other
  tools in them. A narrow window folds a group's trailing tools into `»`.
- **Browser** (left) — origin planes, construction planes, sketches and
  bodies with eye toggles; right-click rows for their menus.
- **Viewport** — middle-drag pans, Shift + middle-drag orbits, the wheel
  zooms towards the cursor (whatever is under the pointer stays under it),
  `P` toggles orthographic. The view cube snaps to faces, the house returns
  home. HUD pills: orbit pivot mode, Look At, Fit, ORTHO, saved Views,
  Preferences.
- **Framing** — `Home` fits the work in any mode (`F` does the same in
  model mode; inside a sketch `F` is the fillet tool). With a body selected
  it fits that body; inside a sketch, the selected geometry. The view also
  frames itself at the moments you would otherwise have to: a document's
  first sketch when you finish it, its first body when it appears, and a
  sketch whose dimensions have just pushed it off screen or shrunk it to a
  speck.
- **Timeline** — one chip per feature in order. Double-click to edit,
  right-click for Edit / Rename / Suppress / Delete, drag the red marker
  to roll the model back in time. A red chip failed (hover for the
  reason); an amber chip computed from a stale reference.
- **Status bar** — mode, the current hint, the measure slot, sketch DOF
  and zoom.

## Sketching

Sketches are typed geometry (points, lines, arcs, circles, splines) held
together by constraints. Drawing infers coincident / horizontal / vertical
constraints as you go (OPTIONS ▸ Infer constraints). Add more from the
CONSTRAIN group — select the entities first, or arm the tool and then click
them (every tool works both ways). Dimensions (`D`) take expressions and
named parameters (Edit ▸ Parameters…). The DOF badge turns green when a
sketch is fully constrained. Construction geometry (OPTIONS) guides without
becoming profile. Project (CREATE) brings edges of other sketches or bodies
into this sketch as linked geometry.

Closed loops become **profiles** (shown filled); holes inside a profile are
respected by extrude/revolve.

## Solid features

| Feature | What it does | Notes |
|---|---|---|
| **Extrude** | Profile → prism | Extent: distance, symmetric, two-sided, to object (pick a face), to next, through all; taper angle; operation New Body / Join / Cut / Intersect; explicit targets. |
| **Revolve** | Profile around an axis | Axis = sketch X/Y or a line; angle; operations + targets. |
| **Hole** | Wizard | Simple / counterbore / countersink, ISO + unified tables, through or blind with drill tip, cosmetic or modelled thread. Follows its face. |
| **Sweep** | Profile along a path | Path = line/arc/spline chain in another sketch. |
| **Loft** | Between 2+ profiles | Hole-free profiles on different planes. |
| **Mirror / Pattern** | Bodies or one cut/join feature | Source ▸ Feature: click a face of the feature; a pattern of a cut re-cuts per instance. |
| **Press Pull** | Move a flat face | + adds material, − removes. |
| **Fillet / Chamfer** | Any edge of any body | Click edge chains; ball corners where three rounds meet. |
| **Shell** | Hollow a body | Pick faces to open; inside/outside. |
| **Combine / Split** | Boolean between bodies / cut a body in two | By plane or flat face. |
| **Move / Copy** | Numeric body transforms | Later cuts see the moved body. |
| **Offset Plane** | Construction plane | Sketch on it; chains allowed. |

Every feature dialog docks top-right, confirms with Enter, cancels with
Esc, validates inline, and lets you **pick first or arm first** — select a
body and press the command, or press the command and click what it asks
for (hover always shows what a click would take; Enter or right-click ends
a multi-pick).

## Inspect

Measure (two points, snaps to corners and edges; hover a face for area and
normal), Section analysis (plane + offset, live), Properties (mass by
material, centre of mass, inertia), Interference (overlap volumes), Print
Check (watertight, bed, overhangs).

## Files and exchange

- `.ecad` — the document: JSON, versioned, readable. Autosaves every two
  minutes while there is unsaved work; a crash is offered for recovery at
  the next launch.
- Import: DXF, SVG (sketches), STL / OBJ / 3MF (mesh bodies — closed
  meshes take booleans), PNG/JPEG canvases for tracing.
- Export: 3MF (colours, names, mm), STL, OBJ, DXF and SVG of a sketch.

## Units

The model is millimetres inside. The display unit (Preferences, also saved
in the document) formats every label and field; typed values may carry a
suffix (`10mm`, `0.5in`, `2cm`).

## Themes

View ▸ Theme switches between the shipped themes; drop your own JSON into
the user themes folder (Preferences ▸ Open themes folder). See
`docs/THEMING.md`.

## Keyboard

`F1` or `?` shows the full sheet. Essentials: `Ctrl+N/O/S`, `Ctrl+Z` /
`Ctrl+Shift+Z`, `Home` fit (`F` too, in model mode), `P` ortho, `N` new
sketch, `Esc` cancel, `Enter` confirm, `Delete` in sketches.

## Known limitations (alpha)

- One component per document; no assemblies or joints.
- No STEP (mesh formats only). Fillets on free-form faces are best effort.
- Sketch splines cannot be trimmed/offset; DXF/SVG export writes them as
  polylines.
- Sweep profiles must stay clear of tight bends; loft sections must be
  hole-free.
