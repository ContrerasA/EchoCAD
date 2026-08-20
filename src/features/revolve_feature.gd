class_name RevolveFeature
extends SolidFeature
## Revolve a sketch region around an axis (M23). Like extrude, the region is
## remembered by an ANCHOR POINT inside it (sketch uv, mm) and re-found on
## replay. The axis lives in the same sketch: one of its LINE entities
## (typically a construction line) or the sketch's own X/Y axis through the
## origin. Angle in degrees, (0, 360]; the boolean `operation` comes from
## SolidFeature.
##
## The profile must lie entirely on ONE side of the axis (points exactly on
## it weld) — a straddling region has no valid solid of revolution and
## build_mesh returns null.

const AXIS_X := "x"        # the sketch's +u axis through (0,0)
const AXIS_Y := "y"        # the sketch's +v axis through (0,0)
## Any other value is a LINE entity id in the same sketch.

## Tessellation of a full turn (a 32-gon matches the circle tessellation
## ProfileFinder uses, so revolved and drawn circles agree visually).
const FULL_TURN_SEGS := 48
## Points closer than this to the axis count as ON it (welds); profiles
## reaching farther than this PAST it straddle and are refused.
const AXIS_EPS := 1e-3

var sketch_id := ""
var anchor := Vector2.ZERO
var axis := AXIS_X
var angle_deg := 360.0


static func make(p_sketch_id: String, p_anchor: Vector2, p_axis: String,
		p_angle := 360.0, p_operation := OP_NEW_BODY) -> RevolveFeature:
	var f := RevolveFeature.new()
	f.sketch_id = p_sketch_id
	f.anchor = p_anchor
	f.axis = p_axis
	f.angle_deg = p_angle
	f.operation = p_operation
	return f


func kind() -> String:
	return "revolve"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["sketch_id"] = sketch_id
	d["anchor"] = [anchor.x, anchor.y]
	d["axis"] = axis
	d["angle_deg"] = angle_deg
	d["operation"] = operation
	return d


static func from_dict(d: Dictionary) -> RevolveFeature:
	var f := RevolveFeature.new()
	f._read_base(d)
	f.sketch_id = String(d.get("sketch_id", ""))
	var a: Array = d.get("anchor", [0.0, 0.0])
	f.anchor = Vector2(float(a[0]), float(a[1]))
	f.axis = String(d.get("axis", AXIS_X))
	f.angle_deg = float(d.get("angle_deg", 360.0))
	f.operation = String(d.get("operation", OP_NEW_BODY))
	return f


## The axis in sketch uv: {"a": Vector2 (point), "d": Vector2 (unit dir)},
## or {} when a line axis no longer resolves.
func axis_in_sketch(sk: Sketch) -> Dictionary:
	match axis:
		AXIS_X:
			return {"a": Vector2.ZERO, "d": Vector2(1, 0)}
		AXIS_Y:
			return {"a": Vector2.ZERO, "d": Vector2(0, 1)}
	var e := sk.entity(axis)
	if e == null or e.kind() != "line":
		return {}
	var l := e as SketchLine
	var p0 := sk.point(l.p0)
	var p1 := sk.point(l.p1)
	if p0 == null or p1 == null or p0.pos.distance_to(p1.pos) < 1e-9:
		return {}
	return {"a": p0.pos, "d": (p1.pos - p0.pos).normalized()}


