class_name CadWorld
extends Node3D
## Builds the model-mode 3D scene: origin axes, the three origin planes
## (pickable by math raycast, no physics), and line meshes for every live
## sketch. World units are mm.

## Side length (mm) of each origin plane quad. Fusion-style, the quad occupies
## the +u/+v quadrant with its corner on the origin, so this is a full side
## rather than a half-extent — hit tests run 0..PLANE_SIDE, not ±.
const PLANE_SIDE := 120.0
const COLOR_PLANE := Color(0.55, 0.65, 0.85, 0.10)
const COLOR_PLANE_HOVER := Color(0.55, 0.75, 1.0, 0.28)
## Construction planes read tan/amber (Fusion-ish) so they never get
## mistaken for origin planes.
const COLOR_CPLANE := Color(0.88, 0.76, 0.38, 0.12)
const COLOR_CPLANE_HOVER := Color(0.95, 0.85, 0.45, 0.30)
## Flat body face hovered while picking a sketch plane (M22).
const COLOR_FACE_HOVER := Color(0.95, 0.85, 0.45, 0.35)
const COLOR_SKETCH := Color(0.30, 0.62, 0.96)
const COLOR_CONSTRUCTION := Color(0.72, 0.55, 0.95)
## Closed sketch regions render as translucent faces (Fusion-style) so an
## extrudable profile reads as a surface, not bare wireframe (QA §M18.1).
const COLOR_REGION_FILL := Color(0.30, 0.62, 0.96, 0.12)
## Profile-pick hover: the region under the cursor while Extrude waits.
const COLOR_REGION_HOVER := Color(1.0, 0.72, 0.25, 0.35)
## How far a region fill sits BELOW its sketch plane (mm): under the sketch
## lines (at 0) but above the grid (at -GRID_SINK_MM), so nothing z-fights.
const FILL_SINK_MM := 0.02
## The one background colour for BOTH modes. Model mode paints it as the 3D
## environment's clear colour, sketch mode fills the 2D canvas with it, so
## switching modes does not change the colour under the work.
const COLOR_BG := Color(0.13, 0.14, 0.16)
const COLOR_BODY := Color(0.62, 0.66, 0.72)
const COLOR_BODY_SELECTED := Color(1.0, 0.72, 0.25)
## Solid edge overlay — dark, Fusion-style, so silhouettes read at any angle.
const COLOR_BODY_EDGE := Color(0.10, 0.11, 0.13)
const AXIS_LEN := 150.0
## Transparent draw order: the grid draws early among transparents.
const GRID_RENDER_PRIORITY := -1
## How far the grid quad sits BELOW its plane (mm). Enough to win/lose depth
## tests cleanly against coplanar lines, far too small to see.
const GRID_SINK_MM := 0.05

## Ground grid, Fusion-style. Lines every `step` mm with a brighter line every
## GRID_MAJOR_EVERY; the whole thing spans GRID_SPAN_MM each way from the
## origin, so it reads as a plane rather than a fixed-size mat.
## Grid line colours. Alpha 0.05 (the original) lands only ~11/255 above the
## background at FULL pixel coverage, and a line viewed near edge-on covers a
## fraction of a pixel, which quantises that away — so it must be higher than
## it looks like it needs to be. These were briefly pushed to 0.22/0.40 while
## the shader was multiplying two fades together and eating most of it; with
## that corrected, the same values read as a glaring white mat, so they come
## back down. The grid is scenery: present, legible, never competing with the
## geometry drawn on it.
const COLOR_GRID_MINOR := Color(1, 1, 1, 0.085)
const COLOR_GRID_MAJOR := Color(1, 1, 1, 0.17)
## Where lines have fully faded, as a fraction of the grid's own span. Under 1
## so the fade always completes inside the mesh — the grid must end because it
## faded out, never because the geometry stopped at a visible square edge.
const GRID_FADE_FRAC := 0.85
const GRID_MAJOR_EVERY := 5
## How far the grid reaches, as a COUNT OF STEPS each way from the origin.
##
## Both directions get the identical count, which is what keeps the cells
## square. Counting steps (rather than fixing a span in mm) means the grid
## grows and shrinks with the zoom-driven step, so it always covers the view;
## a fixed mm span would leave the grid ending mid-screen when zoomed out and
## emit needless geometry when zoomed in. The fade is derived from the same
## number, so the grid always ends by fading, never by the mesh running out.
const GRID_SPAN_STEPS := 44
## Upper bound on lines per direction, so a fine step over the fixed span
## cannot emit a wall of geometry.
const GRID_MAX_LINES := 400
## Aim for one grid line per this fraction of the VIEW HEIGHT. The sketch
## canvas aims for one line every ~48 px, so this is the same rule expressed as
## a fraction of the visible span — which makes the two grids agree instead of
## drifting apart. (It keyed off camera DISTANCE before; that is proportional to
## view height under perspective but meaningless under an orthographic camera,
## where the 3D grid ended up four times coarser than the canvas beneath it.)
const GRID_TARGET_FRAC := 48.0 / 700.0

var _plane_meshes := {}          # plane name -> MeshInstance3D
## Construction planes (M22): plane feature id -> MeshInstance3D / transform.
## Rebuilt from the document alongside the sketches.
var _cplane_meshes := {}
var _cplane_xf := {}
var _axes: MeshInstance3D = null
var _sketch_root: Node3D = null
var _grid: MeshInstance3D = null

