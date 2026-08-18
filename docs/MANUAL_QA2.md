# EchoCAD — Manual QA Checklist, volume 2 (M22+)

Continuation of `docs/MANUAL_QA.md`, which holds §M2–§M21 and was closed at
the end of the M21 QA pass (it had grown past 100 KB). Same rules, restated:

Cumulative, hand-driven, windowed. One section per milestone; each section is
signed off before its branch merges. Steps are numbered with an expected
result; log fixes under the section as they happen.

Run: `godot --path .` (see CLAUDE.md for the binary path).

## Checkbox legend

- `[ ]` — not yet verified.
- `[x]` — verified working by hand.
- `[!]` — verified BROKEN. An `Issue:` line follows saying what is wrong; the
  matching entry in the section's fix log says what was done about it.
- `[~]` — works, but a follow-up is deferred to a later milestone. The
  `Deferred:` line names the milestone.

A section may only be signed off when it has no `[ ]` and no `[!]` boxes left.

---

## §M22 — Construction planes + sketch on faces

Status: PENDING sign-off

- [ ] 1. Model mode: press **Offset Plane**, hover the origin planes — they
   glow like in sketch-plane picking; click XY. **Expect:** a small dialog
   asks for the offset; type `1in`, OK. A tan/amber quad appears floating
   25.4 mm above the ground plane, centred over the origin. The timeline
   gains a "Plane1" chip; the browser gains a "Construction" folder with a
   Plane1 row (eye ticked).
- [ ] 2. **Create Sketch**, click the floating tan plane. **Expect:** the
   camera flies square onto it; the grid sits ON the elevated plane (not at
   the ground); the status bar reads "Sketch2 on Plane1" (name may vary).
   Draw a rectangle, Finish Sketch. The sketch's lines render at the
   plane's height in 3D.
- [ ] 3. Extrude the elevated rectangle 0.5in. **Expect:** the solid FLOATS —
   its bottom face at the plane height, not on the ground.
- [ ] 4. Double-click the Plane1 chip (or its browser row). **Expect:** the
   offset dialog reopens showing `1.000 in`. Change it to `2in`. The plane
   quad, the sketch on it, and the extruded solid all move up together.
   Ctrl+Z brings all three back down in ONE step.
- [ ] 5. Offset Plane again; this time click Plane1 itself as the base, type
   `0.5in`. **Expect:** a second plane appears 0.5in above Plane1 (chained).
- [ ] 6. **Create Sketch**, then hover the TOP FACE of the floating solid.
   **Expect:** the face highlights amber. Click it: a sketch opens ON the
   face (grid at face height); the timeline shows a new Plane + Sketch pair.
   Draw a circle on it, Finish; extrude the circle 0.25in — it stacks on the
   solid. Ctrl+Z on the sketch-on-face step removes the plane AND the empty
   sketch together (one undo step).
- [ ] 7. Browser: untick the eye on Plane1. **Expect:** its quad disappears
   in model mode; while picking a sketch plane it re-appears (mode gate),
   like the origin planes. Re-tick: it stays visible in plain model mode.
- [ ] 8. Right-click the Plane1 chip → Delete. **Expect:** REFUSED with a
   status message (a sketch still uses it). Delete the chained plane from
   item 5 (nothing uses it) — it goes away.
- [ ] 9. Timeline: drag the rollback marker before Plane1. **Expect:** the
   plane quad, the elevated sketch and the solid all vanish; drag it back —
   everything returns.
- [ ] 10. Save the document, reopen it. **Expect:** planes, sketches on
   them, and the floating solid all come back exactly; Plane1's offset
   still edits parametrically.
- [ ] 11. In the elevated sketch, Shift+MMB orbits off-axis; the in-edit
   geometry renders at the plane's height; clicking the plane's view-cube
   face flies back square; drawing continues to land on the elevated plane
   while off-axis.

### §M22 fix log

(empty)

---

## §M23 — Revolve

Status: PENDING sign-off

- [ ] 1. Sketch on XY: a rectangle from about (20,0) to (30,10) — off to the
   right of the origin. Finish. Press **Revolve**, hover the rectangle —
   the region highlights amber like Extrude's pick; click it. **Expect:**
   the status bar now asks for the axis: "click a sketch line, or press
   X / Y for the sketch axes".
- [ ] 2. Press **Y**. **Expect:** the Revolve dialog opens (angle box,
   operation dropdown). Leave the angle empty (=360), OK. A RING (donut
   with a square cross-section) appears around the vertical axis; the
   timeline gains a "Revolve1" chip; the browser lists the body.