## Everything the mesher/CSG need, resolved against the CURRENT sketch:
## region, plane transform, axis frame, side-normalized. {} when invalid.
## Frame convention (see build_mesh): axis dir Zl, radial-at-zero Xl,
## rotation sweeps Xl toward Yl = Zl x Xl. In uv terms r = (p-a).perp,
## t = (p-a).d with perp = rot90ccw(d); when the region lies on the perp<0
## side the AXIS DIRECTION flips (not perp), which keeps (t, r) right-handed
## so ccw uv rings stay ccw and the hard-coded windings hold.
func _resolve(doc: CadDocument) -> Dictionary:
	var sf := doc.sketch_feature(sketch_id)
	if sf == null:
		return {}
	var healed := ProfileFinder.profile_at_healed(sf.sketch, anchor)
	if healed.is_empty():
		return {}
	var prof: Dictionary = healed["prof"]
	anchor = healed["at"]
	var ax := axis_in_sketch(sf.sketch)
	if ax.is_empty():
		return {}
	var a: Vector2 = ax["a"]
	var d: Vector2 = ax["d"]
	var perp := Vector2(-d.y, d.x)
	var outer := (prof["polygon"] as PackedVector2Array).duplicate()
	if _ring_area_of(outer) < 0.0:
		outer.reverse()
	var holes_cw: Array = []
	for h in (prof.get("holes", []) as Array):
		var hp := (h as PackedVector2Array).duplicate()
		if _ring_area_of(hp) > 0.0:
			hp.reverse()
		holes_cw.append(hp)
	# Which side does the region live on?
	var rmin := INF
	var rmax := -INF
	var rings_all: Array = [outer]
	rings_all.append_array(holes_cw)
	for ring: PackedVector2Array in rings_all:
		for p in ring:
			var r := (p - a).dot(perp)
			rmin = minf(rmin, r)
			rmax = maxf(rmax, r)
	if rmin < -AXIS_EPS and rmax > AXIS_EPS:
		return {}   # straddles the axis
	if rmax <= AXIS_EPS:
		# Region on the negative side: flip the axis direction (keeps the
		# (t, r) frame right-handed — see the class comment).
		d = -d
		perp = Vector2(-d.y, d.x)
	var xf := sf.plane_transform()
	var o_w: Vector3 = xf * Vector3(a.x, a.y, 0.0)
	var z_l: Vector3 = (xf.basis * Vector3(d.x, d.y, 0.0)).normalized()
	var x_l: Vector3 = (xf.basis * Vector3(perp.x, perp.y, 0.0)).normalized()
	var y_l := z_l.cross(x_l)
	var ang := clampf(angle_deg, 1e-3, 360.0)
	return {"outer": outer, "holes": holes_cw, "prof": prof, "xf": xf,
		"a": a, "d": d, "perp": perp, "o": o_w, "zl": z_l, "xl": x_l,
		"yl": y_l, "angle": deg_to_rad(ang),
		"full": absf(ang - 360.0) < 1e-6}


func _pos(res: Dictionary, p: Vector2, theta: float) -> Vector3:
	var a: Vector2 = res["a"]
	var t := (p - a).dot(res["d"] as Vector2)
	var r := (p - a).dot(res["perp"] as Vector2)
	var xtheta: Vector3 = (res["xl"] as Vector3) * cos(theta) \
		+ (res["yl"] as Vector3) * sin(theta)
	return (res["o"] as Vector3) + (res["zl"] as Vector3) * t + xtheta * r


func build_mesh(doc: CadDocument) -> ArrayMesh:
	var res := _resolve(doc)
	if res.is_empty():
		return null
	var full: bool = res["full"]
	var angle: float = res["angle"]
	var segs := maxi(8, int(ceil(FULL_TURN_SEGS * angle / TAU)))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()

	var emit := func(v0: Vector3, v1: Vector3, v2: Vector3) -> void:
		var n := (v1 - v0).cross(v2 - v0)
		if n.length_squared() < 1e-12:
			return   # welded/degenerate sliver (points on the axis)
		n = n.normalized()
		verts.append_array([v0, v1, v2])
		normals.append_array([n, n, n])

	# Walls: one revolved band per ring edge. Winding derived once for the
	# normalized frame (outer ccw, r >= 0, rotation Xl->Yl): (a0, b1, b0) /
	# (a0, a1, b1) faces OUTWARD; cw holes come out cavity-outward the same
	# way extrude's shared wall code does.
	var rings: Array = [res["outer"]]
	rings.append_array(res["holes"] as Array)
	for ring: PackedVector2Array in rings:
		for i in ring.size():
			var p := ring[i]
			var q := ring[(i + 1) % ring.size()]
			for j in segs:
				var th0: float = angle * j / segs
				var th1: float = angle * (j + 1) / segs
				if full and j == segs - 1:
					th1 = 0.0   # exact wrap: last band reuses ring 0 verts
				var a0 := _pos(res, p, th0)
				var b0 := _pos(res, q, th0)
				var a1 := _pos(res, p, th1)
				var b1 := _pos(res, q, th1)
				emit.call(a0, b1, b0)
				emit.call(a0, a1, b1)

	# Caps close a partial sweep. ccw uv triangles mapped at angle theta face
	# +Ytheta (the sweep direction), so the START cap reverses (outside is
	# behind it) and the END cap keeps the returned order.
	if not full:
		var tri := ProfileFinder.triangulate_with_holes(
			res["outer"] as PackedVector2Array, res["prof"].get("holes", []))
		var pts: PackedVector2Array = tri["points"]
		var idx: PackedInt32Array = tri["indices"]
		for t in range(0, idx.size(), 3):
			emit.call(_pos(res, pts[idx[t]], 0.0),
				_pos(res, pts[idx[t + 2]], 0.0),
				_pos(res, pts[idx[t + 1]], 0.0))
			emit.call(_pos(res, pts[idx[t]], angle),
				_pos(res, pts[idx[t + 1]], angle),
				_pos(res, pts[idx[t + 2]], angle))

	if verts.is_empty():
		return null
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Edge overlay: the circles swept by SHARP profile corners (the lathe
	# analog of extrude's cap outlines), plus the profile outline itself on
	# both faces of a partial sweep.
	var edges := PackedVector3Array()
	for ring: PackedVector2Array in rings:
		var m := ring.size()
		for i in m:
			var p := ring[i]
			var prev := ring[(i - 1 + m) % m]
			var nxt := ring[(i + 1) % m]
			var din := (p - prev).normalized()
			var dout := (nxt - p).normalized()
			if din.dot(dout) < cos(deg_to_rad(15.0)):
				for j in segs:
					var th0: float = angle * j / segs
					var th1: float = angle * (j + 1) / segs
					edges.append(_pos(res, p, th0))
					edges.append(_pos(res, p, th1))
			if not full:
				edges.append(_pos(res, p, 0.0))
				edges.append(_pos(res, nxt, 0.0))
				edges.append(_pos(res, p, angle))
				edges.append(_pos(res, nxt, angle))
	if not edges.is_empty():
		var earr := []
		earr.resize(Mesh.ARRAY_MAX)
		earr[Mesh.ARRAY_VERTEX] = edges
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)
	return mesh


