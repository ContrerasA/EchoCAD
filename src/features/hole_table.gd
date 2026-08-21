class_name HoleTable
extends RefCounted
## M40 — standard hole sizes (mm). Built-in tables ship in
## `res://data/holes.json`; `user://holes/*.json` files with the same shape
## add or shadow entries by id. Everything the wizard offers as a preset
## comes from here; Custom is always available.

const BUILTIN := "res://data/holes.json"

static var _entries: Array = []      # [{id, family, major, pitch, close, normal, loose, cbore:[d, depth], csink}]
static var _loaded := false


static func entries() -> Array:
	if not _loaded:
		reload()
	return _entries


static func reload() -> void:
	_entries = []
	_merge_file(BUILTIN)
	var dir := DirAccess.open("user://holes")
	if dir != null:
		for f in dir.get_files():
			if f.get_extension().to_lower() == "json":
				_merge_file("user://holes/" + f)
	_loaded = true


static func _merge_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		push_warning("[HoleTable] %s: not a JSON object" % path)
		return
	for family in ["metric", "unified"]:
		for row in (data as Dictionary).get(family, []):
			if not (row is Dictionary) or not (row as Dictionary).has("id"):
				continue
			var e: Dictionary = (row as Dictionary).duplicate()
			e["family"] = family
			var replaced := false
			for i in _entries.size():
				if String((_entries[i] as Dictionary)["id"]) == String(e["id"]):
					_entries[i] = e
					replaced = true
			if not replaced:
				_entries.append(e)


static func find(id: String) -> Dictionary:
	for e: Dictionary in entries():
		if String(e["id"]) == id:
			return e
	return {}


## Tap drill (minor) diameter for a thread: major − 1.0825·pitch (ISO 60°).
static func tap_drill(e: Dictionary) -> float:
	return float(e["major"]) - 1.0825 * float(e["pitch"])


## Preset ids for the wizard's Size dropdown, grouped per family.
static func preset_labels() -> Array:
	var out: Array = []
	for e: Dictionary in entries():
		out.append(String(e["id"]))
	return out
