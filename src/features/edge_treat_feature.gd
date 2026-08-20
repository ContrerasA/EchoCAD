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
## vertices are not "corners"). The same threshold decides which rim
## segments chain together for one-click selection (QA §M35.4).
const CORNER_MIN_DEG := 25.0

## Why the last build_combined / build refused, for the status bar. Cleared
## at the start of every build_combined call.
static var build_error := ""


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
	var cmap := {}
	for i in poly.size():
		if only.is_empty() or only.has(i):
			cmap[i] = {"treat": p_treat, "size": size}
	return treat_corners_multi(poly, cmap)


## Per-corner variant: `cmap` maps a polygon index to {treat, size}, so a
## fillet and a chamfer can live on the same profile (QA §M35.3 — stacked
## treatments). Also returns "ctr": per out-vertex, the fillet corner-arc
## CENTER (null off the arcs) — the vertex-blend builder offsets arc
## vertices radially toward it (a chord-normal offset opens cracks between
## the fan's bands). Same contract as treat_corners_mapped otherwise.
static func treat_corners_multi(poly: PackedVector2Array,
		cmap: Dictionary) -> Dictionary:
	var n := poly.size()
	var out := PackedVector2Array()
	var seg: Array = []
	var ctr: Array = []
	for i in n:
		var prev := poly[(i - 1 + n) % n]
		var cur := poly[i]
		var next := poly[(i + 1) % n]
		if not corner_eligible(prev, cur, next) or not cmap.has(i):
			out.append(cur)
			seg.append(i)
			ctr.append(null)
			continue
		var prm: Dictionary = cmap[i]
		var p_treat := String(prm["treat"])
		var size := float(prm["size"])
		var u := (prev - cur).normalized()
		var w := (next - cur).normalized()
		var theta := acos(clampf(u.dot(w), -1.0, 1.0))
		var leg := size if p_treat == KIND_CHAMFER \
			else size / tan(theta * 0.5)
		if leg > prev.distance_to(cur) * 0.5 - 1e-6 \
				or leg > next.distance_to(cur) * 0.5 - 1e-6:
			# does not fit
			return {"poly": PackedVector2Array(), "seg": [], "ctr": []}
		var t1 := cur + u * leg
		var t2 := cur + w * leg
		if p_treat == KIND_CHAMFER:
			out.append(t1)
			seg.append(-1)
			ctr.append(null)
			out.append(t2)
			seg.append(i)
			ctr.append(null)
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
			ctr.append(center)
	return {"poly": out, "seg": seg, "ctr": ctr}


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
		out.append({"key": "corner:%d" % i, "chain": "corner:%d" % i,
			"a": base, "b": base + off})
	# Rim segments joined at a SMOOTH vertex (turn under CORNER_MIN_DEG)
	# share a chain id, so one click picks a whole tangent-continuous run —
	# a cylinder's rim, the arc of a rounded corner (QA §M35.4).
	var chain_of: Array = []
	chain_of.resize(n)
	var smooth: Array = []
	for i in n:
		var u := (poly[(i - 1 + n) % n] - poly[i]).normalized()
		var w := (poly[(i + 1) % n] - poly[i]).normalized()
		var theta := acos(clampf(u.dot(w), -1.0, 1.0))
		smooth.append(rad_to_deg(PI - theta) < CORNER_MIN_DEG)
	var start := -1
	for i in n:
		if not smooth[i]:   # vertex i joins edges i-1 and i
			start = i
			break
	if start < 0:
		for i in n:
			chain_of[i] = 0   # fully smooth loop: one chain
	else:
		var cid := -1
		for k in n:
			var i := (start + k) % n
			if not smooth[i]:
				cid += 1
			chain_of[i] = cid
	for i in n:
		var a: Vector3 = xf * Vector3(poly[i].x, poly[i].y, 0.0)
		var b: Vector3 = xf * Vector3(poly[(i + 1) % n].x,
			poly[(i + 1) % n].y, 0.0)
		out.append({"key": "top:%d" % i, "chain": "top#%d" % chain_of[i],
			"a": a + off, "b": b + off})
		out.append({"key": "bottom:%d" % i,
			"chain": "bottom#%d" % chain_of[i], "a": a, "b": b})
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