## The plane the ground grid currently lies on. Model mode shows XY (the
## ground); sketch mode moves it onto the sketch's own plane so the grid
## reads as the surface being drawn on.
var _grid_plane := "XY"
## Full transform of the grid's plane (M22): construction planes carry an
## origin offset, so a basis alone no longer places the grid.
var _grid_xf := Transform3D.IDENTITY
var _grid_unit: UnitConverter.Unit = UnitConverter.Unit.IN
var _grid_step := 0.0
## Cross-fade state for the zoom transition: how far the next FINER ladder rung
## has arrived (0..1) and the ratio between the two rungs. Both change
## continuously as the view scales, which is what removes the pop.
var _grid_blend := 0.0
var _grid_ratio := 2.0
var _grid_shown := true

## Per-plane user visibility from the browser tree. The planes only actually
## show when the user asks for them AND the current mode wants them shown
## (`_planes_mode_visible`) — Fusion keeps them out of the way until a sketch
## is being placed.
var _plane_shown := {}           # plane name -> bool
var _planes_mode_visible := false
var _origin_shown := true
## Feature id of the selected solid, "" for none.
var _selected_body := ""
## Feature id -> false for bodies the browser tree has hidden. Absent = shown,
## so a newly created body is visible without needing an entry.
var _body_hidden := {}
## Feature id -> false for sketches the browser tree has hidden. Absent =
## shown. Governs the 3D line mesh AND the sketch-mode reference geometry, so
## one tick means the same thing in both modes.
var _sketch_hidden := {}
## Body rebuild state (M18). Bodies come from BodyBuilder, which is a
## coroutine when CSG booleans are involved: a rebuild may land a frame or
## two after the model change. `_bodies_building` serializes overlapping
## requests; the latest requested document wins.
var _bodies_building := false
var _bodies_pending: CadDocument = null
## The last built body list: [{id, name, mesh, feature_ids}].
var _bodies: Array = []
## Profile-pick hover highlight (owned by this node, outside _sketch_root so
## sketch rebuilds cannot orphan it mid-gesture).
var _profile_hover_mi: MeshInstance3D = null
var _profile_hover_key := ""


func _ready() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	# Z-up world: aim the key light down from above (-Z) and slightly to the
	# side, so the ground plane and solid tops are the lit surfaces.
	light.basis = Basis.looking_at(Vector3(-0.4, 0.6, -1.0), Vector3(0, 0, 1))
	add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = COLOR_BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	_build_grid()
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
	_axes = MeshInstance3D.new()
	_axes.name = "Axes"
	_axes.mesh = im
	# Plain depth-tested lines. They used to be `no_depth_test` to survive the
	# grid painting over them, but that same flag drew them THROUGH solids —
	# a blue axis skewering every extrude, which read as a transparent body.
	# Now the grid depth-tests and sits GRID_SINK_MM below the plane, so the
	# axes win against the grid honestly and hide behind solids like
	# everything else.
	var axis_mat := _line_material(Color.WHITE)
	_axes.material_override = axis_mat
	add_child(_axes)