- [ ] 3. Orbit the ring. **Expect:** shaded like extruded solids, with edge
   lines on the four sharp circles; no seams on the smooth walls; no
   see-through faces.
- [ ] 4. Undo. Revolve the same rectangle again, angle **90**. **Expect:** a
   quarter of the ring with two flat end caps; the caps carry outline edges.
- [ ] 5. Draw a sketch with a rectangle straddling the vertical axis (e.g.
   (-5,20) to (5,30)) and try to revolve it about Y. **Expect:** refused
   with a status message about the region straddling the axis; no feature
   is added.
- [ ] 6. In a sketch, draw a rectangle plus a separate vertical CONSTRUCTION
   line (X toggle) to its left. Revolve the rectangle and CLICK THE LINE as
   the axis. **Expect:** the ring forms around the line, not the sketch
   axis.
- [ ] 7. Booleans: extrude a plate, then sketch a small rectangle over it
   and revolve it 360° about a line through the plate with operation
   **Cut**. **Expect:** a round groove/trough carved out of the plate;
   undo restores the plate in one step.
- [ ] 8. Edit the ring's source sketch (drag the rectangle a little),
   finish. **Expect:** the revolve replays — the ring follows the profile.
- [ ] 9. Save and reopen. **Expect:** revolves rebuild identically; the
   timeline order and names survive.
- [ ] 10. Suppress the Revolve chip. **Expect:** the ring disappears;
   unsuppress brings it back.

### §M23 fix log

(empty)

---

## §M24 — STL export

Status: PENDING sign-off

- [ ] 1. Empty document: press **Export STL**. **Expect:** no dialog; the
   status bar says there are no solid bodies to export.
- [ ] 2. Extrude a box (with a hole in it for interest). Export STL.
   **Expect:** file dialog defaults to .stl with an "ASCII STL" checkbox
   (unticked); saving reports the triangle count in the status bar.
- [ ] 3. Open the exported file in an external viewer/slicer (PrusaSlicer,
   Cura, Windows 3D Viewer...). **Expect:** the part loads at the right
   SIZE in mm (a 40 x 30 x 10 sketch box measures 40 x 30 x 10 mm), is
   watertight (no slicer repair warnings), and shows no inverted faces.
- [ ] 4. A boolean body (box with a revolved groove cut, from §M23.7):
   export and open externally. **Expect:** the carved shape survives the
   round trip; still manifold.
- [ ] 5. Two bodies: right-click a body row in the browser → "Export
   STL...". **Expect:** only that body lands in the file.
- [ ] 6. Hide one body (browser eye), Export STL from the toolbar.
   **Expect:** only the visible body exports.
- [ ] 7. Tick "ASCII STL" and export. **Expect:** the file opens in a text
   editor as `solid echocad` / `facet normal ...`; a viewer still loads it.

### §M24 fix log

(empty)

---

## §M25 — DXF import

Status: PENDING sign-off

- [ ] 1. Export a sketch (rect + circle + a construction line) to DXF, then
   press **Import DXF** and pick that file. **Expect:** a NEW sketch
   appears in the timeline/browser with the same geometry in the same
   place; the construction line comes back violet-dashed; the status bar
   reports the entity census.
- [ ] 2. Hover the imported rectangle in Extrude picking. **Expect:** the
   region highlights (endpoints welded into a closed profile); extruding it
   works.
- [ ] 3. Ctrl+Z after an import. **Expect:** the entire imported sketch
   disappears in ONE step.
- [ ] 4. Import a DXF exported from another CAD (Fusion, LibreCAD,
   QCAD...): a 2D drawing with lines, arcs, circles, and a polyline.
   **Expect:** geometry lands correctly (polylines become lines+arcs);
   unsupported entities (text, dimensions, splines) are skipped and the
   status bar says how many.
- [ ] 5. Import a file drawn in INCHES ($INSUNITS=1). **Expect:** the
   geometry lands at the right physical size (1in line measures 25.4 mm /
   1.000 in with Smart Dimension).
- [ ] 6. Open the imported sketch and edit: drag points, add constraints,
   dimension it. **Expect:** imported geometry behaves like drawn geometry
   (snap, solver, DOF all work).
- [ ] 7. Pick a garbage file (a .txt renamed .dxf). **Expect:** refused with
   a status message; the document is untouched.

### §M25 fix log

(empty)
