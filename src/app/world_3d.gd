class_name CadWorld
extends Node3D
## Builds the model-mode 3D scene: origin axes, the three origin planes
## (pickable by math raycast, no physics), and line meshes for every live
## sketch. World units are mm.

const PLANE_HALF := 120.0        # mm half-extent of the origin plane quads
const COLOR_PLANE := Color(0.55, 0.65, 0.85, 0.10)
const COLOR_PLANE_HOVER := Color(0.55, 0.75, 1.0, 0.28)
const COLOR_SKETCH := Color(0.30, 0.62, 0.96)
const COLOR_CONSTRUCTION := Color(0.72, 0.55, 0.95)
const AXIS_LEN := 150.0

var _plane_meshes := {}          # plane name -> MeshInstance3D
var _sketch_root: Node3D = null


func _ready() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation = Vector3(-0.9, 0.6, 0)
	add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	_build_axes()
	_build_planes()
	_sketch_root = Node3D.new()
	_sketch_root.name = "Sketches"
	add_child(_sketch_root)


func _build_axes() -> void:
	var im := ImmediateMesh.new()
	for axis: Array in [
			[Vector3(AXIS_LEN, 0, 0), Color(0.85, 0.30, 0.30)],
			[Vector3(0, AXIS_LEN, 0), Color(0.35, 0.80, 0.35)],
			[Vector3(0, 0, AXIS_LEN), Color(0.35, 0.55, 0.95)]]:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_set_color(axis[1])
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(axis[0])
		im.surface_end()
	var mi := MeshInstance3D.new()
	mi.name = "Axes"
	mi.mesh = im
	mi.material_override = _line_material(Color.WHITE)
	add_child(mi)


func _build_planes() -> void:
	for plane_name in SketchFeature.PLANES:
		var basis := SketchFeature.plane_basis(plane_name)
		var quad := QuadMesh.new()
		quad.size = Vector2(PLANE_HALF * 2.0, PLANE_HALF * 2.0)
		var mi := MeshInstance3D.new()
		mi.name = "Plane" + plane_name
		mi.mesh = quad
		# QuadMesh faces +Z; orient its +Z along the plane normal.
		mi.basis = basis
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = COLOR_PLANE
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		add_child(mi)
		_plane_meshes[plane_name] = mi


func set_planes_visible(v: bool) -> void:
	for k: String in _plane_meshes:
		(_plane_meshes[k] as MeshInstance3D).visible = v


func set_plane_hover(plane_name: String) -> void:
	for k: String in _plane_meshes:
		var mat := (_plane_meshes[k] as MeshInstance3D).material_override \
			as StandardMaterial3D
		mat.albedo_color = COLOR_PLANE_HOVER if k == plane_name else COLOR_PLANE


## Math raycast (no physics): which origin plane does the ray hit inside its
## quad? Returns "" or the nearest plane name.
func pick_plane(origin: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_t := INF
	for plane_name: String in _plane_meshes:
		var basis := SketchFeature.plane_basis(plane_name)
		var n := basis.z
		var denom := dir.dot(n)
		if absf(denom) < 1e-6:
			continue
		var t := -origin.dot(n) / denom
		if t <= 0.0 or t >= best_t:
			continue
		var hit := origin + dir * t
		if absf(hit.dot(basis.x)) <= PLANE_HALF and absf(hit.dot(basis.y)) <= PLANE_HALF:
			best = plane_name
			best_t = t
	return best


## Rebuild the 3D display for every live feature: sketch line meshes plus
## extruded solids. Arcs/circles are polyline-tessellated — display only.
func rebuild_sketches(doc: CadDocument) -> void:
	for c in _sketch_root.get_children():
		c.queue_free()
	for f in doc.live_features():
		if f is ExtrudeFeature:
			var mesh := (f as ExtrudeFeature).build_mesh(doc)
			if mesh != null:
				var smi := MeshInstance3D.new()
				smi.name = f.name
				smi.mesh = mesh
				var mat := StandardMaterial3D.new()
				mat.albedo_color = Color(0.62, 0.66, 0.72)
				mat.metallic = 0.1
				mat.roughness = 0.7
				smi.material_override = mat
				_sketch_root.add_child(smi)
			continue
		if not (f is SketchFeature):
			continue
		var sf := f as SketchFeature
		var im := ImmediateMesh.new()
		var has_any := false
		for e in sf.sketch.entities():
			var pts := _entity_polyline(sf.sketch, e)
			if pts.size() < 2:
				continue
			has_any = true
			im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
			for p in pts:
				im.surface_add_vertex(sf.to_world(p))
			im.surface_end()
		if not has_any:
			continue
		var mi := MeshInstance3D.new()
		mi.name = sf.name
		mi.mesh = im
		mi.material_override = _line_material(COLOR_SKETCH)
		_sketch_root.add_child(mi)


func _entity_polyline(sk: Sketch, e: SketchEntity) -> PackedVector2Array:
	var out := PackedVector2Array()
	match e.kind():
		"line":
			var l := e as SketchLine
			var a := sk.point(l.p0)
			var b := sk.point(l.p1)
			if a != null and b != null:
				out.append(a.pos)
				out.append(b.pos)
		"circle":
			var ci := e as SketchCircle
			var c := sk.point(ci.center)
			if c != null:
				for i in 65:
					var ang := TAU * i / 64.0
					out.append(c.pos + Vector2(cos(ang), sin(ang)) * ci.radius)
		"arc":
			var arc := e as SketchArc
			var c := sk.point(arc.center)
			var s := sk.point(arc.start)
			var t := sk.point(arc.end)
			if c != null and s != null and t != null:
				var r := c.pos.distance_to(s.pos)
				var a0 := (s.pos - c.pos).angle()
				var sweep := (t.pos - c.pos).angle() - a0
				if arc.ccw and sweep < 0.0:
					sweep += TAU
				elif not arc.ccw and sweep > 0.0:
					sweep -= TAU
				var n := maxi(8, int(ceil(absf(sweep) / (TAU / 64.0))))
				for i in n + 1:
					var ang := a0 + sweep * i / float(n)
					out.append(c.pos + Vector2(cos(ang), sin(ang)) * r)
	return out


func _line_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = color
	return mat