## Draws the grid ANALYTICALLY on a single quad, rather than as line
## primitives.
##
## Line primitives were the root of the "missing grid lines" bug that survived
## four attempted fixes. `PRIMITIVE_LINES` rasterises a hairline exactly one
## pixel wide with no anti-aliasing, so at the grazing angles a ground plane is
## normally viewed at, lines land between pixel centres and simply disappear —
## in RUNS, which is why cells read as rectangles. Measuring a scanline across
## the old screenshots showed gaps of 13, 52, 39, 51 px where a smooth
## perspective ramp was expected: whole groups of lines absent. No amount of
## alpha, span, fade or step arithmetic can fix that, because the geometry was
## never the problem — the rasteriser was throwing it away.
##
## Computing coverage per fragment instead gives a line that is always at least
## a pixel wide and antialiases itself, using screen-space derivatives to know
## how wide a millimetre is at this pixel. Distant lines fade smoothly into the
## background instead of flickering out, and the whole grid is two triangles.
const GRID_SHADER := """
shader_type spatial;
// Depth-TESTED (but never written): solids must occlude the grid — painting
// it over bodies made every solid read as transparent. The coplanar-fight
// with sketch lines and axes is solved by sinking the quad GRID_SINK_MM
// below its plane instead of disabling the test.
render_mode unshaded, blend_mix, depth_draw_never,
	cull_disabled, shadows_disabled;

uniform float fade_mm = 2600.0;
// The COARSE decade currently in play, in mm. The next finer level is this
// divided by `level_ratio`, and `level_blend` says how far in it is.
uniform float step_mm = 25.4;
// Ratio between adjacent levels of the 1/2/5 ladder — not constant (1->2 is
// x2, 2->5 is x2.5, 5->10 is x2), so the CPU supplies the live one.
uniform float level_ratio = 2.0;
// 0 = only the coarse level is drawn, 1 = the fine level has fully arrived and
// has itself become the coarse one.
uniform float level_blend = 0.0;
uniform int major_every = 5;
uniform vec4 minor_color : source_color = vec4(1.0, 1.0, 1.0, 0.085);
uniform vec4 major_color : source_color = vec4(1.0, 1.0, 1.0, 0.17);

// Fraction of `fade_mm` that stays at FULL strength; only the outer sliver
// fades, so the working area is never dimmed.
const float FADE_START = 0.55;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

// Coverage of the nearest gridline of spacing `sp`, antialiased. `w` is how
// many millimetres this pixel spans, so a line never thins below one pixel and
// never aliases away.
float line_cover(vec2 p, float sp, vec2 w) {
	vec2 d = abs(fract(p / sp - 0.5) - 0.5) * sp;
	vec2 a = smoothstep(w * 1.5, w * 0.5, d);
	return max(a.x, a.y);
}

void fragment() {
	// The grid lies in the quad's own XY, so these are millimetres directly.
	vec2 p = local_pos.xy;
	// How much of the plane one pixel covers here — larger with distance, which
	// is exactly what keeps far lines a pixel wide instead of vanishing.
	vec2 w = fwidth(p) + 0.0001;

	// TWO LEVELS AT ONCE, cross-faded — the Blender behaviour.
	//
	// Snapping the spacing to a ladder means that at some zoom the step jumps
	// from one rung to the next and every intermediate line pops in or out on a
	// single frame. Drawing the coarse level solidly AND the next finer level
	// at `level_blend` opacity removes the pop entirely: the in-between lines
	// arrive gradually as you zoom in, reach full strength exactly as the
	// ladder clicks over, and the cycle repeats with no visible event.
	float fine_mm = step_mm / max(level_ratio, 1.001);
	float coarse = line_cover(p, step_mm, w);
	float fine = line_cover(p, fine_mm, w);
	// Majors ride the coarse level, so the every-fifth line stays put while the
	// finer subdivisions come and go around it.
	float major = line_cover(p, step_mm * float(major_every), w);

	// Alpha per family; the fine level is the only one that fades.
	float a_minor = coarse * minor_color.a;
	float a_fine = fine * minor_color.a * level_blend;
	float a_major = major * major_color.a;
	float cover = max(max(a_minor, a_fine), a_major);
	// Colour follows whichever family is strongest here, so a major reads as a
	// major even where a minor crosses it.
	vec4 col = mix(minor_color, major_color, step(max(a_minor, a_fine), a_major));

	// Radial fade so the grid dissolves into the background rather than ending
	// at a visible square edge.
	float d = length(p) / max(fade_mm, 0.001);
	cover *= 1.0 - smoothstep(FADE_START, 1.0, d);

	ALBEDO = col.rgb;
	ALPHA = cover;
}
"""


func _build_grid() -> void:
	_grid = MeshInstance3D.new()
	_grid.name = "Grid"
	# The grid is scenery: it must never occlude geometry sitting on it, and it
	# should not fight the depth buffer with coplanar sketch lines — both are
	# handled by the render_mode flags in GRID_SHADER.
	var sh := Shader.new()
	sh.code = GRID_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_grid.material_override = mat
	mat.render_priority = GRID_RENDER_PRIORITY
	_grid.sorting_offset = -1.0
	add_child(_grid)
	_rebuild_grid()


## Resize/reorient the grid quad and push the current step to the shader.
##
## The mesh is now two triangles that never change; only the transform and a
## few uniforms move, so this is cheap enough to call whenever the step changes.
func _rebuild_grid() -> void:
	if _grid == null:
		return
	if _grid_step <= 0.0:
		_grid_step = SketchView.step_for(_grid_unit, 25.0)
	# Reach, in millimetres. A whole number of steps keeps the fade landing on
	# a grid line rather than mid-cell.
	var half := _grid_step * mini(GRID_SPAN_STEPS, GRID_MAX_LINES)
	# One quad, oriented onto the grid's plane. QuadMesh is built in its own XY
	# with +Z as normal, which is exactly how the shader reads `local_pos`.
	var quad := QuadMesh.new()
	quad.size = Vector2(half * 2.0, half * 2.0)
	_grid.mesh = quad
	# A hair below the plane, so coplanar geometry (axes, sketch lines on the
	# plane) wins the depth test instead of z-fighting the grid.
	_grid.transform = Transform3D(_grid_xf.basis,
		_grid_xf * Vector3(0, 0, -GRID_SINK_MM))
	var mat := _grid.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fade_mm", half * GRID_FADE_FRAC)
		mat.set_shader_parameter("step_mm", _grid_step)
		mat.set_shader_parameter("major_every", GRID_MAJOR_EVERY)
		mat.set_shader_parameter("level_blend", _grid_blend)
		mat.set_shader_parameter("level_ratio", _grid_ratio)
		mat.set_shader_parameter("minor_color", COLOR_GRID_MINOR)
		mat.set_shader_parameter("major_color", COLOR_GRID_MAJOR)
	_grid.visible = _grid_shown


## Point the grid at a plane ("XY" in model mode, the sketch's plane while
## editing one). Origin-plane names resolve on their own; a construction
## plane passes its resolved transform as `xf` (M22). No-op when the grid is
## already there.
func set_grid_plane(key: String, xf: Variant = null) -> void:
	var want: Transform3D
	if xf is Transform3D:
		want = xf
	elif SketchFeature.PLANES.has(key):
		want = Transform3D(SketchFeature.plane_basis(key), Vector3.ZERO)
	else:
		return
	if _grid_plane == key and _grid_xf.is_equal_approx(want):
		return
	_grid_plane = key
	_grid_xf = want
	_rebuild_grid()


func grid_plane() -> String:
	return _grid_plane


