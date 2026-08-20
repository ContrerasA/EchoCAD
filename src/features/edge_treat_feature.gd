class_name EdgeTreatFeature
extends Feature
## M35 3D fillet/chamfer — PRISMATIC scope, honest about what mesh CSG can
## do without a B-rep kernel: it treats the edges of a body rooted at a
## single plain EXTRUDE (no booleans, no holes in the profile).
##   - lateral edges (parallel to the extrude direction): the profile's
##     corners are rounded/cut in 2D before extrusion — exact and cheap.
##   - cap rims (top/bottom): chamfer = a conical band to an inset ring;
##     fillet = quarter-round rings of insets (loft-style bands).
## Applied by BodyBuilder's post pass: the body's mesh is REBUILT from the
## extrude's own profile with the treatments baked in. Everything else
## (booleans, revolves, sweeps) is refused with a status hint.

const KIND_FILLET := "fillet"
const KIND_CHAMFER := "chamfer"

var body := ""              # root feature id (must be a plain extrude)
var treat := KIND_FILLET
var size_mm := 3.0          # radius (fillet) or leg distance (chamfer)
var lateral := true         # round/cut profile corners (see `corners`)
var top := true             # treat the offset-cap rim
var bottom := false         # treat the plane-cap rim
## WHICH profile corners (indices into the ccw profile polygon) when
## `lateral` — empty means every eligible corner, which is also what
## pre-M35-QA documents deserialize to. Filled by the viewport edge pick.
var corners: Array = []
## WHICH rim segments (indices of the ccw profile polygon's edges) when
## `top` / `bottom` — empty means the WHOLE rim (also what older documents
## deserialize to). Filled by the viewport edge pick (QA §M35.1 round 2).
var top_segs: Array = []
var bottom_segs: Array = []

const FILLET_STEPS := 10
const CORNER_ARC_STEPS := 16
## Corners flatter than this are left alone (a tessellated circle's
## vertices are not "corners").
const CORNER_MIN_DEG := 25.0


func kind() -> String:
	return "edge_treat"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["body"] = body
	d["treat"] = treat
	d["size_mm"] = size_mm
	d["lateral"] = lateral
	d["top"] = top
	d["bottom"] = bottom
	if not corners.is_empty():
		d["corners"] = corners.duplicate()
	if not top_segs.is_empty():
		d["top_segs"] = top_segs.duplicate()
	if not bottom_segs.is_empty():
		d["bottom_segs"] = bottom_segs.duplicate()
	return d


static func from_dict(d: Dictionary) -> EdgeTreatFeature:
	var f := EdgeTreatFeature.new()
	f._read_base(d)
	f.body = String(d.get("body", ""))
	f.treat = String(d.get("treat", KIND_FILLET))
	f.size_mm = float(d.get("size_mm", 3.0))
	f.lateral = bool(d.get("lateral", true))
	f.top = bool(d.get("top", true))
	f.bottom = bool(d.get("bottom", false))
	for c in (d.get("corners", []) as Array):
		f.corners.append(int(c))
	for s in (d.get("top_segs", []) as Array):
		f.top_segs.append(int(s))
	for s in (d.get("bottom_segs", []) as Array):
		f.bottom_segs.append(int(s))
	return f


## Is polygon vertex `cur` a treatable corner? Sharp enough (a tessellated
## circle's vertices are not corners) and convex (a fillet on a reflex
## corner needs material ADDED — out of scope). Shared by treat_corners
## and the viewport edge pick so they agree on what is selectable.
static func corner_eligible(prev: Vector2, cur: Vector2,
		next: Vector2) -> bool:
	var u := (prev - cur).normalized()
	var w := (next - cur).normalized()
	var theta := acos(clampf(u.dot(w), -1.0, 1.0))
	if rad_to_deg(PI - theta) < CORNER_MIN_DEG:
		return false
	return (cur - prev).cross(next - cur) > 0.0


## Round/cut the sharp corners of a CCW ring in 2D. Fillet corners become
## sampled arcs; chamfer corners become a straight cut. `only` (a set of
## polygon indices) limits the treatment to those corners — empty treats
## every eligible one. Returns the new ring, or [] when the size does not
## fit an edge.
static func treat_corners(poly: PackedVector2Array, p_treat: String,
		size: float, only := {}) -> PackedVector2Array:
	return treat_corners_mapped(poly, p_treat, size, only)["poly"]