func solid_part(doc: CadDocument) -> Dictionary:
	var res := _resolve(doc)
	if res.is_empty():
		return {}
	# World AABB from the swept ring points at a spread of angles.
	var aabb := AABB()
	var first := true
	var rings: Array = [res["outer"]]
	rings.append_array(res["holes"] as Array)
	var angle: float = res["angle"]
	for ring: PackedVector2Array in rings:
		for p in ring:
			for j in 17:
				var w := _pos(res, p, angle * j / 16.0)
				if first:
					aabb = AABB(w, Vector3.ZERO)
					first = false
				else:
					aabb = aabb.expand(w)
	return {"feature": self, "res": res, "aabb": aabb.grow(0.001)}


## The revolved solid as CSG: CSGPolygon3D MODE_SPIN spins its local-XY
## polygon around local +Y (X = radius, must be >= 0), sweeping +X toward
## -Z for positive degrees — which is exactly this feature's Xl->Yl
## direction under the node basis (Xl, Zl, Xl x Zl = -Yl).
func csg_node(part: Dictionary) -> CSGShape3D:
	var res: Dictionary = part["res"]
	var cut := operation == OP_CUT
	var deg: float = rad_to_deg(res["angle"])
	var segs := maxi(8, int(ceil(FULL_TURN_SEGS * float(res["angle"]) / TAU)))

	var spin := func(ring: PackedVector2Array, grow: float) -> CSGPolygon3D:
		var shaped := ring
		if absf(grow) > 0.0:
			var g := offset_ring(ring, grow)
			if g.size() >= 3:
				shaped = g
		var poly := PackedVector2Array()
		var a: Vector2 = res["a"]
		for p in shaped:
			var r := maxf(0.0, (p - a).dot(res["perp"] as Vector2))
			var t := (p - a).dot(res["d"] as Vector2)
			poly.append(Vector2(r, t))
		var node := CSGPolygon3D.new()
		node.mode = CSGPolygon3D.MODE_SPIN
		node.polygon = poly
		node.spin_degrees = clampf(deg, 0.01, 360.0)
		node.spin_sides = segs
		var x_l: Vector3 = res["xl"]
		var z_l: Vector3 = res["zl"]
		node.transform = Transform3D(Basis(x_l, z_l, x_l.cross(z_l)),
			res["o"] as Vector3)
		return node

	# Cut solids grow a hair sideways (radially) so coplanar cut walls do
	# not leave classifier skins — the lateral analog of the prism trick.
	# (Cap-coplanarity along the axis is rare for revolves; the radial grow
	# also nudges the caps since the profile ring grows in both u and v.)
	var outer_node: CSGPolygon3D = spin.call(
		res["outer"] as PackedVector2Array, EPS_MM if cut else 0.0)
	var holes: Array = res["holes"]
	if holes.is_empty():
		return outer_node
	var c := CSGCombiner3D.new()
	c.add_child(outer_node)
	for h in holes:
		# Hole rings arrive cw; offset_ring's grow/shrink convention is for
		# ccw input, so flip, shrink, and let spin() read the result.
		var hcc := (h as PackedVector2Array).duplicate()
		hcc.reverse()
		var hn: CSGPolygon3D = spin.call(hcc, -EPS_MM if cut else 0.0)
		hn.operation = CSGShape3D.OPERATION_SUBTRACTION
		c.add_child(hn)
	return c


static func _ring_area_of(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return a * 0.5