## {treat, size} for the multi-treatment maps below.
func _param() -> Dictionary:
	return {"treat": treat, "size": size_mm}


## corner index -> {treat, size} for this feature (empty corners = every
## corner; eligibility is filtered inside treat_corners_multi).
func _corner_map(n0: int) -> Dictionary:
	var out := {}
	if not lateral:
		return out
	for c in (corners if not corners.is_empty() else range(n0)):
		out[int(c)] = _param()
	return out


## rim segment index -> {treat, size} for one rim of this feature.
func _rim_map(flag: bool, segs: Array, n0: int) -> Dictionary:
	var out := {}
	if not flag:
		return out
	for s in (segs if not segs.is_empty() else range(n0)):
		out[int(s)] = _param()
	return out


## ALL live treatments on one body baked into a single mesh (QA §M35.3 —
## a fillet and a chamfer can stack on the same body, different edges).
## null = refuse, with the reason in `build_error`.
static func build_combined(doc: CadDocument, ef: ExtrudeFeature,
		ets: Array) -> ArrayMesh:
	build_error = ""
	if ets.is_empty():
		return null
	if ets.size() == 1:
		var one := ets[0] as EdgeTreatFeature
		var m := one.build_treated_mesh(doc, ef)
		if m == null and build_error == "":
			build_error = ("size too large for the body, or the profile "
				+ "has holes")
		return m
	var sf := doc.sketch_feature(ef.sketch_id)
	if sf == null:
		return null
	var healed := ProfileFinder.profile_at_healed(sf.sketch, ef.anchor)
	if healed.is_empty():
		return null
	var prof: Dictionary = healed["prof"]
	ef.anchor = healed["at"]
	if not (prof.get("holes", []) as Array).is_empty():
		build_error = "the profile has holes"
		return null
	var poly: PackedVector2Array = (prof["polygon"] as PackedVector2Array).duplicate()
	if ExtrudeFeature._signed_area(poly) < 0.0:
		poly.reverse()
	var n0 := poly.size()
	var cmap := {}
	var tmap := {}
	var bmap := {}
	for f in ets:
		var et := f as EdgeTreatFeature
		if et == null:
			continue
		for k in et._corner_map(n0):
			if not cmap.has(k):
				cmap[k] = et._param()
		for k in et._rim_map(et.top, et.top_segs, n0):
			if not tmap.has(k):
				tmap[k] = et._param()
		for k in et._rim_map(et.bottom, et.bottom_segs, n0):
			if not bmap.has(k):
				bmap[k] = et._param()
	var mesh := _build_multi_mesh(doc, ef, poly, cmap, tmap, bmap)
	if mesh == null and build_error == "":
		build_error = "size too large for the body"
	return mesh


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
		return EdgeTreatFeature._build_multi_mesh(doc, ef, poly,
			_corner_map(n0), _rim_map(top, top_segs, n0),
			_rim_map(bottom, bottom_segs, n0))
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


## Size of a nullable {treat, size} param (0.0 for untreated).
static func _p_size(p: Variant) -> float:
	return 0.0 if p == null else float((p as Dictionary)["size"])


static func _same_param(a: Dictionary, b: Dictionary) -> bool:
	return String(a["treat"]) == String(b["treat"]) \
		and absf(float(a["size"]) - float(b["size"])) < 1e-9


