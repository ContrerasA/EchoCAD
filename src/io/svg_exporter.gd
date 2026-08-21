class_name SvgExporter
extends RefCounted
## M44 — sketch -> SVG (mm user units, y up flipped to SVG's y down, one
## path per entity; splines as their tessellation). For laser / vinyl /
## web workflows alongside DXF.


static func to_svg(sk: Sketch, include_construction := false, stroke_mm := 0.2) -> String:
	var ents: Array = []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for e in sk.entities():
		if e.kind() == "point":
			continue
		if e.construction and not include_construction:
			continue
		var pts := SketchGeometry.entity_polyline(sk, e)
		if pts.size() < 2:
			continue
		ents.append({"e": e, "pts": pts})
		for p in pts:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	if ents.is_empty():
		lo = Vector2.ZERO
		hi = Vector2(10, 10)
	var pad := 2.0
	var w := hi.x - lo.x + pad * 2.0
	var h := hi.y - lo.y + pad * 2.0
	var sb := PackedStringArray()
	sb.append('<?xml version="1.0" encoding="UTF-8"?>')
	sb.append('<svg xmlns="http://www.w3.org/2000/svg" width="%.4fmm" height="%.4fmm" viewBox="%.4f %.4f %.4f %.4f">'
		% [w, h, lo.x - pad, -(hi.y + pad), w, h])
	sb.append('<!-- EchoCAD sketch export, millimetres, y up -->')
	sb.append('<g fill="none" stroke="#000000" stroke-width="%.3f" stroke-linecap="round" stroke-linejoin="round">' % stroke_mm)
	for rec: Dictionary in ents:
		var e: SketchEntity = rec["e"]
		var pts: PackedVector2Array = rec["pts"]
		var dash := ' stroke-dasharray="1 0.8"' if e.construction else ""
		match e.kind():
			"circle":
				var c := sk.point((e as SketchCircle).center).pos
				sb.append('<circle cx="%.4f" cy="%.4f" r="%.4f"%s />' % [c.x, -c.y, (e as SketchCircle).radius, dash])
			"line":
				var a := sk.point((e as SketchLine).p0).pos
				var b := sk.point((e as SketchLine).p1).pos
				sb.append('<line x1="%.4f" y1="%.4f" x2="%.4f" y2="%.4f"%s />' % [a.x, -a.y, b.x, -b.y, dash])
			"arc":
				var arc := e as SketchArc
				var c2 := sk.point(arc.center).pos
				var s := sk.point(arc.start).pos
				var en := sk.point(arc.end).pos
				var r := s.distance_to(c2)
				# Sweep direction from the tessellation (SVG: large-arc + sweep flags).
				var a0 := (s - c2).angle()
				var a1 := (en - c2).angle()
				var ccw := pts.size() > 2 and (pts[1] - c2).angle_to(pts[0] - c2) < 0.0
				var sweep := fposmod(a1 - a0, TAU) if ccw else fposmod(a0 - a1, TAU)
				var large := 1 if sweep > PI else 0
				# y is flipped, so the sweep flag inverts.
				var sweep_flag := 0 if ccw else 1
				sb.append('<path d="M %.4f %.4f A %.4f %.4f 0 %d %d %.4f %.4f"%s />' % [
					s.x, -s.y, r, r, large, sweep_flag, en.x, -en.y, dash])
			_:
				var d := "M %.4f %.4f" % [pts[0].x, -pts[0].y]
				for i in range(1, pts.size()):
					d += " L %.4f %.4f" % [pts[i].x, -pts[i].y]
				sb.append('<path d="%s"%s />' % [d, dash])
	sb.append('</g></svg>')
	return "\n".join(sb)


static func save(sk: Sketch, path: String, include_construction := false) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "cannot write %s" % path}
	f.store_string(to_svg(sk, include_construction))
	f.close()
	return {"ok": true, "error": ""}
