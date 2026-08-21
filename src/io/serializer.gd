class_name Serializer
extends RefCounted
## .ecad file format: versioned, human-readable JSON. No runtime handles are
## ever serialized; save -> load -> save is byte-identical (dict key order is
## deterministic because to_dict/from_dict build keys in the same order).

static func to_json(doc: CadDocument) -> String:
	return JSON.stringify(doc.to_dict(), "\t") + "\n"


## Why the last from_json / load_file returned null ("" when it did not).
static var last_error := ""


static func from_json(text: String) -> CadDocument:
	last_error = ""
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		last_error = "not a valid .ecad file"
		push_error("[Serializer] not a valid .ecad file")
		return null
	if CadDocument.is_newer_schema(data as Dictionary):
		# M46: refuse instead of silently dropping what we do not understand.
		last_error = "this file was saved by a newer EchoCAD (schema %d, this build reads %d) — update the app" % [
			int((data as Dictionary).get("version", 1)), CadDocument.SCHEMA_VERSION]
		push_error("[Serializer] " + last_error)
		return null
	return CadDocument.from_dict(data as Dictionary)


static func save(doc: CadDocument, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[Serializer] cannot write %s: %s"
			% [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(to_json(doc))
	f.close()
	return true


static func load_file(path: String) -> CadDocument:
	if not FileAccess.file_exists(path):
		last_error = "no such file: %s" % path
		push_error("[Serializer] no such file: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	return from_json(text)
