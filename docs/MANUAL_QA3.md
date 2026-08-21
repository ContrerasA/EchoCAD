# EchoCAD — Manual QA Checklist, volume 3 (M38+, the alpha)

Continuation of `docs/MANUAL_QA2.md` (§M22–§M37). Same rules, restated:

Cumulative, hand-driven, windowed. One section per milestone (and one per
polish round, §P1…); each section is signed off before its branch merges.
Steps are numbered with an expected result; log fixes under the section as
they happen.

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

## §M38 — Manifold kernel

Status: PENDING

Bodies are now computed by the Manifold kernel (`MeshSolid` in the vendored
geometry addon) instead of the engine's CSG: exact booleans, synchronous
rebuilds, face ids on every triangle, an edge overlay on every body.

- [ ] 1. Launch the app. **Expect:** the status bar shows no "LEGACY
   KERNEL" badge (it only appears on a platform whose addon binary is
   missing — Linux and Windows x86_64 ship it).
- [ ] 2. Sketch a 40×30 rectangle on XY, extrude 10. Sketch a 10×10 square
   in the middle of its top face, extrude −10 as **Cut**. **Expect:** the
   pocket appears the instant the dialog closes — no one-frame flash of the
   raw cutter, no z-fighting ghost, no see-through skin at the pocket's
   floor or rim. Body properties (browser right-click ▸ Properties or the
   `query.bodies` volume) read exactly 11000 mm³ — cuts are no longer
   inflated by 0.05 mm.
- [ ] 3. Sketch another 10×10 square that shares the plate's outer edge
   (flush notch), cut through. **Expect:** the notch opens cleanly to the
   outside — no paper-thin wall left standing on the flush side. Volume
   exactly 10000.
- [ ] 4. **Edges on boolean bodies:** orbit around the pocketed plate.
   **Expect:** every edge draws as a hairline — the outer box, the pocket
   rim, the pocket floor — in both themes. Before M38 a body that had been
   through a boolean lost its edge overlay.
- [ ] 5. Revolve a rectangle 90° as **Cut** through a block (the §M23 notch).
   **Expect:** the notch is carved, its radius matches the dimension exactly
   (no radial inflation), end caps closed.
- [ ] 6. Sweep + loft bodies (§M34): build the frustum loft and cut it with
   an identical loft. **Expect:** the loft body vanishes; nothing else in the
   document grows a hole unless the cutter actually passes through it.
- [ ] 7. **Consuming cut:** a cut larger than the whole body. **Expect:** the
   body disappears from the viewport and the browser; undo brings it back.
