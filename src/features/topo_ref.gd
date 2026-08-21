class_name TopoRef
extends RefCounted
## M39 — a persistent reference to a FACE of a body.
##
## `body` is the body's root feature id, `face` the kernel face id of the
## face (SolidKernel: feature ordinal << FACE_SHIFT | local face), which
## survives every boolean the body goes through. Because a sketch edit can
## renumber a feature's local faces, the ref also carries a geometric HINT
## — the face plane (normal + offset, world) as last resolved — and heals
## itself by picking the body face whose plane matches the hint when the
## id no longer exists. `face == -1` means "unbound": resolve purely by
## hint (how pre-M39 snapshot planes adopt a face on load).

var body := ""
var face := -1
var hint_normal := Vector3(0, 0, 1)
var hint_offset := 0.0    # plane offset along hint_normal (mm)

## Plane match tolerances for healing.
const HEAL_ANGLE_DOT := 0.9995   # ~1.8°
const HEAL_OFFSET_MM := 0.05


static func make(p_body: String, p_face: int, normal: Vector3, point: Vector3) -> TopoRef:
	var r := TopoRef.new()
	r.body = p_body
	r.face = p_face
	r.hint_normal = normal.normalized()
	r.hint_offset = point.dot(r.hint_normal)
	return r


func to_dict() -> Dictionary:
	return {"body": body, "face": face,
		"n": [hint_normal.x, hint_normal.y, hint_normal.z], "d": hint_offset}


static func from_dict(d: Dictionary) -> TopoRef:
	var r := TopoRef.new()
	r.body = String(d.get("body", ""))
	r.face = int(d.get("face", -1))
	var n: Array = d.get("n", [0, 0, 1])
	if n.size() == 3:
		r.hint_normal = Vector3(float(n[0]), float(n[1]), float(n[2]))
	r.hint_offset = float(d.get("d", 0.0))
	return r


## Resolve against a body entry from BodyBuilder ({mesh, face_ids, ...}).
## -> {point: Vector3 (face centroid), normal: Vector3, face: int} or {}.
## Updates `face` + hint on a successful heal.
func resolve_on(entry: Dictionary) -> Dictionary:
	var faces := face_planes(entry)
	if faces.is_empty():
		return {}
	if face >= 0 and faces.has(face):
		var fp: Dictionary = faces[face]
		# Guard against the id surviving on a face that moved elsewhere
		# entirely (renumbering): the plane must still roughly agree with
		# the hint, else heal by hint.
		if (fp["normal"] as Vector3).dot(hint_normal) > 0.5:
			_adopt(fp)
			return fp
	# Heal: the face whose plane is nearest the hint.
	var best := {}
	var best_score := INF
	for fid in faces:
		var fp: Dictionary = faces[fid]
		var n: Vector3 = fp["normal"]
		if n.dot(hint_normal) < HEAL_ANGLE_DOT:
			continue
		var d_off := absf((fp["point"] as Vector3).dot(hint_normal) - hint_offset)
		if d_off > HEAL_OFFSET_MM:
			continue
		var score := d_off + (1.0 - n.dot(hint_normal)) * 100.0
		if score < best_score:
			best_score = score
			best = fp
	if best.is_empty():
		return {}
	face = int(best["face"])
	_adopt(best)
	return best


func _adopt(fp: Dictionary) -> void:
	hint_normal = (fp["normal"] as Vector3).normalized()
	hint_offset = (fp["point"] as Vector3).dot(hint_normal)


