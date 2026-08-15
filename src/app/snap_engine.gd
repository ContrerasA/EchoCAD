class_name SnapEngine
extends RefCounted
## Snap targets for sketch tools. Priorities (strongest first): existing
## points (endpoint/center), line midpoints, on-curve, grid intersections.
## Tolerance is SCREEN pixels — callers convert via zoom. The result carries
## enough identity for inference to turn a snap into a constraint
## (Fusion-style: the snap the user SAW is the constraint they get).

const TOL_PX := 8.0

## Result kinds, strongest to weakest.
const KIND_POINT := "point"      # {id} — an existing SketchPoint
const KIND_MID := "mid"          # {owner} — line midpoint
const KIND_CURVE := "curve"      # {owner} — on an entity's curve
const KIND_GRID := "grid"

var grid_enabled := true
var entity_snap_enabled := true

var _points: Array = []          # [{pos, id}]
var _mids: Array = []            # [{pos, owner}]
var _curves: Array[String] = []  # entity ids for on-curve snapping
var _sketch: Sketch = null


## Build the target index. `exclude` — entity ids being dragged/created (a
## Dictionary set or Array) so a gesture never snaps to itself.
func build_index(sk: Sketch, exclude = []) -> void:
	_sketch = sk
	var ex := {}
	if exclude is Dictionary:
		ex = exclude
	else:
		for id in exclude:
			ex[id] = true
	_points.clear()
	_mids.clear()
	_curves.clear()
	if sk == null:
		return
	for e in sk.entities():
		if ex.has(e.id):
			continue
		match e.kind():
			"point":
				_points.append({"pos": (e as SketchPoint).pos, "id": e.id})
			"line":
				var m := SketchGeometry.line_midpoint(sk, e as SketchLine)
				if m.get("ok", false):
					_mids.append({"pos": m["pos"], "owner": e.id})
				_curves.append(e.id)
			"arc", "circle":
				_curves.append(e.id)


## Best snap for `world` (mm). `tol_mm` = TOL_PX / zoom. `grid_step` mm (0 =
## no grid snapping). Returns {pos, kind, ...} — kind "" when nothing hit
## (pos passes through unchanged).
func snap_point(world: Vector2, tol_mm: float, grid_step: float) -> Dictionary:
	if entity_snap_enabled:
		var best: Dictionary = {}
		var best_d := tol_mm
		for t: Dictionary in _points:
			var d := (t["pos"] as Vector2).distance_to(world)
			if d <= best_d:
				best = {"pos": t["pos"], "kind": KIND_POINT, "id": t["id"]}
				best_d = d
		if not best.is_empty():
			return best
		best_d = tol_mm
		for t: Dictionary in _mids:
			var d := (t["pos"] as Vector2).distance_to(world)
			if d <= best_d:
				best = {"pos": t["pos"], "kind": KIND_MID, "owner": t["owner"]}
				best_d = d
		if not best.is_empty():
			return best
		best_d = tol_mm
		for id in _curves:
			var e := _sketch.entity(id)
			if e == null:
				continue
			var r := SketchGeometry.closest_on_entity(_sketch, e, world)
			if not r.get("ok", false):
				continue
			var d := (r["pos"] as Vector2).distance_to(world)
			if d <= best_d:
				best = {"pos": r["pos"], "kind": KIND_CURVE, "owner": id}
				best_d = d
		if not best.is_empty():
			return best
	# Grid snap is a magnet everywhere (CAD convention), not tolerance-gated.
	if grid_enabled and grid_step > 0.0:
		return {"pos": (world / grid_step).round() * grid_step, "kind": KIND_GRID}
	return {"pos": world, "kind": ""}