- [ ] 8. **Red chip:** sketch a small square far away from every body and
   extrude it as Cut. **Expect:** the feature lands in the timeline with an
   error-tinted chip (border + label in the theme's `error` colour); hover
   it — tooltip reads "Extrude N — touches no body". Other chips are
   unaffected. Drag the rollback marker before it: the chip dims like any
   rolled-back chip. Delete it: the tint is gone.
- [ ] 9. **Open every sample document** from volumes 1–2 you still have
   (`.ecad` files with booleans, patterns, mirrors, fillets). **Expect:**
   every body looks as before, the rebuild feels instant, no feature chip
   turned red.
- [ ] 10. Export STL of the pocketed plate, open it in a slicer. **Expect:**
   no "mesh is not manifold / repaired N errors" warning.
- [ ] 11. Move Body / Copy Body / Mirror / Pattern on a boolean body (§M32–
   §M33). **Expect:** instances carry the edge overlay and the same
   appearance; volumes equal the source.
- [ ] 12. 3D Fillet / Chamfer on a plain extrude (§M35). **Expect:** still
   works; the treated body has a clean edge overlay along the rounded
   corners (one line per tessellation seam is NOT drawn — smooth runs stay
   seam-free).
- [ ] 13. Both themes: the error chip reads clearly against the timeline in
   Modernist Dark and Modernist Light.

### Fix log

(none yet)

---

## §M39 — Face identity + explicit targets

Status: PENDING

Every body face now has a persistent identity (TopoRef). Sketches on
faces follow their face, booleans can name their targets, patterns and
mirrors can repeat a single cut/join feature, and the feature dialogs
share one shell (rows, inline errors, Enter/Esc, Pick… buttons).

- [ ] 1. **Sketch follows its face.** Extrude a 40×30 plate 10 mm. New
   Sketch on its top face, draw a 10×10 square, Finish, extrude it 5 mm as
   Join (a boss). Double-click Extrude1's chip and change the distance to
   25. **Expect:** the plate grows AND the boss rides up with it — the
   sketch's 3D outline, its construction plane row, and the boss all sit on
   the new top face. Undo: everything comes back down.
- [ ] 2. Same document: drag the rollback marker before Extrude1 and back.
   **Expect:** no chip turns yellow/red; the face plane resolves again.
- [ ] 3. **Lost face = warning.** Suppress Extrude1 (right-click its chip).
   **Expect:** the face plane's chip turns warning-tinted (amber border);
   tooltip says "face reference lost — the last position stands; re-pick the
   face". The sketch and boss stay where they were (no crash, no jump).
   Unsuppress: the tint clears.
- [ ] 4. **Open a pre-M39 file** that has a sketch on a face (any §M22
   document). **Expect:** it opens unchanged; after the first rebuild,
   editing the underlying extrude moves that sketch too (the snapshot plane
   adopted its face). Save ▸ the file still opens in this build.
- [ ] 5. **New dialogs.** Press Extrude after picking a profile. **Expect:** a
   dialog with labelled rows — Profile (sketch name), Distance (placeholder
   shows unit examples), Operation, and for Join/Cut/Intersect a Targets
   row reading "Auto (bodies it touches)" with a Pick… button. The
   Distance field is focused; Enter confirms; Esc cancels; an empty or zero
   distance shows an inline red error under the rows instead of closing.
   Same shell for Revolve (Profile, Axis, Angle, Operation, Targets), Sweep
   (Profile, Path, Operation, Targets), Loft (Sections count, Operation,
   Targets), Pattern and Mirror.
- [ ] 6. **Explicit targets.** Two plates side by side (0..40 and 40..80 in
   X). Sketch a 10×10 square straddling the seam (35..45), Extrude ▸ Cut.
   **Expect:** with Targets on Auto both plates get notched. Undo. Repeat,
   press Pick…: the status bar says "Targets: click bodies to add/remove";
   hovering a body tints it; click plate 2 — it stays tinted and a chip
   "Extrude2 ×" appears in the dialog; Enter (or right-click) returns to the
   dialog; OK. **Expect:** only plate 2 is notched. Clicking the chip's ×
   removes it (back to Auto).
- [ ] 7. **Intersect.** Operation ▸ Intersect with a target: only the overlap
   of the tool and the target body survives; a tool that misses the target
   flags the chip red with "no overlap with <body>".
- [ ] 8. **Cut that misses its target** (explicit target that the tool never
   reaches): red chip "does not touch <body>".
- [ ] 9. **Pattern of a feature.** Cut one small pocket in a plate. Press
   Pattern with nothing selected. **Expect:** the dialog opens with Source ▸
   Pick… armed; switch Source to "Feature"; hover the pocket — ALL of the
   pocket's faces light up (not the whole body); click. Count 4, step 10 in
   X, OK. **Expect:** four pockets in the plate, ONE body in the browser
   (no "Pattern1 1/2/3" bodies). Edit the pocket's depth via its chip:
   every instance follows. Source ▸ "Body" still patterns whole bodies as
   before (browser rows per instance).
- [ ] 10. **Mirror of a feature.** Same pocket; Mirror, Source ▸ Feature,
   click the pocket, Plane ▸ XZ (or Pick… and click the plane in the
   viewport — planes appear, hover glows). **Expect:** the mirrored pocket
   is cut on the other side of the plate; if the mirror lands outside every
   body the chip goes red ("touches no body").
- [ ] 11. **Mirror a body** (the old flow): select a body, press Mirror.
   **Expect:** the dialog opens with the body as Source and the plane Pick…
   already armed — click a plane in the viewport, it lands in the Plane
   dropdown; OK mirrors.
- [ ] 12. **Move, then cut.** Extrude a block, Move Body +50 in X, then sketch
   and Cut a pocket where the block now IS. **Expect:** the pocket is carved
   (before M39 booleans targeted the pre-move position).
- [ ] 13. Both themes: dialog labels, placeholder text, the inline error, the
   target chips and the tinted target bodies all read clearly.

### Fix log

(none yet)

---

## §M40 — Extents, draft, hole wizard

Status: PENDING

Extrude grew the Fusion extent set and a taper; every extrude can be
edited from its chip; the Hole wizard drills standard holes on a face.

- [ ] 1. **Edit an extrude.** Double-click any Extrude chip (or right-click
   ▸ Edit…). **Expect:** the same dialog as creation, titled "Edit
   ExtrudeN", every field prefilled EXACTLY (a 10 mm extrude in inch display
   reads "0.393701 in", not "0.394 in" — confirming untouched must not
   change the model). Change the distance; OK; the body updates; undo is
   one step.
