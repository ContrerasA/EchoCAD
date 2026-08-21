class_name CombineFeature
extends Feature
## M42 — boolean between EXISTING bodies: target ∪/−/∩ tools. Tools are
## consumed unless `keep_tools`. Replaces the "sketch a cutter" detour.

var target := ""
var tools: Array = []          # body ids
var operation := SolidFeature.OP_JOIN
var keep_tools := false


func kind() -> String:
	return "combine"


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["target"] = target
	d["tools"] = tools.duplicate()
	d["operation"] = operation
	d["keep_tools"] = keep_tools
	return d


static func from_dict(d: Dictionary) -> CombineFeature:
	var f := CombineFeature.new()
	f._read_base(d)
	f.target = String(d.get("target", ""))
	f.tools = []
	for t in (d.get("tools", []) as Array):
		f.tools.append(String(t))
	f.operation = String(d.get("operation", SolidFeature.OP_JOIN))
	f.keep_tools = bool(d.get("keep_tools", false))
	return f
