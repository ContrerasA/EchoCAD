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
