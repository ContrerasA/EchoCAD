class_name MeshIo
extends RefCounted
## M44 — mesh interchange: READ STL (binary/ascii), OBJ, 3MF; WRITE 3MF and
## OBJ. Everything in canonical mm. Readers return a flat triangle soup
## ({triangles: PackedVector3Array, name, error}); the caller welds it
## through the kernel. 3MF is the zip+XML core spec (unit, objects with
## meshes, basematerials for per-body colour, build items).

const NS_3MF := "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
const NS_MAT := "http://schemas.microsoft.com/3dmanufacturing/material/2015/02"


## --- reading ------------------------------------------------------------------

## -> {ok, triangles: PackedVector3Array, name: String, error: String,
##     objects: Array (3MF: [{name, triangles}])}
static func read(path: String, scale := 1.0) -> Dictionary:
	var ext := path.get_extension().to_lower()
	var out := {}
	match ext:
		"stl":
			out = read_stl(path)
		"obj":
			out = read_obj(path)
		"3mf":
			out = read_3mf(path)
		_:
			return {"ok": false, "error": "unsupported mesh format .%s" % ext,
				"triangles": PackedVector3Array(), "objects": []}
	if bool(out.get("ok", false)) and absf(scale - 1.0) > 1e-12:
		# Scale each object once (the readers may share one buffer between
		# `triangles` and the single object), then rebuild the flat list.
		var all := PackedVector3Array()
		for o: Dictionary in out.get("objects", []):
			var ot: PackedVector3Array = (o["triangles"] as PackedVector3Array).duplicate()
			for i in ot.size():
				ot[i] *= scale
			o["triangles"] = ot
			all.append_array(ot)
		out["triangles"] = all
	return out


