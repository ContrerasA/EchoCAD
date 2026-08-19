class_name SolidFeature
extends Feature
## Base of the solid-producing features (extrude, revolve — M23). Carries
## Fusion's operation dropdown, which BodyBuilder evaluates in timeline
## order:
##   new_body — starts a solid of its own,
##   join     — unions into every body it touches (none touched: new body),
##   cut      — carves its shape out of every body it touches (none: no-op).

const OP_NEW_BODY := "new_body"
const OP_JOIN := "join"
const OP_CUT := "cut"

var operation := OP_NEW_BODY

## Per-body appearance (M32): albedo of the body ROOTED at this feature.
## Alpha 0 = unset (the default gray). Ignored on join/cut features.
var color := Color(0, 0, 0, 0)


func to_dict() -> Dictionary:
	var d := super.to_dict()
	if color.a > 0.0:
		d["color"] = [color.r, color.g, color.b]
	return d


func _read_base(d: Dictionary) -> void:
	super._read_base(d)
	var c: Variant = d.get("color")
	if c is Array and (c as Array).size() >= 3:
		color = Color(float(c[0]), float(c[1]), float(c[2]), 1.0)


## Exact watertight mesh of this feature's own solid (surface 0 = shaded
## triangles, surface 1 = edge-line overlay). null when the profile/axis no
## longer resolves.
func build_mesh(_doc: CadDocument) -> ArrayMesh:
	return null


## Everything BodyBuilder needs to boolean this feature: at least
## {"feature": self, "aabb": AABB (world)} plus whatever csg_node reads.
## {} when the feature no longer resolves.
func solid_part(_doc: CadDocument) -> Dictionary:
	return {}


## This feature's solid as a CSG node (for boolean bodies), positioned in
## world space. `part` is this feature's solid_part result.
func csg_node(_part: Dictionary) -> CSGShape3D:
	return null


## Coplanar boolean faces z-fight and confuse the CSG classifier; cut
## shapes are extended by this much past their exact bounds.
const EPS_MM := 0.05


## Offset a ccw ring by `by` mm (positive grows, negative shrinks; verified
## convention of Geometry2D.offset_polygon for ccw input). Offsetting can
## split a ring into several or collapse it entirely — the largest surviving
## ring wins, and an empty result comes back empty (callers skip the ring).
static func offset_ring(poly: PackedVector2Array, by: float) -> PackedVector2Array:
	var res := Geometry2D.offset_polygon(poly, by, Geometry2D.JOIN_MITER)
	if res.is_empty():
		return PackedVector2Array()
	var best: PackedVector2Array = res[0]
	var best_a := absf(ring_area(best))
	for r: PackedVector2Array in res:
		var a := absf(ring_area(r))
		if a > best_a:
			best = r
			best_a = a
	return best


static func ring_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return a * 0.5
