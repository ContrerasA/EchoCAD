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