- [ ] 2. **Symmetric.** Extent ▸ Symmetric, distance 10. **Expect:** the body
   spans −10..+10 around the sketch plane; tick "distance is the whole
   length" → −5..+5.
- [ ] 3. **Two Sided.** Distance 5, Distance 2 = 3. **Expect:** 5 one way, 3
   the other, whichever sign the first has.
- [ ] 4. **Through All.** Plate 10 mm on a 20 mm block (step). From a plane
   under both, a cut Extent ▸ Through All. **Expect:** both steps are cut
   the whole way; the Distance field reads "direction only" and its sign
   flips the direction.
- [ ] 5. **To Next.** New body from an offset plane below the block, Extent ▸
   To Next. **Expect:** the pillar stops exactly at the block's underside.
- [ ] 6. **To Object.** Extent ▸ To Object arms the Pick… automatically; hover
   faces (they glow), click the block's top. **Expect:** the dialog shows
   "face of ExtrudeN"; OK; the pillar reaches that face. Edit the block
   height: the pillar follows. Suppress the block: the pillar's chip turns
   red ("to object: its body no longer exists").
- [ ] 7. **Taper.** 10×10 square, 10 mm, Taper 10°. **Expect:** a frustum that
   grows outward; −10° shrinks; walls are flat quads, edges drawn; holes
   in the profile taper the other way (material thickens). Esc in the
   dialog cancels without a feature.
- [ ] 8. **Hole wizard — arm first.** Press Hole with nothing selected.
   **Expect:** the dialog docks top-right with Face ▸ Pick… armed; hovering
   flat faces highlights them; click the plate top — "face of ExtrudeN",
   and placement is armed at once (status bar: "click centres on the face
   … Enter or right-click when done"). Moving over the face shows a ring
   of the current diameter under the cursor; over a circular edge's centre
   or a sketch point/circle centre on that plane it snaps (a small cross,
   status bar names the snap). Click three places; the rings stay; the
   Positions row says "3 placed"; Clear empties them.
- [ ] 9. **Presets.** Size ▸ M6, Fit ▸ Normal clearance → Diameter 6.6 mm;
   Close → 6.4; Loose → 7.0; Tap drill → 4.917 and Thread flips to
   Modelled. Type ▸ Counterbore shows C'bore Ø 11 / depth 6.5 (ISO 4762);
   Countersink shows 12.6 / 90°; a unified size (1/4-20) gives 82°. Size ▸
   Custom leaves the fields alone.
- [ ] 10. **Through / blind.** Depth ▸ Through All hides Distance and Tip; OK.
   **Expect:** clean through holes, exact diameter, edges drawn around each
   rim. Edit the hole (double-click its chip), Depth ▸ Distance 6, Tip 118°:
   blind holes with a drill-point cone; Flat: flat bottoms.
- [ ] 11. **Counterbore / countersink.** Visibly stepped / chamfered entries
   of the preset sizes; a counterbore smaller than the hole is refused
   inline ("Counterbore diameter must exceed the hole diameter").
- [ ] 12. **Modelled thread.** M6 tap drill + Thread ▸ Modelled, Through All.
   **Expect:** a helical ridge inside the hole (orbit close; it is real
   geometry); export STL → the slicer shows threads and reports no repair.
   Cosmetic: plain tap-drill hole, no geometry.
- [ ] 13. **Holes follow the face.** Edit the plate's extrude height.
   **Expect:** the holes still start at the (new) top face. Suppress the
   plate: the hole chip turns amber (warning) and the holes stay put.
- [ ] 14. **Hole on a tilted face** (sketch-on-face plane or a revolved body's
   flat end): the wizard's rings lie in that face and the holes bore along
   its normal.
- [ ] 15. Both themes: preview rings (placed = selection colour, hover =
   hover colour), dialog rows, inline errors.

### Fix log

(none yet)

---

## §M41 — Fillet + chamfer on any edge

Status: PENDING

The Fillet / Chamfer buttons now work on ANY body edge, after any boolean
— picked edge by edge (a click takes the whole smooth chain). The §M35
treatments still load and edit from old files.

- [ ] 1. **Arm first.** With nothing selected press Fillet. **Expect:** the
   dialog docks top-right (Type / Size / Edges + Pick… armed) and every
   visible body's edges draw as thin candidate lines (`edge_candidate`
   colour); hovering an edge highlights its whole chain; the status bar
   says "Fillet: click edges to add/remove (0 picked…)".