## General treated-mesh builder (QA §M35.1 round 2 + §M35.3): rim segments
## are individually selectable and every corner/segment carries its OWN
## {treat, size} (so stacked fillet + chamfer features combine). Built
## segment-wise in the sketch's local frame (z 0..h): full-height walls
## under untreated rim edges, shortened walls + inset band strips under
## treated ones, miter joints where two same-treatment edges meet, flat end
## fans where a treated run stops, and caps triangulated over the mixed
## boundary. Corner arcs/cuts from the lateral pass count as untreated rim
## (rolling a rim treatment around a rounded corner is B-rep-kernel tier).
## Two DIFFERENT treatments meeting at a shared rim corner are refused —
## their band surfaces have no common joint curve at this tier.
static func _build_multi_mesh(doc: CadDocument, ef: ExtrudeFeature,
		poly0: PackedVector2Array, cmap: Dictionary, tmap: Dictionary,
		bmap: Dictionary) -> ArrayMesh:
	var n0 := poly0.size()
	var sf := doc.sketch_feature(ef.sketch_id)
	var xf := sf.plane_transform()
	var h := absf(ef.distance)
	var zsign := 1.0 if ef.distance >= 0.0 else -1.0
	for prm_any: Variant in cmap.values() + tmap.values() + bmap.values():
		if float((prm_any as Dictionary)["size"]) <= 0.0:
			return null
	for j0 in n0:
		var ts := _p_size(tmap.get(j0))
		var bs := _p_size(bmap.get(j0))
		if ts + bs > h - 1e-6:
			build_error = "size too large for the body height"
			return null
	var poly := poly0
	var seg: Array = []
	var ctr: Array = []
	for i in n0:
		seg.append(i)
		ctr.append(null)
	if not cmap.is_empty():
		var mapped := treat_corners_multi(poly0, cmap)
		poly = mapped["poly"]
		seg = mapped["seg"]
		ctr = mapped["ctr"]
		if poly.is_empty():
			build_error = "corner size too large for its edges"
			return null
	var m := poly.size()
	# Per treated-poly edge: this edge's rim params (or null), by rim.
	var pt: Array = []
	var pb: Array = []
	for j in m:
		var s0 := int(seg[j])
		pt.append(tmap.get(s0) if s0 >= 0 else null)
		pb.append(bmap.get(s0) if s0 >= 0 else null)
	# VERTEX BLENDS (QA §M35 round 3, the "odd meeting point"): where a
	# treated lateral corner meets rim treatments on BOTH flanking edges
	# with the SAME {kind, size}, the corner's cut/arc edges inherit the
	# rim treatment — the generic band code then sweeps the standard blend
	# for free: a 45° diagonal band on a chamfer corner, and the true
	# sphere-octant "ball corner" on a fillet corner (the plan offset of
	# the corner arc IS the sphere's latitude circle). A one-sided or
	# mixed corner refuses — no joint surface exists at this tier (the old
	# code silently emitted a non-manifold mess there).
	if not cmap.is_empty():
		var jr := 0
		while jr < m:
			if int(seg[jr]) >= 0:
				jr += 1
				continue
			var j0 := jr   # run of corner-cut edges [j0, jr)
			while jr < m and int(seg[jr]) < 0:
				jr += 1
			var c := int(seg[jr % m])          # the corner's original index
			var prev := int(seg[(j0 - 1 + m) % m])
			for rims: Array in [[tmap, pt], [bmap, pb]]:
				var rmap: Dictionary = rims[0]
				var arr: Array = rims[1]
				var a_p: Variant = rmap.get(prev)
				var b_p: Variant = rmap.get(c)
				if a_p == null and b_p == null:
					continue   # rim stays sharp across this corner
				if a_p == null or b_p == null \
						or not _same_param(a_p as Dictionary,
							b_p as Dictionary) \
						or not _same_param(a_p as Dictionary,
							cmap[c] as Dictionary):
					build_error = ("a treated corner blends only when the "
						+ "corner and BOTH its edges carry the same "
						+ "treatment and size — pick them together, or "
						+ "leave the corner edges untreated")
					return null
				for jj in range(j0, jr):
					arr[jj] = a_p
	# Mixed treatments meeting at a shared corner: no joint curve exists at
	# this tier (a chamfer cone and a fillet torus don't meet in a line).
	for j in m:
		for arr: Array in [pt, pb]:
			var a_p: Variant = arr[j]
			var b_p: Variant = arr[(j + 1) % m]
			if a_p != null and b_p != null and not _same_param(
					a_p as Dictionary, b_p as Dictionary):
				build_error = ("a fillet and a chamfer (or two sizes) meet "
					+ "at the same corner — use one treatment for edges "
					+ "that share a corner")
				return null
	var sched_cache := {}
	var sched_of := func(p: Dictionary) -> Array:
		var key := "%s|%.6f" % [String(p["treat"]), float(p["size"])]
		if not sched_cache.has(key):
			sched_cache[key] = cap_schedule(String(p["treat"]),
				float(p["size"]))
		return sched_cache[key]

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
		var vidx := j if lead else (j + 1) % m
		var v := poly[vidx]
		# Fillet corner-ARC vertices offset RADIALLY toward the arc center:
		# the offset of the arc at inset i is the exact latitude circle of
		# the vertex-blend sphere (radius s - i). The generic chord-normal
		# parallel branch below is only approximate there and opens cracks
		# between the fan's bands (and piles a zigzag blob at the cap pole).
		if ctr[vidx] != null and absf(i_self - i_other) < 1e-9:
			var co: Vector2 = ctr[vidx]
			var rad := v - co
			var rl := rad.length()
			# rl comes back through float32 storage: at the cap the inset
			# equals the radius only to ~1e-6, so clamp instead of reject
			# (the pole collapse there is exactly the intended blend).
			if rl > 1e-9 and i_self <= rl + rl * 1e-4 + 1e-6:
				var f := maxf(rl - i_self, 0.0) / rl
				if f < 1e-5:
					f = 0.0   # snap the cap pole exactly — no slivers
				return {"p": co + rad * f, "ok": true}
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
	# Zero-area triangles appear where blend stations collapse (a fillet
	# ball corner's cap pole) — skip them at emit time.
	var add_tri := func(a3: Vector3, b3: Vector3, c3: Vector3) -> void:
		if ((b3 - a3).cross(c3 - a3)).length_squared() > 1e-16:
			tris.append_array([a3, b3, c3])

	# Band strips + (fallback) end fans, per treated edge, per rim. Each
	# edge uses its OWN schedule; a mitered neighbor shares it (equal
	# params enforced above), so the stations line up along the joint.
	for j in m:
		for is_top in [true, false]:
			var arr_e: Array = pt if is_top else pb
			if arr_e[j] == null:
				continue
			var prm: Dictionary = arr_e[j]
			var sz := float(prm["size"])
			var sched: Array = sched_of.call(prm)
			var ks: int = sched.size()
			var zof := func(dz: float) -> float:
				return h - dz if is_top else dz
			var lead_on: bool = arr_e[(j - 1 + m) % m] != null
			var trail_on: bool = arr_e[(j + 1) % m] != null
			# Fit: the cap-level ring must keep some edge length.
			# Corner-cut edges (seg < 0) skip the fit check: a fillet ball
			# corner legitimately collapses to the cap pole.
			var pk: Dictionary = corner_off.call(j, true, sz,
				sz if lead_on else 0.0)
			var qk: Dictionary = corner_off.call(j, false, sz,
				sz if trail_on else 0.0)
			if int(seg[j]) >= 0 and (pk["p"] as Vector2).distance_to(
					qk["p"] as Vector2) < 1e-6:
				build_error = "size too large for an edge"
				return null
			for k in ks - 1:
				var ia := float(sched[k]["inset"])
				var ib := float(sched[k + 1]["inset"])
				var za: float = zof.call(float(sched[k]["dz"]))
				var zb: float = zof.call(float(sched[k + 1]["dz"]))
				var pa: Vector2 = corner_off.call(j, true, ia,
					ia if lead_on else 0.0)["p"]
				var qa: Vector2 = corner_off.call(j, false, ia,
					ia if trail_on else 0.0)["p"]
				var pb2: Vector2 = corner_off.call(j, true, ib,
					ib if lead_on else 0.0)["p"]
				var qb: Vector2 = corner_off.call(j, false, ib,
					ib if trail_on else 0.0)["p"]
				if is_top:
					add_tri.call(Vector3(pa.x, pa.y, za),
						Vector3(qa.x, qa.y, za), Vector3(qb.x, qb.y, zb))
					add_tri.call(Vector3(pa.x, pa.y, za),
						Vector3(qb.x, qb.y, zb), Vector3(pb2.x, pb2.y, zb))
				else:
					add_tri.call(Vector3(pb2.x, pb2.y, zb),
						Vector3(qb.x, qb.y, zb), Vector3(qa.x, qa.y, za))
					add_tri.call(Vector3(pb2.x, pb2.y, zb),
						Vector3(qa.x, qa.y, za), Vector3(pa.x, pa.y, za))
			# Sealing fans only for near-parallel fallback ends.
			for lead in [true, false]:
				var other := (j - 1 + m) % m if lead else (j + 1) % m
				if arr_e[other] != null:
					continue
				var probe: Dictionary = corner_off.call(j, lead, sz, 0.0)
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
		var zlo: float = _p_size(pb[j])
		var zhi: float = h - _p_size(pt[j])
		if zhi - zlo < 1e-6:
			build_error = "size too large for the body height"
			return null
		# Does the corner at `lead` get clipped by the neighbor's band on
		# rim `is_top`? Only when edge j itself is untreated there, the
		# neighbor IS treated, and the corner solve is non-degenerate.
		# The curve follows the NEIGHBOR's schedule (its treat + size).
		var clip_curve := func(lead: bool, is_top: bool) -> PackedVector2Array:
			var arr_e: Array = pt if is_top else pb
			var other := (j - 1 + m) % m if lead else (j + 1) % m
			if arr_e[j] != null or arr_e[other] == null:
				return PackedVector2Array()
			var op: Dictionary = arr_e[other]
			var probe: Dictionary = corner_off.call(j, lead, 0.0,
				float(op["size"]))
			if not probe["ok"]:
				return PackedVector2Array()
			var so: Array = sched_of.call(op)
			# (u, z) points from the rim shoulder toward the cap.
			var out2 := PackedVector2Array()
			for k in so.size():
				var q: Vector2 = corner_off.call(j, lead, 0.0,
					float(so[k]["inset"]))["p"]
				var zq: float = (h - float(so[k]["dz"])) if is_top \
					else float(so[k]["dz"])
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
			for k in bl.size():   # (0, s) down the curve to (u_K, 0)
				wall.append(bl[k])
		if br.is_empty():
			wall.append(Vector2(length, zlo))
		else:
			for k in range(br.size() - 1, -1, -1):
				wall.append(br[k])
		if tr.is_empty():
			wall.append(Vector2(length, zhi))
		else:
			for k in tr.size():   # (len, h-s) up the curve to the cap corner
				wall.append(tr[k])
		if tl.is_empty():
			wall.append(Vector2(0.0, zhi))
		else:
			for k in range(tl.size() - 1, -1, -1):
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
			build_error = "a wall degenerated (edge too short for the size)"
			return null
		var widx := Geometry2D.triangulate_polygon(wpoly)
		if widx.is_empty():
			build_error = "a wall failed to triangulate"
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
		var arr_c: Array = pt if is_top else pb
		var boundary := PackedVector2Array()
		var push := func(p: Vector2) -> void:
			if boundary.is_empty() \
					or boundary[boundary.size() - 1].distance_to(p) > 1e-6:
				boundary.append(p)
		for j in m:
			var i_self := _p_size(arr_c[j])
			var i_lead := _p_size(arr_c[(j - 1 + m) % m])
			var i_trail := _p_size(arr_c[(j + 1) % m])
			push.call(corner_off.call(j, true, i_self, i_lead)["p"])
			push.call(corner_off.call(j, false, i_self, i_trail)["p"])
		if boundary.size() > 1 and boundary[0].distance_to(
				boundary[boundary.size() - 1]) <= 1e-6:
			boundary.remove_at(boundary.size() - 1)
		if boundary.size() < 3 \
				or ExtrudeFeature._signed_area(boundary) <= 0.0:
			build_error = "size too large — the inset cap crosses itself"
			return null   # inset crossed itself — size too big for the edge
		var idx := Geometry2D.triangulate_polygon(boundary)
		if idx.is_empty():
			build_error = "the cap failed to triangulate"
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
