class_name CadDocument
extends RefCounted
## The document: an ordered feature list (the timeline), a rollback marker,
## and named parameters. All geometry numbers are CANONICAL MILLIMETRES;
## `display_unit` is only what the UI shows. Mutations happen only through
## commands on the CommandStack.

const SCHEMA_VERSION := 1

var features: Array[Feature] = []
## Features[0..timeline_marker) are computed/visible; the rest are rolled
## back. Default = features.size() (everything live).
var timeline_marker := 0
var parameters: Array[CadParameter] = []
var display_unit := UnitConverter.Unit.IN

var _feature_counter := 0


func next_feature_id() -> String:
	_feature_counter += 1
	return "f%d" % _feature_counter


func feature_by_id(fid: String) -> Feature:
	for f in features:
		if f.id == fid:
			return f
	return null


func sketch_feature(fid: String) -> SketchFeature:
	return feature_by_id(fid) as SketchFeature


## Features up to the rollback marker, skipping suppressed — what replay,
## rendering, and profile detection walk.
func live_features() -> Array[Feature]:
	var out: Array[Feature] = []
	for i in range(mini(timeline_marker, features.size())):
		if not features[i].suppressed:
			out.append(features[i])
	return out


## Next automatic name for a feature kind: "Sketch1", "Sketch2", ...
func auto_name(kind_label: String) -> String:
	var n := 1
	for f in features:
		if f.name.begins_with(kind_label):
			var tail := f.name.trim_prefix(kind_label)
			if tail.is_valid_int():
				n = maxi(n, tail.to_int() + 1)
	return "%s%d" % [kind_label, n]


func to_dict() -> Dictionary:
	var feats: Array = []
	for f in features:
		feats.append(f.to_dict())
	var params: Array = []
	for p in parameters:
		params.append(p.to_dict())
	return {
		"app": "EchoCAD",
		"version": SCHEMA_VERSION,
		"display_unit": UnitConverter.unit_to_string(display_unit),
		"feature_counter": _feature_counter,
		"timeline_marker": timeline_marker,
		"parameters": params,
		"features": feats,
	}


static func from_dict(d: Dictionary) -> CadDocument:
	var on_disk := int(d.get("version", 1))
	_migrate(on_disk, d)
	var doc := CadDocument.new()
	doc.display_unit = UnitConverter.unit_from_string(
		String(d.get("display_unit", "in")), UnitConverter.Unit.IN)
	doc._feature_counter = int(d.get("feature_counter", 0))
	for fd in d.get("features", []):
		var f := feature_from_dict(fd as Dictionary)
		if f != null:
			doc.features.append(f)
	doc.timeline_marker = clampi(
		int(d.get("timeline_marker", doc.features.size())), 0, doc.features.size())
	for pd in d.get("parameters", []):
		doc.parameters.append(CadParameter.from_dict(pd as Dictionary))
	return doc


static func feature_from_dict(d: Dictionary) -> Feature:
	match String(d.get("kind", "")):
		"sketch":
			return SketchFeature.from_dict(d)
	push_error("[CadDocument] unknown feature kind in file: %s"
		% String(d.get("kind", "?")))
	return null


## Cumulative in-place migration of `d` from `on_disk` version to
## SCHEMA_VERSION. Always runs before field reads; each future version adds
## its step here and never edits earlier ones.
static func _migrate(on_disk: int, _d: Dictionary) -> void:
	if on_disk > SCHEMA_VERSION:
		push_warning("[CadDocument] file version %d is newer than app schema %d"
			% [on_disk, SCHEMA_VERSION])
	# v1 -> v2: (next schema bump's step goes here)
