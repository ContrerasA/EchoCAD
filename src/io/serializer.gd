class_name Serializer
extends RefCounted
## .ecad file format: versioned, human-readable JSON. No runtime handles are
## ever serialized; save -> load -> save is byte-identical (dict key order is
## deterministic because to_dict/from_dict build keys in the same order).

static func to_json(doc: CadDocument) -> String:
	return JSON.stringify(doc.to_dict(), "\t") + "\n"


static func from_json(text: String) -> CadDocument:
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		push_error("[Serializer] not a valid .ecad file")
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
		push_error("[Serializer] no such file: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	return from_json(text)