static func read_stl(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot read %s" % path, "triangles": PackedVector3Array(), "objects": []}
	var size := f.get_length()
	var head := f.get_buffer(mini(80, size))
	var tris := PackedVector3Array()
	# Binary: 80-byte header + uint32 count + 50 bytes per facet.
	var is_binary := false
	if size >= 84:
		f.seek(80)
		var count := f.get_32()
		is_binary = size == 84 + count * 50
	var name := path.get_file().get_basename()
	if is_binary:
		f.seek(80)
		var count := f.get_32()
		for i in count:
			f.get_float(); f.get_float(); f.get_float()   # facet normal, recomputed
			for v in 3:
				var x := f.get_float()
				var y := f.get_float()
				var z := f.get_float()
				tris.append(Vector3(x, y, z))
			f.get_16()
	else:
		f.seek(0)
		var text := f.get_as_text()
		for line in text.split("\n"):
			var t := line.strip_edges()
			if t.begins_with("vertex"):
				var parts := t.split(" ", false)
				if parts.size() >= 4:
					tris.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			elif t.begins_with("solid") and t.length() > 6:
				name = t.substr(6).strip_edges()
		if tris.size() % 3 != 0:
			tris.resize(tris.size() - tris.size() % 3)
	f.close()
	if tris.is_empty():
		return {"ok": false, "error": "no triangles in %s" % path.get_file(), "triangles": tris, "objects": []}
	return {"ok": true, "triangles": tris, "name": name, "error": "",
		"objects": [{"name": name, "triangles": tris}]}


static func read_obj(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot read %s" % path, "triangles": PackedVector3Array(), "objects": []}
	var verts := PackedVector3Array()
	var objects: Array = []
	var cur := {"name": path.get_file().get_basename(), "triangles": PackedVector3Array()}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.split(" ", false)
			if p.size() >= 4:
				verts.append(Vector3(p[1].to_float(), p[2].to_float(), p[3].to_float()))
		elif line.begins_with("o ") or line.begins_with("g "):
			if not (cur["triangles"] as PackedVector3Array).is_empty():
				objects.append(cur)
			cur = {"name": line.substr(2).strip_edges(), "triangles": PackedVector3Array()}
		elif line.begins_with("f "):
			var p := line.split(" ", false)
			var idx: Array = []
			for k in range(1, p.size()):
				var token: String = p[k].split("/")[0]
				var i := token.to_int()
				if i < 0:
					i = verts.size() + i
				else:
					i -= 1
				if i >= 0 and i < verts.size():
					idx.append(i)
			# Fan-triangulate polygons.
			for k in range(1, idx.size() - 1):
				var tr: PackedVector3Array = cur["triangles"]
				tr.append(verts[idx[0]])
				tr.append(verts[idx[k]])
				tr.append(verts[idx[k + 1]])
				cur["triangles"] = tr
	f.close()
	if not (cur["triangles"] as PackedVector3Array).is_empty():
		objects.append(cur)
	var all := PackedVector3Array()
	for o: Dictionary in objects:
		all.append_array(o["triangles"])
	if all.is_empty():
		return {"ok": false, "error": "no faces in %s" % path.get_file(), "triangles": all, "objects": []}
	return {"ok": true, "triangles": all, "name": String(objects[0]["name"]), "error": "",
		"objects": objects}


static func read_3mf(path: String) -> Dictionary:
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return {"ok": false, "error": "cannot open %s as a 3MF (zip)" % path.get_file(),
			"triangles": PackedVector3Array(), "objects": []}
	var model_path := ""
	for fpath in zr.get_files():
		if fpath.to_lower().ends_with(".model"):
			model_path = fpath
			if fpath.begins_with("3D/"):
				break
	if model_path == "":
		zr.close()
		return {"ok": false, "error": "no 3D model part in %s" % path.get_file(),
			"triangles": PackedVector3Array(), "objects": []}
	var xml := zr.read_file(model_path)
	zr.close()
	var parser := XMLParser.new()
	if parser.open_buffer(xml) != OK:
		return {"ok": false, "error": "3MF model XML unreadable", "triangles": PackedVector3Array(), "objects": []}
	var unit_scale := 1.0
	var objects := {}      # id -> {name, verts, tris (indices)}
	var cur_id := ""
	var in_mesh := false
	var build: Array = []   # [{objectid, transform}]
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			if parser.get_node_type() == XMLParser.NODE_ELEMENT_END and parser.get_node_name() == "object":
				cur_id = ""
			continue
		var tag := parser.get_node_name()
		# Strip namespace prefixes (m:, etc.).
		if tag.contains(":"):
			tag = tag.split(":")[1]
		match tag:
			"model":
				var unit := parser.get_named_attribute_value_safe("unit")
				unit_scale = {"micron": 0.001, "millimeter": 1.0, "centimeter": 10.0,
					"inch": 25.4, "foot": 304.8, "meter": 1000.0}.get(unit, 1.0)
			"object":
				cur_id = parser.get_named_attribute_value_safe("id")
				objects[cur_id] = {"name": parser.get_named_attribute_value_safe("name"),
					"verts": PackedVector3Array(), "tris": PackedInt32Array(),
					"type": parser.get_named_attribute_value_safe("type")}
			"vertex":
				if cur_id != "":
					var vs: PackedVector3Array = objects[cur_id]["verts"]
					vs.append(Vector3(
						parser.get_named_attribute_value_safe("x").to_float(),
						parser.get_named_attribute_value_safe("y").to_float(),
						parser.get_named_attribute_value_safe("z").to_float()))
					objects[cur_id]["verts"] = vs
			"triangle":
				if cur_id != "":
					var tr: PackedInt32Array = objects[cur_id]["tris"]
					tr.append(parser.get_named_attribute_value_safe("v1").to_int())
					tr.append(parser.get_named_attribute_value_safe("v2").to_int())
					tr.append(parser.get_named_attribute_value_safe("v3").to_int())
					objects[cur_id]["tris"] = tr
			"item":
				build.append({"objectid": parser.get_named_attribute_value_safe("objectid"),
					"transform": parser.get_named_attribute_value_safe("transform")})
	var out_objects: Array = []
	var all := PackedVector3Array()
	var items := build
	if items.is_empty():
		for oid in objects:
			items.append({"objectid": oid, "transform": ""})
	var k := 0
	for it: Dictionary in items:
		var o: Dictionary = objects.get(String(it["objectid"]), {})
		if o.is_empty() or (o["tris"] as PackedInt32Array).is_empty():
			continue
		var xf := _parse_3mf_transform(String(it["transform"]))
		var verts: PackedVector3Array = o["verts"]
		var idx: PackedInt32Array = o["tris"]
		var tris := PackedVector3Array()
		for i in idx:
			if i >= 0 and i < verts.size():
				tris.append(xf * (verts[i] * unit_scale))
		if tris.size() % 3 != 0:
			tris.resize(tris.size() - tris.size() % 3)
		k += 1
		var nm := String(o["name"])
		if nm == "":
			nm = "%s %d" % [path.get_file().get_basename(), k]
		out_objects.append({"name": nm, "triangles": tris})
		all.append_array(tris)
	if all.is_empty():
		return {"ok": false, "error": "no mesh objects in %s" % path.get_file(), "triangles": all, "objects": []}
	return {"ok": true, "triangles": all, "name": String(out_objects[0]["name"]), "error": "",
		"objects": out_objects}


## 3MF transform attribute: 12 numbers, row-major 4x3 (m00 m01 m02 m10 …
## m30 m31 m32) — rows are the basis vectors, last row the translation.
static func _parse_3mf_transform(text: String) -> Transform3D:
	var p := text.strip_edges().split(" ", false)
	if p.size() != 12:
		return Transform3D.IDENTITY
	var v: Array = []
	for s in p:
		v.append(s.to_float())
	return Transform3D(Basis(Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]),
		Vector3(v[6], v[7], v[8])), Vector3(v[9], v[10], v[11]))


