class_name Measure
extends RefCounted

## M27: selection-driven measurement. Pure functions over sketch entities —
## the UI (status readout) and the RPC query both call `analyze` and format
## the same numbers, so what the label says is exactly what automation sees.
##
## All values are canonical mm / degrees; `describe` formats for a display
## unit at the UI boundary, per the project rule.


## {kind, ...values} for a selection, or {} when the selection has no single
## obvious measurement. Kinds:
##   line_length {mm, angle_deg}      one line
##   radius {mm, diameter_mm}         one circle or arc
##   point_distance {mm, dx, dy}      two points
##   point_line {mm}                  point + line (perpendicular distance)
##   angle {deg}                      two non-parallel lines
##   parallel_distance {mm}           two parallel lines
##   center_distance {mm}             two circles/arcs
static func analyze(sk: Sketch, ids: Array) -> Dictionary:
	if sk == null or ids.is_empty() or ids.size() > 2:
		return {}
	var ents: Array = []
	for id in ids:
		var e := sk.entity(String(id))
		if e == null:
			return {}
		ents.append(e)
	if ents.size() == 1:
		var e: SketchEntity = ents[0]
		match e.kind():
			"line":
				var a := sk.point((e as SketchLine).p0).pos
				var b := sk.point((e as SketchLine).p1).pos
				var d := b - a
				return {"kind": "line_length", "mm": d.length(),
					"angle_deg": absf(fposmod(rad_to_deg(d.angle()), 180.0))}
			"circle":
				var r := (e as SketchCircle).radius
				return {"kind": "radius", "mm": r, "diameter_mm": r * 2.0}
			"arc":
				var arc := e as SketchArc
				var r2 := sk.point(arc.start).pos.distance_to(
					sk.point(arc.center).pos)
				return {"kind": "radius", "mm": r2, "diameter_mm": r2 * 2.0}
		return {}
	var ka: String = ents[0].kind()
	var kb: String = ents[1].kind()
	if ka == "point" and kb == "point":
		var pa := (ents[0] as SketchPoint).pos
		var pb := (ents[1] as SketchPoint).pos
		return {"kind": "point_distance", "mm": pa.distance_to(pb),
			"dx": absf(pb.x - pa.x), "dy": absf(pb.y - pa.y)}
	if (ka == "point" and kb == "line") or (ka == "line" and kb == "point"):
		var pt := (ents[0] if ka == "point" else ents[1]) as SketchPoint
		var ln := (ents[1] if ka == "point" else ents[0]) as SketchLine
		var a2 := sk.point(ln.p0).pos
		var b2 := sk.point(ln.p1).pos
		var dir := (b2 - a2)
		if dir.length() < 1e-9:
			return {}
		var n := Vector2(-dir.y, dir.x).normalized()
		return {"kind": "point_line", "mm": absf(n.dot(pt.pos - a2))}
	if ka == "line" and kb == "line":
		var la := ents[0] as SketchLine
		var lb := ents[1] as SketchLine
		var da := (sk.point(la.p1).pos - sk.point(la.p0).pos)
		var db := (sk.point(lb.p1).pos - sk.point(lb.p0).pos)
		if da.length() < 1e-9 or db.length() < 1e-9:
			return {}
		var ang := absf(rad_to_deg(da.angle_to(db)))
		if ang > 90.0:
			ang = 180.0 - ang
		if ang < 0.05:
			var n2 := Vector2(-da.y, da.x).normalized()
			return {"kind": "parallel_distance",
				"mm": absf(n2.dot(sk.point(lb.p0).pos - sk.point(la.p0).pos))}
		return {"kind": "angle", "deg": ang}
	if ka in ["circle", "arc"] and kb in ["circle", "arc"]:
		var ca := _center_of(sk, ents[0])
		var cb := _center_of(sk, ents[1])
		return {"kind": "center_distance", "mm": ca.distance_to(cb)}
	return {}


static func _center_of(sk: Sketch, e: SketchEntity) -> Vector2:
	if e.kind() == "circle":
		return sk.point((e as SketchCircle).center).pos
	return sk.point((e as SketchArc).center).pos


## One-line human string for the status bar, in the display unit.
static func describe(sk: Sketch, ids: Array, unit: UnitConverter.Unit) -> String:
	var m := analyze(sk, ids)
	if m.is_empty():
		return ""
	match String(m["kind"]):
		"line_length":
			return "Length %s   ∠ %.1f°" % [
				UnitConverter.format(m["mm"], unit), m["angle_deg"]]
		"radius":
			return "R %s   ⌀ %s" % [UnitConverter.format(m["mm"], unit),
				UnitConverter.format(m["diameter_mm"], unit)]
		"point_distance":
			return "Dist %s   ΔX %s  ΔY %s" % [
				UnitConverter.format(m["mm"], unit),
				UnitConverter.format(m["dx"], unit),
				UnitConverter.format(m["dy"], unit)]
		"point_line":
			return "Dist %s" % UnitConverter.format(m["mm"], unit)
		"angle":
			return "∠ %.2f°" % float(m["deg"])
		"parallel_distance":
			return "Dist %s (parallel)" % UnitConverter.format(m["mm"], unit)
		"center_distance":
			return "Centers %s" % UnitConverter.format(m["mm"], unit)
	return ""