func set_grid_unit(unit: UnitConverter.Unit) -> void:
	if _grid_unit == unit:
		return
	_grid_unit = unit
	_grid_step = 0.0
	_rebuild_grid()


## Adapt grid density to how much world the view spans: the spacing follows the
## same 1/2/5 ladder the sketch canvas uses, so zooming out thins the lines out
## instead of collapsing them into a solid sheet.
##
## `view_height_mm` — the world height of the viewport (`OrbitCamera.
## view_height_mm`), NOT the camera distance.
func update_grid(view_height_mm: float) -> void:
	var levels := SketchView.step_levels(
		_grid_unit, view_height_mm * GRID_TARGET_FRAC)
	var step: float = levels["step"]
	# The BLEND changes continuously even when the step does not, and it is what
	# makes zooming smooth, so it has to be pushed every time — an early-out on
	# the step alone would leave the cross-fade frozen between rungs and bring
	# the popping straight back.
	_grid_blend = levels["blend"]
	_grid_ratio = levels["ratio"]
	if is_equal_approx(step, _grid_step):
		_push_grid_uniforms()
		return
	_grid_step = step
	_rebuild_grid()


## Push only the per-frame uniforms (the cross-fade), leaving the mesh alone.
func _push_grid_uniforms() -> void:
	if _grid == null:
		return
	var mat := _grid.material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("level_blend", _grid_blend)
	mat.set_shader_parameter("level_ratio", _grid_ratio)


func set_grid_shown(shown: bool) -> void:
	_grid_shown = shown
	if _grid != null:
		_grid.visible = shown


func grid_shown() -> bool:
	return _grid_shown


func grid_step() -> float:
	return _grid_step


func _build_planes() -> void:
	for plane_name in SketchFeature.PLANES:
		var basis := SketchFeature.plane_basis(plane_name)
		# Fusion-style: the quad sits in ONE quadrant with its corner ON the
		# origin, running out along +u/+v — not a sheet centred on the origin.
		# QuadMesh is centred by construction, so shift it half a side each way.
		var quad := QuadMesh.new()
		quad.size = Vector2(PLANE_SIDE, PLANE_SIDE)
		quad.center_offset = Vector3(PLANE_SIDE * 0.5, PLANE_SIDE * 0.5, 0.0)
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
		mi.visible = false
		add_child(mi)
		_plane_meshes[plane_name] = mi
		# Unticked on open: Fusion starts with a clean view, and the box now
		# honestly reports that the plane is hidden.
		_plane_shown[plane_name] = false


## Plane-picking override: while true EVERY plane shows regardless of its
## browser tick, because the user is being asked to click one. Turning it off
## restores whatever the ticks say. The ticks themselves are untouched, so a
## plane the user unticked comes back hidden once picking ends.
func set_planes_visible(v: bool) -> void:
	_planes_mode_visible = v
	_apply_plane_visibility()


## Browser-tree toggle for a single plane — an origin plane by name or a
## construction plane by feature id. Independent of the mode gate: hiding
## "XY" here keeps it hidden even while picking a plane.
func set_plane_shown(plane_name: String, shown: bool) -> void:
	if not _plane_meshes.has(plane_name) and not _cplane_meshes.has(plane_name):
		return
	_plane_shown[plane_name] = shown
	_apply_plane_visibility()


func plane_shown(plane_name: String) -> bool:
	# Origin planes start hidden (Fusion's clean boot view); construction
	# planes start shown.
	return bool(_plane_shown.get(plane_name, _cplane_meshes.has(plane_name)))


## Browser-tree toggle for the origin axes. Unlike the planes these have no
## mode gate — axes are cheap orientation cues, so they stay up by default.
func set_origin_shown(shown: bool) -> void:
	_origin_shown = shown
	if _axes != null:
		_axes.visible = shown


func origin_shown() -> bool:
	return _origin_shown


func _apply_plane_visibility() -> void:
	for k: String in _plane_meshes:
		# A tick means "show it", full stop. Plane-picking additionally forces
		# all three on for the duration of the pick.
		(_plane_meshes[k] as MeshInstance3D).visible = \
			_planes_mode_visible or bool(_plane_shown.get(k, false))
	for k: String in _cplane_meshes:
		# Construction planes default SHOWN (a plane you just made for a
		# sketch should be there to click).
		(_cplane_meshes[k] as MeshInstance3D).visible = \
			_planes_mode_visible or bool(_plane_shown.get(k, true))


func _body_shown(fid: String) -> bool:
	return not bool(_body_hidden.get(fid, false))


## Browser-tree toggle for one solid body.
func set_body_shown(fid: String, shown: bool) -> void:
	if shown:
		_body_hidden.erase(fid)
	else:
		_body_hidden[fid] = true
	var mi := _body_mesh(fid)
	if mi != null:
		mi.visible = shown


func body_shown(fid: String) -> bool:
	return _body_shown(fid)


## Browser-tree toggle for one SKETCH's geometry. Absent = shown, so a newly
## created sketch is visible without needing an entry. The same flag governs
## the dimmed reference geometry drawn in sketch mode, so hiding a sketch hides
## it in both modes rather than only in the 3D view.
func set_sketch_shown(fid: String, shown: bool) -> void:
	if shown:
		_sketch_hidden.erase(fid)
	else:
		_sketch_hidden[fid] = true
	if _sketch_root == null:
		return
	# Both the line mesh (keyed on feature_id) and the region-fill mesh
	# (keyed on sketch_fill_for — it must NOT carry feature_id, or it would
	# be pickable as a body) obey the one tick.
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		if (mi.has_meta("feature_id") and not mi.has_meta("is_body") \
				and String(mi.get_meta("feature_id")) == fid) \
				or (mi.has_meta("sketch_fill_for") \
				and String(mi.get_meta("sketch_fill_for")) == fid):
			mi.visible = shown