- [ ] 2. Click a straight box edge — it turns into a thick selection tube,
   Edges reads "1 picked on ExtrudeN". Click it again: off. Click an edge of
   ANOTHER body: refused with "all edges must belong to … (Clear to switch
   bodies)". Clear empties the pick.
- [ ] 3. **Select first.** Select a body, press Chamfer: only that body's
   edges are candidates.
- [ ] 4. Fillet one top edge at 3 mm, OK. **Expect:** a smooth round with
   hairlines along its two tangent lines, no seam lines across the round;
   the body is watertight (STL export slices clean). Undo removes it.
- [ ] 5. **Hole rim.** Drill a through hole (wizard), then Chamfer, click the
   hole's top rim — the WHOLE circle highlights as one chain; 1 mm; OK.
   **Expect:** a clean conical countersink-like chamfer all round.
- [ ] 6. **Concave.** Cut a pocket; Fillet the pocket FLOOR edge (where the
   floor meets a wall) at 2 mm. **Expect:** material is ADDED — a concave
   round in the corner; the pocket rim (convex) rounds by removal.
- [ ] 7. **All four top edges** of a box at 3 mm. **Expect:** rounds along
   all four and rounded BALL corners where they meet (no little pyramids
   or gaps), watertight.
- [ ] 8. **Too big.** Fillet 25 mm on a 10 mm thick plate edge. **Expect:**
   the chip turns amber with "… could not be rounded — size too large for
   the geometry?" and the body stays sharp there (no crash, no explosion).
- [ ] 9. **Edit.** Double-click the fillet's chip. **Expect:** the dialog
   reopens with the feature's edges pre-selected ON THE BODY AS IT WAS
   BEFORE THE FILLET (the original sharp edges, not the tangent lines);
   switch Type to Chamfer, size 3, OK: the body updates; undo is one step.
- [ ] 10. **Upstream edit.** Change the plate's extrude distance after
   filleting its top edges. **Expect:** the fillet follows the new top;
   no amber chip.
- [ ] 11. Fillet after a pattern of cuts, after a mirror, on a revolved
   body's rim: candidates exist and rounds apply (sweep/loft walls may
   refuse — amber chip with a reason, not a crash).
- [ ] 12. Both themes: candidate lines, hover chain, selection tubes read
   against the body.

### Fix log

(none yet)

---

## §M42 — Shell, combine, split, press-pull

Status: PENDING

Four new Modify commands, all on the shared dialog shell with arm-first
picking and chip editing.

- [ ] 1. **Shell — arm first.** Box 40×30×10. Press Shell with nothing
   selected. **Expect:** dialog docks top-right (Body / Open faces + Pick…
   armed / Thickness / Direction); hovering faces highlights them; click
   the top face: Body reads "ExtrudeN", Open faces "1 face(s) open"; click
   it again toggles it off; Clear empties. Enter (or right-click) ends the
   pick; 2 mm; OK. **Expect:** an open-top box with 2 mm walls and floor,
   crisp inner edges drawn, watertight (export STL and slice).
- [ ] 2. No faces removed: a closed hollow box (look through a later cut).
   Direction ▸ Outside: the original body becomes the cavity, walls grow
   around it (outer size 44×34×14). Thickness 8 on the 10 mm box: amber /
   red chip "thickness too large for this body…", body unchanged.
- [ ] 3. Shell a body with a hole: the hole's wall gets shelled too (a
   tube); a cylinder (revolve) shells to a cup when its top is removed.
- [ ] 4. **Combine.** Two overlapping bodies; select one, press Combine.
   **Expect:** Target prefilled with the selection, Tools Pick… armed; click
   the other body (tints); Enter; Operation ▸ Cut; OK. **Expect:** the tool
   is consumed and its overlap removed from the target; "Keep tools" leaves
   the tool in place. Join merges into one body; Intersect keeps the
   overlap only. A tool that misses the target: red chip "… does not touch
   the target".