## treat_corners plus a map back to the ORIGINAL polygon: seg[j] is the
## original segment index of the edge STARTING at out[j], or -1 for edges
## introduced by a corner cut/arc. -> {poly, seg}; empty poly = no fit.
## The partial-rim builder needs this to know which treated-poly edges the
## picked rim segments landed on.
static func treat_corners_mapped(poly: PackedVector2Array, p_treat: String,
		size: float, only := {}) -> Dictionary:
	var n := poly.size()
	var out := PackedVector2Array()
	var seg: Array = []
	for i in n:
		var prev := poly[(i - 1 + n) % n]
		var cur := poly[i]
		var next := poly[(i + 1) % n]
		if not corner_eligible(prev, cur, next) \
				or (not only.is_empty() and not only.has(i)):
			out.append(cur)
			seg.append(i)
			continue
		var u := (prev - cur).normalized()
		var w := (next - cur).normalized()
		var theta := acos(clampf(u.dot(w), -1.0, 1.0))
		var leg := size if p_treat == KIND_CHAMFER \
			else size / tan(theta * 0.5)
		if leg > prev.distance_to(cur) * 0.5 - 1e-6 \
				or leg > next.distance_to(cur) * 0.5 - 1e-6:
			return {"poly": PackedVector2Array(), "seg": []}   # does not fit
		var t1 := cur + u * leg
		var t2 := cur + w * leg
		if p_treat == KIND_CHAMFER:
			out.append(t1)
			seg.append(-1)
			out.append(t2)
			seg.append(i)
			continue
		var bis := (u + w).normalized()
		var center := cur + bis * (size / sin(theta * 0.5))
		var a0 := (t1 - center).angle()
		var a1 := (t2 - center).angle()
		var sweep := wrapf(a1 - a0, -PI, PI)
		for k in CORNER_ARC_STEPS + 1:
			var a := a0 + sweep * k / CORNER_ARC_STEPS
			out.append(center + Vector2(cos(a), sin(a)) * size)
			seg.append(i if k == CORNER_ARC_STEPS else -1)
	return {"poly": out, "seg": seg}


## The selectable edges of `ef`'s prismatic body, for the M35 viewport
## pick. -> [{key: String, a: Vector3, b: Vector3}] in world mm.
## Each eligible profile corner is one lateral edge ("corner:<i>", i an
## index into the ccw profile polygon); each rim SEGMENT is individually
## selectable too ("top:<i>" / "bottom:<i>", i the polygon edge index —
## QA §M35.1 round 2).
static func pickable_edges(doc: CadDocument, ef: ExtrudeFeature) -> Array:
	var sf := doc.sketch_feature(ef.sketch_id)
	if sf == null:
		return []
	var healed := ProfileFinder.profile_at_healed(sf.sketch, ef.anchor)
	if healed.is_empty():
		return []
	var prof: Dictionary = healed["prof"]
	ef.anchor = healed["at"]
	if not (prof.get("holes", []) as Array).is_empty():
		return []
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	if ExtrudeFeature._signed_area(poly) < 0.0:
		poly.reverse()
	var xf := sf.plane_transform()
	var off: Vector3 = xf.basis.z * ef.distance
	var out: Array = []
	var n := poly.size()
	for i in n:
		if not corner_eligible(poly[(i - 1 + n) % n], poly[i],
				poly[(i + 1) % n]):
			continue
		var base: Vector3 = xf * Vector3(poly[i].x, poly[i].y, 0.0)
		out.append({"key": "corner:%d" % i, "a": base, "b": base + off})
	for i in n:
		var a: Vector3 = xf * Vector3(poly[i].x, poly[i].y, 0.0)
		var b: Vector3 = xf * Vector3(poly[(i + 1) % n].x,
			poly[(i + 1) % n].y, 0.0)
		out.append({"key": "top:%d" % i, "a": a + off, "b": b + off})
		out.append({"key": "bottom:%d" % i, "a": a, "b": b})
	return out


