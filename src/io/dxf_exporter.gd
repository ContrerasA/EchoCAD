class_name DxfExporter
extends RefCounted
## Minimal DXF R12 (ASCII) writer for a single sketch (M21). Geometry goes
## out in sketch-plane coordinates, millimetres ($INSUNITS = 4), one entity
## per SketchLine/Arc/Circle plus lone SketchPoints. Regular geometry lands
## on layer "0", construction geometry on layer "CONSTRUCTION" so CAM /
## other CAD can filter it. The sketch origin point is scaffolding and is
## not exported.
##
## R12 because it is the lingua franca: every importer reads it and it
## needs no class dictionaries or handles.


static func to_dxf(sk: Sketch) -> String:
	var out := PackedStringArray()
	var w := func(code: int, value: Variant) -> void:
		out.append(str(code))
		out.append(str(value))
	# --- HEADER: declare millimetres.
	w.call(0, "SECTION")
	w.call(2, "HEADER")
	w.call(9, "$INSUNITS")
	w.call(70, 4)
	w.call(0, "ENDSEC")
	# --- TABLES: the two layers, so strict importers see them declared.
	w.call(0, "SECTION")
	w.call(2, "TABLES")
	w.call(0, "TABLE")
	w.call(2, "LAYER")
	w.call(70, 2)
	for lname: String in ["0", "CONSTRUCTION"]:
		w.call(0, "LAYER")
		w.call(2, lname)
		w.call(70, 0)
		w.call(62, 7)
		w.call(6, "CONTINUOUS")
	w.call(0, "ENDTAB")
	w.call(0, "ENDSEC")
	# --- ENTITIES.
	w.call(0, "SECTION")
	w.call(2, "ENTITIES")
	var referenced := {}
	for e in sk.entities():
		for pid in e.point_refs():
			referenced[pid] = true
	for e in sk.entities():
		var layer := "CONSTRUCTION" if e.construction else "0"
		match e.kind():
			"line":
				var l := e as SketchLine
				var a := sk.point(l.p0)
				var b := sk.point(l.p1)
				if a == null or b == null:
					continue
				w.call(0, "LINE")
				w.call(8, layer)
				w.call(10, a.pos.x)
				w.call(20, a.pos.y)
				w.call(11, b.pos.x)
				w.call(21, b.pos.y)
			"circle":
				var ci := e as SketchCircle
				var c := sk.point(ci.center)
				if c == null:
					continue
				w.call(0, "CIRCLE")
				w.call(8, layer)
				w.call(10, c.pos.x)
				w.call(20, c.pos.y)
				w.call(40, ci.radius)
			"arc":
				var arc := e as SketchArc
				var c2 := sk.point(arc.center)
				var s := sk.point(arc.start)
				var en := sk.point(arc.end)
				if c2 == null or s == null or en == null:
					continue
				var r := c2.pos.distance_to(s.pos)
				# DXF arcs run CCW from angle 50 to 51: a CW arc swaps ends.
				var a0 := rad_to_deg((s.pos - c2.pos).angle())
				var a1 := rad_to_deg((en.pos - c2.pos).angle())
				if not arc.ccw:
					var tmp := a0
					a0 = a1
					a1 = tmp
				w.call(0, "ARC")
				w.call(8, layer)
				w.call(10, c2.pos.x)
				w.call(20, c2.pos.y)
				w.call(40, r)
				w.call(50, fposmod(a0, 360.0))
				w.call(51, fposmod(a1, 360.0))
			"point":
				# Only LONE points: endpoints/centers already travel with
				# their entity, and the origin is scaffolding.
				if referenced.has(e.id) or e.id == sk.origin_id():
					continue
				w.call(0, "POINT")
				w.call(8, layer)
				w.call(10, (e as SketchPoint).pos.x)
				w.call(20, (e as SketchPoint).pos.y)
	w.call(0, "ENDSEC")
	w.call(0, "EOF")
	return "\n".join(out) + "\n"


## Write `sk` to `path`. Returns "" on success or the failure reason.
static func save(sk: Sketch, path: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s: %s" % [path,
			error_string(FileAccess.get_open_error())]
	f.store_string(to_dxf(sk))
	f.close()
	return ""