static func _format_3mf_transform(xf: Transform3D) -> String:
	var b := xf.basis
	var o := xf.origin
	return "%s %s %s %s %s %s %s %s %s %s %s %s" % [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z,
		b.z.x, b.z.y, b.z.z, o.x, o.y, o.z]


## --- writing ------------------------------------------------------------------

## Welded vertex/index arrays of a body mesh (1 µm grid), for indexed formats.
static func weld(mesh: ArrayMesh) -> Dictionary:
	var tris := StlExporter.mesh_triangles(mesh)
	var vid := {}
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in tris.size():
		var v := tris[i]
		var k := Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0))
		if not vid.has(k):
			vid[k] = verts.size()
			verts.append(v)
		idx.append(vid[k])
	# Drop degenerate triangles after welding.
	var clean := PackedInt32Array()
	for t in idx.size() / 3:
		var a := idx[t * 3]
		var b := idx[t * 3 + 1]
		var c := idx[t * 3 + 2]
		if a != b and b != c and a != c:
			clean.append_array([a, b, c])
	return {"vertices": verts, "indices": clean}


static func _xml_escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


## Write `bodies` ([{name, mesh, color?}]) to a 3MF at `path`. Units mm,
## one object per body, per-body colour through basematerials, build items
## at identity, optional PNG thumbnail bytes.
## -> {ok, objects, error}
static func write_3mf(bodies: Array, path: String, thumbnail_png: PackedByteArray = PackedByteArray(),
		title := "EchoCAD model") -> Dictionary:
	var objs: Array = []
	for b: Dictionary in bodies:
		var w := weld(b.get("mesh") as ArrayMesh)
		if (w["indices"] as PackedInt32Array).is_empty():
			continue
		objs.append({"name": String(b.get("name", "Body")), "verts": w["vertices"],
			"idx": w["indices"], "color": b.get("color", Color(0, 0, 0, 0))})
	if objs.is_empty():
		return {"ok": false, "objects": 0, "error": "nothing to export — no solid bodies"}
	var sb := PackedStringArray()
	sb.append('<?xml version="1.0" encoding="UTF-8"?>')
	sb.append('<model unit="millimeter" xml:lang="en-US" xmlns="%s" xmlns:m="%s">' % [NS_3MF, NS_MAT])
	sb.append('<metadata name="Title">%s</metadata>' % _xml_escape(title))
	sb.append('<metadata name="Application">EchoCAD</metadata>')
	sb.append('<resources>')
	# Materials: one base per body (default grey when unset).
	sb.append('<basematerials id="1">')
	for o: Dictionary in objs:
		var c: Color = o["color"]
		var col := c if c.a > 0.0 else Color(0.62, 0.6, 0.59, 1.0)
		col.a = 1.0
		sb.append('<base name="%s" displaycolor="#%s" />' % [_xml_escape(String(o["name"])), col.to_html(true).to_upper()])
	sb.append('</basematerials>')
	for i in objs.size():
		var o: Dictionary = objs[i]
		sb.append('<object id="%d" name="%s" type="model" pid="1" pindex="%d">' % [i + 2, _xml_escape(String(o["name"])), i])
		sb.append('<mesh><vertices>')
		var verts: PackedVector3Array = o["verts"]
		for v in verts:
			sb.append('<vertex x="%.6f" y="%.6f" z="%.6f" />' % [v.x, v.y, v.z])
		sb.append('</vertices><triangles>')
		var idx: PackedInt32Array = o["idx"]
		for t in idx.size() / 3:
			sb.append('<triangle v1="%d" v2="%d" v3="%d" />' % [idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]])
		sb.append('</triangles></mesh></object>')
	sb.append('</resources><build>')
	for i in objs.size():
		sb.append('<item objectid="%d" />' % (i + 2))
	sb.append('</build></model>')
	var model_xml := "\n".join(sb)
	var has_thumb := not thumbnail_png.is_empty()
	var rels := PackedStringArray()
	rels.append('<?xml version="1.0" encoding="UTF-8"?>')
	rels.append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
	rels.append('<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" />')
	if has_thumb:
		rels.append('<Relationship Target="/Metadata/thumbnail.png" Id="rel1" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" />')
	rels.append('</Relationships>')
	var types := PackedStringArray()
	types.append('<?xml version="1.0" encoding="UTF-8"?>')
	types.append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
	types.append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />')
	types.append('<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml" />')
	if has_thumb:
		types.append('<Default Extension="png" ContentType="image/png" />')
	types.append('</Types>')
	var zp := ZIPPacker.new()
	if zp.open(path) != OK:
		return {"ok": false, "objects": 0, "error": "cannot write %s" % path}
	for pair in [["[Content_Types].xml", "\n".join(types)], ["_rels/.rels", "\n".join(rels)],
			["3D/3dmodel.model", model_xml]]:
		zp.start_file(pair[0])
		zp.write_file((pair[1] as String).to_utf8_buffer())
		zp.close_file()
	if has_thumb:
		zp.start_file("Metadata/thumbnail.png")
		zp.write_file(thumbnail_png)
		zp.close_file()
	zp.close()
	return {"ok": true, "objects": objs.size(), "error": ""}


## Write `bodies` to a Wavefront OBJ (mm, one object per body, welded).
static func write_obj(bodies: Array, path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "objects": 0, "error": "cannot write %s" % path}
	f.store_line("# EchoCAD OBJ export (millimetres)")
	var base := 1
	var n := 0
	for b: Dictionary in bodies:
		var w := weld(b.get("mesh") as ArrayMesh)
		var verts: PackedVector3Array = w["vertices"]
		var idx: PackedInt32Array = w["indices"]
		if idx.is_empty():
			continue
		n += 1
		f.store_line("o %s" % String(b.get("name", "Body")).replace(" ", "_"))
		for v in verts:
			f.store_line("v %.6f %.6f %.6f" % [v.x, v.y, v.z])
		for t in idx.size() / 3:
			f.store_line("f %d %d %d" % [base + idx[t * 3], base + idx[t * 3 + 1], base + idx[t * 3 + 2]])
		base += verts.size()
	f.close()
	if n == 0:
		return {"ok": false, "objects": 0, "error": "nothing to export — no solid bodies"}
	return {"ok": true, "objects": n, "error": ""}