## Vertical inset schedule for a cap treatment: [{dz, inset}] from the rim
## toward the cap (dz measured INTO the body from the cap plane).
static func cap_schedule(p_treat: String, size: float) -> Array:
	var out: Array = []
	if p_treat == KIND_CHAMFER:
		out.append({"dz": size, "inset": 0.0})
		out.append({"dz": 0.0, "inset": size})
		return out
	for k in FILLET_STEPS + 1:
		var a := (PI * 0.5) * k / FILLET_STEPS
		out.append({"dz": size - size * sin(a),
			"inset": size - size * cos(a)})
	return out


## The treated replacement mesh for `ef`'s body, or null (with the reason
## in "error" via the returned dict? -> null means refuse).
func build_treated_mesh(doc: CadDocument, ef: ExtrudeFeature) -> ArrayMesh:
	var sf := doc.sketch_feature(ef.sketch_id)
	if sf == null:
		return null
	var healed := ProfileFinder.profile_at_healed(sf.sketch, ef.anchor)
	if healed.is_empty():
		return null
	var prof: Dictionary = healed["prof"]
	ef.anchor = healed["at"]
	if not (prof.get("holes", []) as Array).is_empty():
		return null
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	if ExtrudeFeature._signed_area(poly) < 0.0:
		poly.reverse()
	# PARTIAL rims (some but not all segments picked) go through the
	# segment-wise builder; whole rims keep the exact offset-ring path.
	var n0 := poly.size()
	if (top and not _rim_full(top_segs, n0)) \
			or (bottom and not _rim_full(bottom_segs, n0)):
		return _build_partial_mesh(doc, ef, poly)
	if lateral:
		var only := {}
		for ci in corners:
			only[int(ci)] = true
		poly = treat_corners(poly, treat, size_mm, only)
		if poly.is_empty():
			return null
	var h := absf(ef.distance)
	if size_mm <= 0.0 or ((top and bottom) and 2.0 * size_mm > h - 1e-6) \
			or ((top or bottom) and size_mm > h - 1e-6):
		return null
	var xf := sf.plane_transform()
	var zsign := 1.0 if ef.distance >= 0.0 else -1.0

	# Height/ring stations bottom -> top.
	var stations: Array = []   # {z (0..h), ring}
	if bottom:
		var sched := cap_schedule(treat, size_mm)
		for i in range(sched.size() - 1, -1, -1):
			var s: Dictionary = sched[i]
			var ring := SolidFeature.offset_ring(poly, -float(s["inset"]))
			if ring.size() < 3:
				return null
			stations.append({"z": float(s["dz"]), "ring": ring})
	else:
		stations.append({"z": 0.0, "ring": poly})
	if top:
		var sched2 := cap_schedule(treat, size_mm)
		# From the rim inward: dz decreases toward the cap.
		stations.append({"z": h - size_mm, "ring": poly})
		for s2: Dictionary in sched2:
			if absf(float(s2["dz"]) - size_mm) < 1e-9:
				continue   # rim station already added
			var ring2 := SolidFeature.offset_ring(poly, -float(s2["inset"]))
			if ring2.size() < 3:
				return null
			stations.append({"z": h - float(s2["dz"]), "ring": ring2})
	else:
		stations.append({"z": h, "ring": poly})

	# Bands need a common vertex count. When every station shares the SAME
	# ring (lateral-only treatments), use it verbatim — arclength resampling
	# would shave the sharp chamfer corners off. Offset rings (cap
	# treatments) resample densely instead, since Clipper offsets renumber
	# vertices freely.
	var uniform := true
	for st: Dictionary in stations:
		if (st["ring"] as PackedVector2Array) != poly:
			uniform = false
			break
	var samples := poly.size()
	if not uniform:
		for st: Dictionary in stations:
			samples = maxi(samples, (st["ring"] as PackedVector2Array).size())
		samples = maxi(samples * 4, 64)
	var rings3: Array = []
	for st: Dictionary in stations:
		var flat: PackedVector2Array = st["ring"] if uniform \
			else LoftFeature.resample_ring(st["ring"], samples)
		var world := PackedVector3Array()
		for p in flat:
			world.append(xf * Vector3(p.x, p.y, float(st["z"]) * zsign))
		rings3.append(world)
	if not uniform:
		for k in range(1, rings3.size()):
			rings3[k] = LoftFeature._align_ring(rings3[k - 1], rings3[k])

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for k in rings3.size() - 1:
		var r0: PackedVector3Array = rings3[k]
		var r1: PackedVector3Array = rings3[k + 1]
		for i in samples:
			var a0 := r0[i]
			var b0 := r0[(i + 1) % samples]
			var a1 := r1[i]
			var b1 := r1[(i + 1) % samples]
			verts.append_array([a0, b0, b1, a0, b1, a1])
			var wn := ((b0 - a0).cross(b1 - a0)).normalized()
			for _i in 6:
				normals.append(wn)
	# Caps: triangulate the first and last rings. A ccw-in-plane triangle
	# maps to a +plane-normal face, so the cap whose outward side is the
	# NEGATIVE normal gets its triangles reversed explicitly (the global
	# orientation pass below can only flip everything at once).
	for endi in [0, rings3.size() - 1]:
		var ring: PackedVector3Array = rings3[endi]
		var flat2 := PackedVector2Array()
		for p in ring:
			var local := xf.affine_inverse() * p
			flat2.append(Vector2(local.x, local.y))
		var idx := Geometry2D.triangulate_polygon(flat2)
		var outward := xf.basis.z * zsign * (1.0 if endi > 0 else -1.0)
		var reverse := outward.dot(xf.basis.z) < 0.0
		var t := 0
		while t + 2 < idx.size():
			if reverse:
				verts.append_array([ring[idx[t]], ring[idx[t + 2]],
					ring[idx[t + 1]]])
			else:
				verts.append_array([ring[idx[t]], ring[idx[t + 1]],
					ring[idx[t + 2]]])
			for _i in 3:
				normals.append(outward)
			t += 3
	if verts.is_empty():
		return null
	SweepFeature._orient_outward(verts, normals)
	LoftFeature._fix_flat_normals(verts, normals)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var edges := PackedVector3Array()
	for endi in [0, rings3.size() - 1]:
		var ring: PackedVector3Array = rings3[endi]
		for i in samples:
			edges.append_array([ring[i], ring[(i + 1) % samples]])
	var earr := []
	earr.resize(Mesh.ARRAY_MAX)
	earr[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


## Does `segs` mean the whole rim? Empty (legacy documents + RPC's plain
## top/bottom flags) and every-segment-picked both do.
static func _rim_full(segs: Array, n: int) -> bool:
	return segs.is_empty() or segs.size() >= n


## Partial-rim builder (QA §M35.1 round 2): rim segments are individually
## selectable, so a treated rim may cover only SOME of the profile's edges.
## Built segment-wise in the sketch's local frame (z 0..h): full-height
## walls under untreated rim edges, shortened walls + inset band strips
## under treated ones, miter joints where two treated edges meet, flat end
## fans where a treated run stops, and caps triangulated over the mixed
## boundary. Corner arcs/cuts from the lateral pass count as untreated rim
## (rolling a rim treatment around a rounded corner is B-rep-kernel tier).
func _build_partial_mesh(doc: CadDocument, ef: ExtrudeFeature,
		poly0: PackedVector2Array) -> ArrayMesh:
	var n0 := poly0.size()
	var sf := doc.sketch_feature(ef.sketch_id)
	var xf := sf.plane_transform()
	var h := absf(ef.distance)
	var zsign := 1.0 if ef.distance >= 0.0 else -1.0
	if size_mm <= 0.0 or ((top and bottom) and 2.0 * size_mm > h - 1e-6) \
			or ((top or bottom) and size_mm > h - 1e-6):
		return null
	var poly := poly0
	var seg: Array = []
	for i in n0:
		seg.append(i)
	if lateral:
		var only := {}
		for ci in corners:
			only[int(ci)] = true
		var mapped := treat_corners_mapped(poly0, treat, size_mm, only)
		poly = mapped["poly"]
		seg = mapped["seg"]
		if poly.is_empty():
			return null
	var m := poly.size()
	var t_set := {}
	var b_set := {}
	if top:
		for i in (top_segs if not top_segs.is_empty() else range(n0)):
			t_set[int(i)] = true
	if bottom:
		for i in (bottom_segs if not bottom_segs.is_empty() else range(n0)):
			b_set[int(i)] = true
	var et_top: Array = []
	var et_bot: Array = []
	for j in m:
		et_top.append(int(seg[j]) >= 0 and t_set.has(int(seg[j])))
		et_bot.append(int(seg[j]) >= 0 and b_set.has(int(seg[j])))
	var sched := cap_schedule(treat, size_mm)   # ordered rim -> cap
	var ks := sched.size()

	var norms_in: Array = []   # inward edge normals (ccw polygon)
	for j in m:
		var d := poly[(j + 1) % m] - poly[j]
		if d.length() < 1e-9:
			return null
		d = d.normalized()
		norms_in.append(Vector2(-d.y, d.x))

	# Corner solve: the point near the shared vertex where edge j's offset
	# line (inset i_self) meets the neighbor's offset line (inset i_other).
	# i_other = same station inset when the neighbor is treated in the same
	# rim (a true miter), 0 when it is not (the band end SLIDES along the
	# neighbor's wall plane, so the neighbor wall can be clipped watertight).
	# ok=false when the lines are near-parallel (lateral corner arcs) — the
	# caller falls back to a plain offset plus a sealing end fan.
	var corner_off := func(j: int, lead: bool, i_self: float,
			i_other: float) -> Dictionary:
		var v := poly[j] if lead else poly[(j + 1) % m]
		var other := (j - 1 + m) % m if lead else (j + 1) % m
		var m1: Vector2 = norms_in[j]
		var m2: Vector2 = norms_in[other]
		var det := m1.x * m2.y - m1.y * m2.x
		if absf(det) < 0.2:
			if absf(i_self - i_other) < 1e-9:
				return {"p": v + m1 * i_self, "ok": true}   # parallel: exact
			return {"p": v + m1 * i_self, "ok": false}
		return {"p": v + Vector2((i_self * m2.y - i_other * m1.y) / det,
			(i_other * m1.x - i_self * m2.x) / det), "ok": true}

	var tris := PackedVector3Array()   # local coords, z in 0..h

	# Band strips + (fallback) end fans, per treated edge, per rim.
	for j in m:
		for is_top in [true, false]:
			var et: Array = et_top if is_top else et_bot
			if not et[j]:
				continue
			var zof := func(dz: float) -> float:
				return h - dz if is_top else dz
			var lead_i_other := size_mm if et[(j - 1 + m) % m] else 0.0
			var trail_i_other := size_mm if et[(j + 1) % m] else 0.0
			# Fit: the cap-level ring must keep some edge length.
			var pk: Dictionary = corner_off.call(j, true, size_mm, lead_i_other)
			var qk: Dictionary = corner_off.call(j, false, size_mm, trail_i_other)
			if (pk["p"] as Vector2).distance_to(qk["p"] as Vector2) < 1e-6:
				return null
			for k in ks - 1:
				var ia := float(sched[k]["inset"])
				var ib := float(sched[k + 1]["inset"])
				var za: float = zof.call(float(sched[k]["dz"]))
				var zb: float = zof.call(float(sched[k + 1]["dz"]))
				var pa: Vector2 = corner_off.call(j, true, ia,
					ia if et[(j - 1 + m) % m] else 0.0)["p"]
				var qa: Vector2 = corner_off.call(j, false, ia,
					ia if et[(j + 1) % m] else 0.0)["p"]
				var pb: Vector2 = corner_off.call(j, true, ib,
					ib if et[(j - 1 + m) % m] else 0.0)["p"]
				var qb: Vector2 = corner_off.call(j, false, ib,
					ib if et[(j + 1) % m] else 0.0)["p"]
				if is_top:
					tris.append_array([
						Vector3(pa.x, pa.y, za), Vector3(qa.x, qa.y, za),
						Vector3(qb.x, qb.y, zb),
						Vector3(pa.x, pa.y, za), Vector3(qb.x, qb.y, zb),
						Vector3(pb.x, pb.y, zb)])
				else:
					tris.append_array([
						Vector3(pb.x, pb.y, zb), Vector3(qb.x, qb.y, zb),
						Vector3(qa.x, qa.y, za),
						Vector3(pb.x, pb.y, zb), Vector3(qa.x, qa.y, za),
						Vector3(pa.x, pa.y, za)])
			# Sealing fans only for near-parallel fallback ends.
			for lead in [true, false]:
				var other := (j - 1 + m) % m if lead else (j + 1) % m
				if et[other]:
					continue
				var probe: Dictionary = corner_off.call(j, lead, size_mm, 0.0)
				if probe["ok"]:
					continue
				var v := poly[j] if lead else poly[(j + 1) % m]
				var mj: Vector2 = norms_in[j]
				var apex := Vector3(v.x, v.y, h if is_top else 0.0)
				for k in ks - 1:
					var i0v := v + mj * float(sched[k]["inset"])
					var i1v := v + mj * float(sched[k + 1]["inset"])
					var e0 := Vector3(i0v.x, i0v.y,
						zof.call(float(sched[k]["dz"])))
					var e1 := Vector3(i1v.x, i1v.y,
						zof.call(float(sched[k + 1]["dz"])))
					if (is_top and not lead) or (not is_top and lead):
						tris.append_array([apex, e0, e1])
					else:
						tris.append_array([apex, e1, e0])

	# Walls: one polygon per edge in its own (u = along-edge, z) plane —
	# rectangles clipped by the neighboring bands' end curves so treated and
	# untreated runs stay watertight.
	for j in m:
		var a2 := poly[j]
		var b2 := poly[(j + 1) % m]
		var dir := (b2 - a2).normalized()
		var length := a2.distance_to(b2)
		var u_of := func(p: Vector2) -> float:
			return (p - a2).dot(dir)
		var zlo: float = size_mm if et_bot[j] else 0.0
		var zhi: float = h - (size_mm if et_top[j] else 0.0)
		if zhi - zlo < 1e-6:
			return null
		# Does the corner at `lead` get clipped by the neighbor's band on
		# rim `is_top`? Only when edge j itself is untreated there, the
		# neighbor IS treated, and the corner solve is non-degenerate.
		var clip_curve := func(lead: bool, is_top: bool) -> PackedVector2Array:
			var et: Array = et_top if is_top else et_bot
			var other := (j - 1 + m) % m if lead else (j + 1) % m
			if et[j] or not et[other]:
				return PackedVector2Array()
			var probe: Dictionary = corner_off.call(j, lead, 0.0, size_mm)
			if not probe["ok"]:
				return PackedVector2Array()
			# (u, z) points from the rim shoulder toward the cap.
			var out2 := PackedVector2Array()
			for k in ks:
				var q: Vector2 = corner_off.call(j, lead, 0.0,
					float(sched[k]["inset"]))["p"]
				var zq: float = (h - float(sched[k]["dz"])) if is_top \
					else float(sched[k]["dz"])
				out2.append(Vector2(u_of.call(q), zq))
			return out2
		var bl: PackedVector2Array = clip_curve.call(true, false)
		var br: PackedVector2Array = clip_curve.call(false, false)
		var tl: PackedVector2Array = clip_curve.call(true, true)
		var tr: PackedVector2Array = clip_curve.call(false, true)
		var wall := PackedVector2Array()
		# CCW in (u, z): bottom left -> right, up, top right -> left, down.
		if bl.is_empty():
			wall.append(Vector2(0.0, zlo))
		else:
			for k in ks:   # (0, s) down the curve to (u_K, 0)
				wall.append(bl[k])
		if br.is_empty():
			wall.append(Vector2(length, zlo))
		else:
			for k in range(ks - 1, -1, -1):
				wall.append(br[k])
		if tr.is_empty():
			wall.append(Vector2(length, zhi))
		else:
			for k in ks:   # (len, h-s) up the curve to the cap corner
				wall.append(tr[k])
		if tl.is_empty():
			wall.append(Vector2(0.0, zhi))
		else:
			for k in range(ks - 1, -1, -1):
				wall.append(tl[k])
		# Dedupe consecutive repeats, then triangulate in wall space.
		var wpoly := PackedVector2Array()
		for p in wall:
			if wpoly.is_empty() or wpoly[wpoly.size() - 1].distance_to(p) > 1e-7:
				wpoly.append(p)
		if wpoly.size() > 1 and wpoly[0].distance_to(
				wpoly[wpoly.size() - 1]) <= 1e-7:
			wpoly.remove_at(wpoly.size() - 1)
		if wpoly.size() < 3:
			return null
		var widx := Geometry2D.triangulate_polygon(wpoly)
		if widx.is_empty():
			return null
		# A CCW (u, z) triangle maps to the OUTWARD wall normal (-inward).
		var t := 0
		while t + 2 < widx.size():
			for wi in [widx[t], widx[t + 1], widx[t + 2]]:
				var wp := wpoly[wi]
				var w2 := a2 + dir * wp.x
				tris.append(Vector3(w2.x, w2.y, wp.y))
			t += 3

	# Caps over the mixed boundary: at each polygon corner the boundary
	# point is the corner solve at the two edges' cap insets (s when
	# treated, 0 when not — both 0 keeps the original vertex).
	var cap_loops: Array = []   # [{boundary: PackedVector2Array, z: float}]
	for is_top in [true, false]:
		var et: Array = et_top if is_top else et_bot
		var boundary := PackedVector2Array()
		var push := func(p: Vector2) -> void:
			if boundary.is_empty() \
					or boundary[boundary.size() - 1].distance_to(p) > 1e-6:
				boundary.append(p)
		for j in m:
			var i_self: float = size_mm if et[j] else 0.0
			var i_lead: float = size_mm if et[(j - 1 + m) % m] else 0.0
			var i_trail: float = size_mm if et[(j + 1) % m] else 0.0
			push.call(corner_off.call(j, true, i_self, i_lead)["p"])
			push.call(corner_off.call(j, false, i_self, i_trail)["p"])
		if boundary.size() > 1 and boundary[0].distance_to(
				boundary[boundary.size() - 1]) <= 1e-6:
			boundary.remove_at(boundary.size() - 1)
		if boundary.size() < 3 \
				or ExtrudeFeature._signed_area(boundary) <= 0.0:
			return null   # inset crossed itself — size too big for the edge
		var idx := Geometry2D.triangulate_polygon(boundary)
		if idx.is_empty():
			return null
		var zc := h if is_top else 0.0
		var t2 := 0
		while t2 + 2 < idx.size():
			var a3 := Vector3(boundary[idx[t2]].x, boundary[idx[t2]].y, zc)
			var b3 := Vector3(boundary[idx[t2 + 1]].x,
				boundary[idx[t2 + 1]].y, zc)
			var c3 := Vector3(boundary[idx[t2 + 2]].x,
				boundary[idx[t2 + 2]].y, zc)
			if is_top:
				tris.append_array([a3, b3, c3])
			else:
				tris.append_array([a3, c3, b3])
			t2 += 3
		cap_loops.append({"boundary": boundary, "z": zc})

	var verts := PackedVector3Array()
	for v3 in tris:
		verts.append(xf * Vector3(v3.x, v3.y, v3.z * zsign))
	var normals := PackedVector3Array()
	var t3 := 0
	while t3 + 2 < verts.size():
		var wn := ((verts[t3 + 1] - verts[t3]).cross(
			verts[t3 + 2] - verts[t3]))
		if wn.length() < 1e-12:
			normals.append_array([Vector3.UP, Vector3.UP, Vector3.UP])
		else:
			wn = wn.normalized()
			for _i in 3:
				normals.append(wn)
		t3 += 3
	SweepFeature._orient_outward(verts, normals)
	LoftFeature._fix_flat_normals(verts, normals)

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var edges := PackedVector3Array()
	for loop: Dictionary in cap_loops:
		var b: PackedVector2Array = loop["boundary"]
		var zc2 := float(loop["z"]) * zsign
		for i in b.size():
			var a4 := b[i]
			var b4 := b[(i + 1) % b.size()]
			edges.append(xf * Vector3(a4.x, a4.y, zc2))
			edges.append(xf * Vector3(b4.x, b4.y, zc2))
	var earr2 := []
	earr2.resize(Mesh.ARRAY_MAX)
	earr2[Mesh.ARRAY_VERTEX] = edges
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr2)
	return mesh