- [ ] 5. **Split.** Select a body, press Split, Split by ▸ Plane, choose an
   offset plane through it, OK. **Expect:** two bodies in the browser
   (ExtrudeN keeps the plane's +normal side; "SplitN" is the other half),
   both watertight, each selectable and movable. Split by ▸ Face: Pick… arms
   itself; click a flat face of ANOTHER body lying through the first.
- [ ] 6. **Press Pull.** Press Press Pull; the face pick is armed; click a
   flat face; Distance +5; OK. **Expect:** the face moves out and the body
   grows (joined, no seam line where the prism meets). −4: the face moves
   in (material removed). A face with a hole in it (a ring) presses as a
   ring. Push deeper than the body: the body vanishes (no crash).
- [ ] 7. **Edit** any of the four from its chip: prefilled, re-pick works,
   OK updates, undo is one step.
- [ ] 8. **Upstream edit.** Change the plate height under a Shell and under a
   Press Pull: both follow their faces (no amber chip).
- [ ] 9. Ribbon at 1280 px wide: MODIFY collapses its trailing tools into
   the » flyout; everything is reachable there.
- [ ] 10. Both themes: dialog rows, hover faces, target tints.

### Fix log

(none yet)

---

## §M43 — Inspection

Status: PENDING

New INSPECT ribbon group: Measure, Section, and a stack with Properties,
Interference, Print Check.

- [ ] 1. **Properties.** Select a body, press Properties (stack face).
   **Expect:** a docked panel: Body, Material dropdown (PLA default, with
   densities), Volume (in the display unit AND cm³), Surface area, Mass,
   Size, Centre of mass, Inertia, Watertight; a red sphere marks the centre
   of mass in the viewport while the panel is open (checkbox hides it).
   Switch Material ▸ Steel: mass updates; Save/Open: the material is
   remembered with the document. With nothing selected the button arms a
   body pick (hover tints, click opens the panel for that body).
- [ ] 2. **Section.** Press Section. **Expect:** the dialog opens with
   "show the cut" ticked, plane XZ, offset through the middle of the
   model; bodies are cut away in front of the plane and the cut faces are
   painted `section_cap` (red), holes/pockets show as gaps in the cap. Type
   a new offset: the cut moves live; "flip which side is kept" flips; the
   Plane dropdown lists construction planes too. Close keeps the section
   and the Section button stays lit; press it again and Cancel: the section
   switches off. Face picks and edge picks still work on the cut bodies.
- [ ] 3. **Interference.** Two overlapping bodies; press Interference (stack
   flyout); Check. **Expect:** "ExtrudeN ∩ ExtrudeM: … in³" and the overlap
   drawn as a translucent red volume; "no interference" when they don't
   touch; Bodies ▸ Pick… restricts the check to chosen bodies.
- [ ] 4. **Print Check.** Select a body, Print Check. **Expect:** Watertight,
   Fits bed (bed size editable, remembered in preferences), "x % of the
   surface needs support (>45°)" with overhanging faces shaded amber in
   the viewport; a box reports 0 %; a 60° outward taper reports a lot.
   Change the angle field: live update.
- [ ] 5. **Measure.** Press Measure; status bar explains. Hover a body
   corner — a highlighted dot snaps to it (bigger dot = snapped), an edge
   snaps to the edge, a face interior shows its area and normal in the
   measure slot. Click corner A, then corner B: a line and the distance
   with Δx/Δy/Δz in the status bar (display unit). A third click starts
   the next measurement from that point; right-click or Esc ends it and
   clears the markers; the Measure button toggles off.
- [ ] 6. Both themes: section cap colour, overhang shading, markers.

### Fix log

(none yet)

---

## §M44 — Exchange: 3MF, mesh import, OBJ, SVG

Status: PENDING

- [ ] 1. **Export 3MF.** A document with two coloured bodies (Appearance on
   one). MAKE ▸ Export 3MF (stack face; STL and OBJ in its flyout). Save.
   **Expect:** the slicer (PrusaSlicer / Bambu / Cura) opens it with two
   objects named like the bodies, right size (mm), the colour on the
   coloured one, no repair warnings. The file has a thumbnail (the viewport).
- [ ] 2. **Export OBJ** of the same: opens in Blender at mm scale (set the
   importer's scale), one object per body.
- [ ] 3. **Import Mesh.** INSERT ▸ Import Mesh, pick an STL (e.g. the
   exported one). **Expect:** the file dialog offers File units
   (mm/in/cm/m); the body lands as "MeshN" (or the file's object name), a
   chip with the mesh icon, selectable, measurable, the browser lists it.
   Extrude a Cut through it with Targets ▸ the mesh body: it is carved.
   Fillet one of its edges. Section through it.
- [ ] 4. **3MF with several objects** imports as several bodies; an OBJ with
   `o` groups too.
- [ ] 5. **Open mesh.** Import a non-watertight mesh (a single quad OBJ,
   or a scanned part with holes). **Expect:** it shows, amber chip "mesh is
   not a closed solid — shown for reference, excluded from booleans"; a
   cut targeting it reports "touches no body".
- [ ] 6. **Save/Open** a document with imported meshes: the meshes come back
   exactly (the triangles live in the .ecad).
- [ ] 7. **Export SVG** of a sketch (MAKE ▸ the DXF stack's flyout, or the
   browser's sketch menu if present): opens in Inkscape at the right size
   in mm; lines, circles and arcs are true SVG primitives; splines are
   polylines; "Include construction geometry" adds dashed strokes.
- [ ] 8. Both themes: the file dialogs' extra rows (units, construction).

### Fix log

(none yet)

---

## §M46 — Document safety

Status: PENDING

- [ ] 1. **Start panel.** Launch with no file. **Expect:** a centred panel
   over the viewport — New Sketch / Open… / Import Mesh… and (after you
   have saved something) a Recent list; Dismiss hides it; pressing any
   ribbon tool also hides it. It never shows for a loaded document.
- [ ] 2. **Autosave.** Draw something, wait 2 minutes (the interval; set
   `autosave_seconds` in the settings file to shorten). **Expect:**
   `user://autosave/<name>.autosave.ecad` appears; saving the document
   removes it; a clean document never writes one.
- [ ] 3. **Recovery.** Draw, wait for the autosave, then `kill -9` the app.
   Relaunch. **Expect:** "Recover unsaved work?" names the file and time;
   Recover loads it with the unsaved mark set and the original file name
   (Ctrl+S writes to it); Discard deletes the autosave and opens normally.
- [ ] 4. **Unsaved guard.** With unsaved changes: close the window, File ▸
   New (Ctrl+N), File ▸ Open (Ctrl+O) and a Recent file. **Expect:** each
   asks Save / Don't save / Cancel; Save with no file name opens Save As
   and continues after it; Cancel does nothing; a clean document skips the
   question.
- [ ] 5. **Recent files.** File ▸ Open Recent lists the last 10 saved/opened
   files (newest first, tooltips show the path, missing files are dropped);
   Clear list empties it.
- [ ] 6. **Newer file.** Hand-edit a .ecad's `"version"` to 99 and open it.
   **Expect:** refused with "saved by a newer EchoCAD…" in a dialog and the
   status bar; the current document is untouched.
- [ ] 7. **Settings.** Change the theme, quit, run the test suites, relaunch:
   theme, ortho, tool names, print bed and recent files all survive (prefs
   live in `[prefs]` of the same settings file; tests use their own file).
- [ ] 8. Both themes: the start panel, the recovery and unsaved dialogs.

### Fix log

(none yet)

---

## §M47 — Performance + robustness

Status: PENDING

- [ ] 1. **Incremental rebuild.** Build a plate with 10+ cuts, four modelled-
   thread holes and a fillet (a model that takes noticeable time to
   rebuild from scratch). Edit the LAST feature: the update is near
   instant; edit the FIRST (plate height): everything downstream rebuilds
   (slower, as expected). Undo/redo, suppress, delete, rollback marker: the
   result always equals a fresh rebuild (File ▸ Open of the saved file
   shows the same bodies).
- [ ] 2. **Feel.** Dragging a dimension in a sketch with an extrude on it:
   the 3D body follows on release with no lag; orbiting never stutters
   during rebuilds of alpha-sized models.
- [ ] 3. **Fuzz.** `tools/run_tests.sh m47` passes (60-step random chain,
   every body watertight, cached == fresh, serializer round trip).
- [ ] 4. Open every sample/test .ecad: none takes more than a second to
   appear; none leaves a red chip that was not red before.

### Fix log

(none yet)
