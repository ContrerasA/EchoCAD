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