func sketch_shown(fid: String) -> bool:
	return not bool(_sketch_hidden.get(fid, false))


## Highlight the selected solid; "" clears. View state only — recolouring a
## material is not a model mutation, so this never touches the command stack.
func set_selected_body(fid: String) -> void:
	if _selected_body == fid:
		return
	_selected_body = fid
	if _sketch_root == null:
		return
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.has_meta("feature_id"):
			continue
		# Bodies carry their shaded material on SURFACE 0 (surface 1 is the
		# edge overlay); sketch line meshes have no surface override and are
		# not bodies, so they fall through untouched.
		var mat := mi.get_surface_override_material(0) as StandardMaterial3D
		if mat == null:
			continue
		mat.albedo_color = COLOR_BODY_SELECTED \
			if String(mi.get_meta("feature_id")) == fid else COLOR_BODY


func selected_body() -> String:
	return _selected_body


func _body_mesh(fid: String) -> MeshInstance3D:
	if _sketch_root == null:
		return null
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.has_meta("feature_id") \
				and String(mi.get_meta("feature_id")) == fid:
			return mi
	return null


## Which solid body does this ray hit first? Feature id, or "" on a miss.
## Hidden bodies are not pickable — what you cannot see, you cannot click.
func pick_body(origin: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_t := INF
	if _sketch_root == null:
		return best
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible or not mi.has_meta("feature_id"):
			continue
		var t := _ray_mesh(mi, origin, dir)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = String(mi.get_meta("feature_id"))
	return best


func set_plane_hover(plane_name: String) -> void:
	for k: String in _plane_meshes:
		var mat := (_plane_meshes[k] as MeshInstance3D).material_override \
			as StandardMaterial3D
		mat.albedo_color = COLOR_PLANE_HOVER if k == plane_name else COLOR_PLANE
	for k: String in _cplane_meshes:
		var cmat := (_cplane_meshes[k] as MeshInstance3D).material_override \
			as StandardMaterial3D
		cmat.albedo_color = COLOR_CPLANE_HOVER if k == plane_name else COLOR_CPLANE


## Is a world point inside an origin plane's quad? The quad runs from the
## origin out along +u/+v, so both coordinates must be in 0..PLANE_SIDE.
func _on_quad(hit: Vector3, basis: Basis) -> bool:
	var u := hit.dot(basis.x)
	var v := hit.dot(basis.y)
	return u >= 0.0 and u <= PLANE_SIDE and v >= 0.0 and v <= PLANE_SIDE


## Math raycast (no physics): which plane quad does the ray hit — an origin
## plane (name) or a construction plane (feature id)? Returns "" on a miss.
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
		if _on_quad(hit, basis):
			best = plane_name
			best_t = t
	for fid: String in _cplane_xf:
		# Only pickable while its quad shows (mode gate or tick), like bodies:
		# what you cannot see, you cannot click.
		var mi := _cplane_meshes.get(fid) as MeshInstance3D
		if mi == null or not mi.visible:
			continue
		var xf: Transform3D = _cplane_xf[fid]
		var n2 := xf.basis.z
		var denom2 := dir.dot(n2)
		if absf(denom2) < 1e-6:
			continue
		var t2 := (xf.origin - origin).dot(n2) / denom2
		if t2 <= 0.0 or t2 >= best_t:
			continue
		# Construction quads are CENTRED on the plane origin (see
		# `_rebuild_cplanes`), unlike the corner-anchored origin quads.
		var local := xf.affine_inverse() * (origin + dir * t2)
		if absf(local.x) <= PLANE_SIDE * 0.5 and absf(local.y) <= PLANE_SIDE * 0.5:
			best = fid
			best_t = t2
	return best


## Resolved transform of a construction plane quad currently in the scene.
func cplane_transform(fid: String) -> Transform3D:
	return _cplane_xf.get(fid, Transform3D.IDENTITY)


## Rebuild the construction-plane quads from the document's live plane
## features (M22). Wholesale, like the sketch meshes: rollback/undo can add
## or remove planes in any order.
func _rebuild_cplanes(doc: CadDocument) -> void:
	for k: String in _cplane_meshes:
		(_cplane_meshes[k] as MeshInstance3D).queue_free()
	_cplane_meshes.clear()
	_cplane_xf.clear()
	for f in doc.live_features():
		var pf := f as PlaneFeature
		if pf == null:
			continue
		var xf := pf.transform()
		var quad := QuadMesh.new()
		# Centred on the plane origin: an offset plane should hover over the
		# model, not run off into one quadrant.
		quad.size = Vector2(PLANE_SIDE, PLANE_SIDE)
		var mi := MeshInstance3D.new()
		mi.name = "CPlane_" + pf.id
		mi.mesh = quad
		mi.transform = xf
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = COLOR_CPLANE
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		add_child(mi)
		_cplane_meshes[pf.id] = mi
		_cplane_xf[pf.id] = xf
	_apply_plane_visibility()


## Nearest flat body face under the ray (M22 face picking). Returns {} on a
## miss, else {"body": feature id, "point": Vector3 (world hit),
## "normal": Vector3 (world, unit, facing the ray)}.
func pick_face(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	if _sketch_root == null:
		return best
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.visible or not mi.has_meta("is_body"):
			continue
		var hit := _ray_mesh_face(mi, origin, dir)
		if not hit.is_empty() and float(hit["t"]) < best_t:
			best_t = float(hit["t"])
			best = {"body": String(mi.get_meta("feature_id")),
				"point": hit["point"], "normal": hit["normal"]}
	if not best.is_empty():
		# The face's outward side is the one looking at the camera.
		var n := best["normal"] as Vector3
		if n.dot(dir) > 0.0:
			best["normal"] = -n
	return best


## Like `_ray_mesh` but keeps the winning triangle's plane, not just the
## distance. {} on a miss.
func _ray_mesh_face(mi: MeshInstance3D, origin: Vector3, dir: Vector3) -> Dictionary:
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return {}
	var xform := mi.transform
	if not (xform * mesh.get_aabb()).intersects_ray(origin, dir):
		return {}
	var out := {}
	var best := INF
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		if verts.is_empty():
			continue
		var idx := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			idx = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var indexed := idx.size() > 0
		var count := idx.size() if indexed else verts.size()
		var i := 0
		while i + 2 < count:
			var a: Vector3 = xform * (verts[idx[i]] if indexed else verts[i])
			var b: Vector3 = xform * (verts[idx[i + 1]] if indexed else verts[i + 1])
			var cc: Vector3 = xform * (verts[idx[i + 2]] if indexed else verts[i + 2])
			var hit = Geometry3D.ray_intersects_triangle(origin, dir, a, b, cc)
			if hit != null:
				var t := origin.distance_to(hit as Vector3)
				if t < best:
					best = t
					out = {"t": t, "point": hit,
						"normal": (b - a).cross(cc - a).normalized()}
			i += 3
	return out


var _face_hover_mi: MeshInstance3D = null
var _face_hover_key := ""


## Highlight the flat face of `body_fid` through `point` with `normal` — all
## of the body's triangles coplanar with it, floated a hair off the surface.
func set_face_hover(body_fid: String, point: Vector3, normal: Vector3) -> void:
	var key := "%s|%.2f,%.2f,%.2f|%.2f" % [body_fid, normal.x, normal.y,
		normal.z, point.dot(normal)]
	if key == _face_hover_key and _face_hover_mi != null:
		return
	clear_face_hover()
	var mi := _body_mesh(body_fid)
	if mi == null:
		return
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return
	var d := point.dot(normal)
	var tris := PackedVector3Array()
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idx := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			idx = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var indexed := idx.size() > 0
		var count := idx.size() if indexed else verts.size()
		var i := 0
		while i + 2 < count:
			var a: Vector3 = mi.transform * (verts[idx[i]] if indexed else verts[i])
			var b: Vector3 = mi.transform * (verts[idx[i + 1]] if indexed else verts[i + 1])
			var c2: Vector3 = mi.transform * (verts[idx[i + 2]] if indexed else verts[i + 2])
			i += 3
			var tn := (b - a).cross(c2 - a).normalized()
			if absf(tn.dot(normal)) < 0.999:
				continue
			if absf(a.dot(normal) - d) > 0.05 or absf(b.dot(normal) - d) > 0.05 \
					or absf(c2.dot(normal) - d) > 0.05:
				continue
			var lift := normal * 0.05
			tris.append(a + lift)
			tris.append(b + lift)
			tris.append(c2 + lift)
	if tris.is_empty():
		return
	var hm := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = tris
	hm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_face_hover_mi = MeshInstance3D.new()
	_face_hover_mi.name = "FaceHover"
	_face_hover_mi.mesh = hm
	_face_hover_mi.material_override = _fill_material(COLOR_FACE_HOVER, false)
	add_child(_face_hover_mi)
	_face_hover_key = key


func clear_face_hover() -> void:
	if _face_hover_mi != null:
		_face_hover_mi.queue_free()
		_face_hover_mi = null
	_face_hover_key = ""


## Rebuild the 3D display for every live feature: sketch line meshes plus
## extruded solids. Arcs/circles are polyline-tessellated — display only.
func rebuild_sketches(doc: CadDocument) -> void:
	# Sketch line meshes rebuild synchronously here; BODY meshes rebuild
	# through `_rebuild_bodies` (M18) because boolean bodies bake through the
	# engine's CSG, which needs a frame. Body nodes are tagged and survive
	# this clear so solids never blink out while a rebuild is in flight.
	for c in _sketch_root.get_children():
		if not (c as Node).has_meta("is_body"):
			c.queue_free()
	_rebuild_cplanes(doc)
	for f in doc.live_features():
		if f is SolidFeature:
			continue   # bodies are rebuilt below, boolean-aware
		if not (f is SketchFeature):
			continue
		var sf := f as SketchFeature
		var im := ImmediateMesh.new()
		# One surface per entity so CONSTRUCTION geometry can carry its own
		# violet dashed look (M21 QA: it rendered exactly like normal
		# geometry in the 3D view). Normal entities stay solid line strips.
		var mats: Array = []
		var mat_normal := _line_material(COLOR_SKETCH)
		var mat_cons := _line_material(COLOR_CONSTRUCTION)
		for e in sf.sketch.entities():
			var pts := _entity_polyline(sf.sketch, e)
			if pts.size() < 2:
				continue
			if e.construction:
				var dashes := _dash_polyline(pts)
				if dashes.is_empty():
					continue
				im.surface_begin(Mesh.PRIMITIVE_LINES)
				for seg: Array in dashes:
					im.surface_add_vertex(sf.to_world(seg[0]))
					im.surface_add_vertex(sf.to_world(seg[1]))
				im.surface_end()
				mats.append(mat_cons)
			else:
				im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
				for p in pts:
					im.surface_add_vertex(sf.to_world(p))
				im.surface_end()
				mats.append(mat_normal)
		if mats.is_empty():
			continue
		var mi := MeshInstance3D.new()
		mi.name = sf.name
		mi.mesh = im
		mi.set_meta("feature_id", sf.id)
		for i in mats.size():
			mi.set_surface_override_material(i, mats[i])
		mi.visible = sketch_shown(sf.id)
		_sketch_root.add_child(mi)
		# Closed regions get a translucent face so the sketch reads as
		# extrudable (Fusion-style). No feature_id meta: fills must never be
		# body-pickable.
		var fill := _profile_fill_mesh(sf)
		if fill != null:
			var fmi := MeshInstance3D.new()
			fmi.name = sf.name + "Fill"
			fmi.mesh = fill
			fmi.set_meta("sketch_fill_for", sf.id)
			fmi.material_override = _fill_material(COLOR_REGION_FILL, false)
			fmi.visible = sketch_shown(sf.id)
			_sketch_root.add_child(fmi)
	_rebuild_bodies(doc)


## Chop a polyline into dash segments (2 mm dash / 1.5 mm gap, sketch mm) —
## 3D line rendering has no dash support, so the dashes are real segments.
## -> Array of [Vector2, Vector2] pairs.
static func _dash_polyline(pts: PackedVector2Array) -> Array:
	const DASH := 2.0
	const GAP := 1.5
	var out: Array = []
	var drawing := true
	var left := DASH
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 1e-9:
			continue
		var t := 0.0
		while t < seg_len - 1e-9:
			var step := minf(left, seg_len - t)
			if drawing:
				out.append([a.lerp(b, t / seg_len),
					a.lerp(b, (t + step) / seg_len)])
			t += step
			left -= step
			if left <= 1e-9:
				drawing = not drawing
				left = DASH if drawing else GAP
	return out


## Triangulated faces of every closed region in a sketch, sunk FILL_SINK_MM
## below its plane. null when the sketch closes nothing.
func _profile_fill_mesh(sf: SketchFeature) -> ArrayMesh:
	var tris := PackedVector3Array()
	var xf := sf.plane_transform()
	var off: Vector3 = xf.basis.z * -FILL_SINK_MM
	for prof: Dictionary in ProfileFinder.profiles(sf.sketch):
		var tri := ProfileFinder.triangulate_with_holes(
			prof["polygon"] as PackedVector2Array, prof.get("holes", []) as Array)
		var pts: PackedVector2Array = tri["points"]
		for i: int in (tri["indices"] as PackedInt32Array):
			tris.append(xf * Vector3(pts[i].x, pts[i].y, 0.0) + off)
	if tris.is_empty():
		return null
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _fill_material(color: Color, on_top: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if on_top:
		# Hover highlight must read even where a body covers the region.
		mat.no_depth_test = true
		mat.render_priority = 10
	return mat


## Highlight the region of `sf` enclosing sketch-uv `at` — the profile the
## Extrude click would take. Rebuilds only when the hovered region changes.
func set_profile_hover(sf: SketchFeature, at: Vector2) -> void:
	if sf == null:
		clear_profile_hover()
		return
	var prof := ProfileFinder.profile_at(sf.sketch, at)
	if prof.is_empty():
		clear_profile_hover()
		return
	var k := sf.id + "|" + str(prof["polygon"])
	if k == _profile_hover_key and _profile_hover_mi != null:
		return
	clear_profile_hover()
	var tri := ProfileFinder.triangulate_with_holes(
		prof["polygon"] as PackedVector2Array, prof.get("holes", []) as Array)
	var pts: PackedVector2Array = tri["points"]
	var idx: PackedInt32Array = tri["indices"]
	if idx.is_empty():
		return
	var xf := sf.plane_transform()
	var tris := PackedVector3Array()
	for i: int in idx:
		tris.append(xf * Vector3(pts[i].x, pts[i].y, 0.0))
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_profile_hover_mi = MeshInstance3D.new()
	_profile_hover_mi.name = "ProfileHover"
	_profile_hover_mi.mesh = mesh
	_profile_hover_mi.material_override = _fill_material(COLOR_REGION_HOVER, true)
	add_child(_profile_hover_mi)
	_profile_hover_key = k


func clear_profile_hover() -> void:
	if _profile_hover_mi != null:
		_profile_hover_mi.queue_free()
		_profile_hover_mi = null
	_profile_hover_key = ""


## Rebuild solid bodies via BodyBuilder. Runs to completion synchronously
## when no CSG boolean is involved (all extrudes are plain new bodies), so
## code that counts solids right after a stack change keeps working; with
## booleans it suspends for the CSG bake frame and applies when it lands.
## Overlapping requests coalesce: the newest document wins.
func _rebuild_bodies(doc: CadDocument) -> void:
	if _bodies_building:
		_bodies_pending = doc
		return
	_bodies_building = true
	while true:
		var bodies: Array = await BodyBuilder.build(doc, self)
		_apply_bodies(bodies)
		if _bodies_pending == null:
			break
		doc = _bodies_pending
		_bodies_pending = null
	_bodies_building = false


func _apply_bodies(bodies: Array) -> void:
	_bodies = bodies
	for c in _sketch_root.get_children():
		if (c as Node).has_meta("is_body"):
			c.free()   # immediate: the replacement is added THIS call
	for b: Dictionary in bodies:
		var mesh: ArrayMesh = b["mesh"]
		# A bake can legitimately come back with no surfaces (a cut consumed
		# the body); putting a surface override on it is the out-of-bounds
		# error QA §M18.6 hit.
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var smi := MeshInstance3D.new()
		smi.name = b["name"]
		smi.mesh = mesh
		# Feature id rides along so picks and the browser tree can map a
		# mesh back to its feature — node names follow the display name,
		# which the user can end up renaming.
		smi.set_meta("feature_id", b["id"])
		smi.set_meta("is_body", true)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = COLOR_BODY_SELECTED if b["id"] == _selected_body \
			else COLOR_BODY
		mat.metallic = 0.1
		mat.roughness = 0.7
		# Double-sided: with a closed outward-wound shell the back faces are
		# depth-hidden anyway, so this costs nothing — and it guarantees a
		# solid can NEVER render see-through even if some profile slips
		# through with reversed winding.
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Per-surface, NOT material_override: surface 1 (when present) is the
		# edge-line overlay and an override would shade the edges like the body.
		smi.set_surface_override_material(0, mat)
		if mesh.get_surface_count() > 1 \
				and mesh.surface_get_primitive_type(1) == Mesh.PRIMITIVE_LINES:
			var emat := _line_material(COLOR_BODY_EDGE)
			emat.albedo_color = COLOR_BODY_EDGE
			smi.set_surface_override_material(1, emat)
		smi.visible = _body_shown(b["id"])
		_sketch_root.add_child(smi)


## The last built body list: [{id, name, mesh, feature_ids}]. Display state —
## derived from the document, possibly a frame behind it (see above).
func bodies() -> Array:
	return _bodies


## World-space bounds of everything the model shows — solids and sketch
## lines. Returns a zero-size AABB when there is nothing to frame, which the
## camera reads as "no bodies".
func model_bounds() -> AABB:
	var out := AABB()
	var any := false
	if _sketch_root == null:
		return out
	for c in _sketch_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var box := mi.transform * mi.mesh.get_aabb()
		if not any:
			out = box
			any = true
		else:
			out = out.merge(box)
	return out


## Nearest surface point under a ray, across solids and the origin planes.
## Returns {"ok": bool, "pos": Vector3}.
func pick_point(origin: Vector3, dir: Vector3) -> Dictionary:
	var best_t := INF
	var best := Vector3.ZERO
	# Solid meshes: triangle-exact so the pivot lands on the surface the user
	# is actually looking at, not on its bounding box.
	if _sketch_root != null:
		for c in _sketch_root.get_children():
			var mi := c as MeshInstance3D
			if mi == null or mi.mesh == null or not mi.visible:
				continue
			var t := _ray_mesh(mi, origin, dir)
			if t >= 0.0 and t < best_t:
				best_t = t
				best = origin + dir * t
	# Origin planes, only where they are visible.
	for k: String in _plane_meshes:
		if not (_plane_meshes[k] as MeshInstance3D).visible:
			continue
		var basis := SketchFeature.plane_basis(k)
		var n := basis.z
		var denom := dir.dot(n)
		if absf(denom) < 1e-6:
			continue
		var t2 := -origin.dot(n) / denom
		if t2 <= 0.0 or t2 >= best_t:
			continue
		var hit := origin + dir * t2
		if _on_quad(hit, basis):
			best_t = t2
			best = hit
	if best_t == INF:
		return {"ok": false, "pos": Vector3.ZERO}
	return {"ok": true, "pos": best}


## Ray vs a mesh instance's triangles; nearest positive t or -1. Only solids
## (ArrayMesh) are pickable — sketches render as ImmediateMesh line strips,
## which have no surface to land a pivot on.
func _ray_mesh(mi: MeshInstance3D, origin: Vector3, dir: Vector3) -> float:
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return -1.0
	var xform := mi.transform
	# Cheap reject before touching triangles.
	if not (xform * mesh.get_aabb()).intersects_ray(origin, dir):
		return -1.0
	var best := -1.0
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		if verts.is_empty():
			continue
		# Index array is null for non-indexed surfaces (the extrude builder
		# emits those), so fall back to reading vertices in triples.
		var idx := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			idx = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var indexed := idx.size() > 0
		var count := idx.size() if indexed else verts.size()
		var i := 0
		while i + 2 < count:
			var a: Vector3 = verts[idx[i]] if indexed else verts[i]
			var b: Vector3 = verts[idx[i + 1]] if indexed else verts[i + 1]
			var c: Vector3 = verts[idx[i + 2]] if indexed else verts[i + 2]
			var hit = Geometry3D.ray_intersects_triangle(
				origin, dir, xform * a, xform * b, xform * c)
			if hit != null:
				var t := origin.distance_to(hit as Vector3)
				if best < 0.0 or t < best:
					best = t
			i += 3
	return best


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
