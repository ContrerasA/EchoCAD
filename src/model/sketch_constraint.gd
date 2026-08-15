class_name SketchConstraint
extends RefCounted
## One constraint between sketch entities. Vocabulary ported from
## echo_vector's EVConstraint; refs are simply ENTITY IDS because every
## endpoint/center is a real SketchPoint entity (no {node, sub, anchor}
## indirection needed).
##
## Operand conventions per type (entity ids, in order):
##   COINCIDENT      [point, point]
##   VERTICAL        [line]  (or [point, point] — same X)
##   HORIZONTAL      [line]  (or [point, point] — same Y)
##   PARALLEL        [line, line]
##   PERPENDICULAR   [line, line]
##   COLLINEAR       [line, line]
##   EQUAL           [line|arc|circle, line|arc|circle]  (length / radius)
##   MIDPOINT        [point, line]
##   CONCENTRIC      [arc|circle, arc|circle]
##   TANGENT         [line|arc|circle, arc|circle]
##   POINT_ON        [point, line|arc|circle]
##   FIX             [point|line|arc|circle]
##   SYMMETRY        [point, point, line]  (axis last)
##   DISTANCE        [point, point]              value mm
##   DIST_X          [point, point]              value mm
##   DIST_Y          [point, point]              value mm
##   ANGLE           [line, line]                value degrees
##   RADIUS          [arc|circle]                value mm
##   DIAMETER        [arc|circle]                value mm
##   LINE_DIST       [line, line]                value mm (parallel gap)
##   POINT_LINE_DIST [point, line]               value mm
##
## A constraint referencing a deleted entity is pruned by the delete command
## in the same undo step (Sketch.prune_constraints_for).

enum Type {
	COINCIDENT, VERTICAL, HORIZONTAL, PARALLEL, PERPENDICULAR, COLLINEAR,
	EQUAL, MIDPOINT, CONCENTRIC, TANGENT, POINT_ON, FIX, SYMMETRY,
	DISTANCE, DIST_X, DIST_Y, ANGLE, RADIUS, DIAMETER, LINE_DIST,
	POINT_LINE_DIST,
}

const DIMENSIONAL := [Type.DISTANCE, Type.DIST_X, Type.DIST_Y, Type.ANGLE,
	Type.RADIUS, Type.DIAMETER, Type.LINE_DIST, Type.POINT_LINE_DIST]

var type: Type = Type.COINCIDENT
var operands: Array[String] = []
## Target value for dimensional types: canonical mm (degrees for ANGLE).
var value := 0.0
## Reference dimension: measures instead of drives.
var driven := false
## Expression source text ("" = plain value) + the unit space it was typed in.
var expr: String = ""
var expr_unit: int = CadParameter.UNIT_SCALAR
## Parked offset of the dimension label from its anchor, sketch mm.
var label_offset := Vector2.ZERO


static func make(t: Type, ops: Array[String], v := 0.0) -> SketchConstraint:
	var c := SketchConstraint.new()
	c.type = t
	c.operands = ops
	c.value = v
	return c


func is_dimensional() -> bool:
	return DIMENSIONAL.has(type)


func references(entity_id: String) -> bool:
	return operands.has(entity_id)


func references_any(ids: Dictionary) -> bool:
	for op in operands:
		if ids.has(op):
			return true
	return false


func duplicate_constraint() -> SketchConstraint:
	var c := SketchConstraint.new()
	c.type = type
	c.operands = operands.duplicate()
	c.value = value
	c.driven = driven
	c.expr = expr
	c.expr_unit = expr_unit
	c.label_offset = label_offset
	return c


func to_dict() -> Dictionary:
	var d := {"type": Type.keys()[type], "operands": Array(operands)}
	if is_dimensional():
		d["value"] = value
		if driven:
			d["driven"] = true
		if expr != "":
			d["expr"] = expr
			d["expr_unit"] = expr_unit
		if label_offset != Vector2.ZERO:
			d["label_offset"] = [label_offset.x, label_offset.y]
	return d


static func from_dict(d: Dictionary) -> SketchConstraint:
	var c := SketchConstraint.new()
	var tname := String(d.get("type", "COINCIDENT"))
	var idx := (Type.keys() as Array).find(tname)
	c.type = (idx if idx >= 0 else Type.COINCIDENT) as Type
	for op in d.get("operands", []):
		c.operands.append(String(op))
	c.value = float(d.get("value", 0.0))
	c.driven = bool(d.get("driven", false))
	c.expr = String(d.get("expr", ""))
	c.expr_unit = int(d.get("expr_unit", CadParameter.UNIT_SCALAR))
	var lo: Array = d.get("label_offset", [0.0, 0.0])
	c.label_offset = Vector2(float(lo[0]), float(lo[1]))
	return c