## Every PLANAR face of a body entry: face id -> {face, normal, point
## (area-weighted centroid), area}. Curved faces (a cylinder wall is one
## face id whose triangle normals disagree) are skipped — they have no
## plane to sketch on.
static func face_planes(entry: Dictionary) -> Dictionary:
	var out := {}
	var mesh: ArrayMesh = entry.get("mesh")
	var fids: PackedInt32Array = entry.get("face_ids", PackedInt32Array())
	if mesh == null or mesh.get_surface_count() == 0 or fids.is_empty():
		return out
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var nt := mini(verts.size() / 3, fids.size())
	var acc := {}   # face -> {n_sum, c_sum, area, first_n, planar}
	for t in nt:
		var a := verts[t * 3]
		var b := verts[t * 3 + 1]
		var c := verts[t * 3 + 2]
		var nv := (b - a).cross(c - a)
		var area := nv.length() * 0.5
		if area < 1e-9:
			continue
		var n := nv / (area * 2.0)
		var fid := fids[t]
		if not acc.has(fid):
			acc[fid] = {"n_sum": Vector3.ZERO, "c_sum": Vector3.ZERO,
				"area": 0.0, "first_n": n, "planar": true}
		var rec: Dictionary = acc[fid]
		if n.dot(rec["first_n"] as Vector3) < 0.999:
			rec["planar"] = false
		rec["n_sum"] = (rec["n_sum"] as Vector3) + n * area
		rec["c_sum"] = (rec["c_sum"] as Vector3) + (a + b + c) / 3.0 * area
		rec["area"] = float(rec["area"]) + area
	for fid in acc:
		var rec: Dictionary = acc[fid]
		if not bool(rec["planar"]) or float(rec["area"]) <= 0.0:
			continue
		out[fid] = {"face": fid,
			"normal": (rec["n_sum"] as Vector3).normalized(),
			"point": (rec["c_sum"] as Vector3) / float(rec["area"]),
			"area": float(rec["area"])}
	return out


## Boundary loops of one face (world vertices, in order): the face's
## triangle edges that are not shared with another triangle of the same
## face, chained. -> Array[PackedVector3Array]
static func face_loops(entry: Dictionary, face_id: int) -> Array:
	var out: Array = []
	var mesh: ArrayMesh = entry.get("mesh")
	var fids: PackedInt32Array = entry.get("face_ids", PackedInt32Array())
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vid := {}
	var pos: Array = []
	var count := {}       # directed edge key -> count (undirected)
	var nxt := {}         # directed edge a->b stored for boundary walk
	var nt := mini(verts.size() / 3, fids.size())
	var key := func(v: Vector3) -> Vector3i:
		return Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0))
	for t in nt:
		if fids[t] != face_id:
			continue
		var ids := [0, 0, 0]
		for e in 3:
			var k: Vector3i = key.call(verts[t * 3 + e])
			if not vid.has(k):
				vid[k] = pos.size()
				pos.append(verts[t * 3 + e])
			ids[e] = vid[k]
		for e in 3:
			var a: int = ids[e]
			var b: int = ids[(e + 1) % 3]
			var uk := Vector2i(mini(a, b), maxi(a, b))
			count[uk] = int(count.get(uk, 0)) + 1
			nxt[Vector2i(a, b)] = true
	# Boundary directed edges: undirected count == 1.
	var succ := {}
	for dk in nxt:
		var d := dk as Vector2i
		if int(count.get(Vector2i(mini(d.x, d.y), maxi(d.x, d.y)), 0)) == 1:
			succ[d.x] = d.y
	var used := {}
	for start in succ:
		if used.has(start):
			continue
		var loop := PackedVector3Array()
		var cur: int = start
		var guard := 0
		while not used.has(cur) and succ.has(cur) and guard < 100000:
			used[cur] = true
			loop.append(pos[cur])
			cur = succ[cur]
			guard += 1
		if loop.size() >= 3:
			out.append(loop)
	return out


## Centres of the circular loops among a face's boundaries (holes, bosses,
## round outlines): loops of 12+ vertices all within 2 % of one radius.
## -> Array of {center: Vector3, radius: float}
static func face_circles(entry: Dictionary, face_id: int) -> Array:
	var out: Array = []
	for loop: PackedVector3Array in face_loops(entry, face_id):
		if loop.size() < 12:
			continue
		var c := Vector3.ZERO
		for p in loop:
			c += p
		c /= loop.size()
		var r := 0.0
		for p in loop:
			r += p.distance_to(c)
		r /= loop.size()
		if r < 1e-6:
			continue
		var ok := true
		for p in loop:
			if absf(p.distance_to(c) - r) > r * 0.02:
				ok = false
				break
		if ok:
			out.append({"center": c, "radius": r})
	return out
