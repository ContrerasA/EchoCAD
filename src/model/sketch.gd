class_name Sketch
extends RefCounted
## The entity + constraint store of one sketch feature. Pure data with
## ordered, id-addressed access; NO solver or render logic. Ids ("e<n>") are
## minted here and never reused, so undo/redo and constraint refs stay valid
## across any edit history.

var constraints: Array[SketchConstraint] = []

var _order: Array[String] = []
var _by_id := {}
var _id_counter := 0
## Entity id of this sketch's origin point. Every sketch owns one, minted at
## construction, so geometry can be dimensioned and constrained RELATIVE to the
## origin the way Fusion allows — without it nothing can ever reach "fully
## constrained", because there is no fixed thing to measure from. It is a real
## SketchPoint (snappable, selectable, a solver variable like any other) that
## the solver always pins and that `remove` refuses to delete.
var _origin_id := ""


func _init() -> void:
	var o := SketchPoint.make(Vector2.ZERO)
	o.id = next_id()
	_origin_id = o.id
	add(o)


func next_id() -> String:
	_id_counter += 1
	return "e%d" % _id_counter


## The sketch origin's entity id — a point at (0,0) that always exists.
func origin_id() -> String:
	return _origin_id


func is_origin(entity_id: String) -> bool:
	return entity_id != "" and entity_id == _origin_id


## Add an entity (id already minted via next_id). `at` = -1 appends;
## otherwise inserts at that index (undo restores original positions).
func add(e: SketchEntity, at := -1) -> void:
	if e.id == "" or _by_id.has(e.id):
		push_error("[Sketch] add: bad or duplicate id '%s'" % e.id)
		return
	_by_id[e.id] = e
	if at < 0 or at >= _order.size():
		_order.append(e.id)
	else:
		_order.insert(at, e.id)


func remove(entity_id: String) -> SketchEntity:
	if is_origin(entity_id):
		return null   # the origin is part of the sketch, not content in it
	if not _by_id.has(entity_id):
		return null
	var e: SketchEntity = _by_id[entity_id]
	_by_id.erase(entity_id)
	_order.erase(entity_id)
	return e


func has(entity_id: String) -> bool:
	return _by_id.has(entity_id)


func entity(entity_id: String) -> SketchEntity:
	return _by_id.get(entity_id)


func point(entity_id: String) -> SketchPoint:
	return _by_id.get(entity_id) as SketchPoint


func index_of(entity_id: String) -> int:
	return _order.find(entity_id)


func entity_ids() -> Array[String]:
	return _order.duplicate()


func entities() -> Array[SketchEntity]:
	var out: Array[SketchEntity] = []
	for id in _order:
		out.append(_by_id[id])
	return out


func size() -> int:
	return _order.size()


## Every constraint that references any of `ids` (a Dictionary set or Array).
func constraints_referencing(ids) -> Array[SketchConstraint]:
	var set := {}
	if ids is Dictionary:
		set = ids
	else:
		for i in ids:
			set[i] = true
	var out: Array[SketchConstraint] = []
	for c in constraints:
		if c.references_any(set):
			out.append(c)
	return out


## Remove every constraint referencing any of `ids`; returns the removed
## constraints (callers keep them for undo, in the same undo step as the
## entity deletion).
func prune_constraints_for(ids) -> Array[SketchConstraint]:
	var doomed := constraints_referencing(ids)
	for c in doomed:
		constraints.erase(c)
	return doomed


func to_dict() -> Dictionary:
	var ents: Array = []
	for e in entities():
		ents.append(e.to_dict())
	var cons: Array = []
	for c in constraints:
		cons.append(c.to_dict())
	return {"id_counter": _id_counter, "entities": ents, "constraints": cons,
		"origin": _origin_id}


static func from_dict(d: Dictionary) -> Sketch:
	var s := Sketch.new()
	# _init already minted an origin; the file carries its own entity list, so
	# clear that provisional state and rebuild from disk.
	s._order.clear()
	s._by_id.clear()
	s._origin_id = ""
	s._id_counter = int(d.get("id_counter", 0))
	for ed in d.get("entities", []):
		var e := entity_from_dict(ed as Dictionary)
		if e != null:
			s.add(e)
	for cd in d.get("constraints", []):
		s.constraints.append(SketchConstraint.from_dict(cd as Dictionary))
	var origin := String(d.get("origin", ""))
	if origin != "" and s.has(origin):
		s._origin_id = origin
	else:
		# Written before sketches had an origin (or the id went missing).
		# Mint one now so old documents gain the same capability as new ones.
		var o := SketchPoint.make(Vector2.ZERO)
		o.id = s.next_id()
		s._origin_id = o.id
		s.add(o)
	return s


static func entity_from_dict(d: Dictionary) -> SketchEntity:
	match String(d.get("kind", "")):
		"point":
			return SketchPoint.from_dict(d)
		"line":
			return SketchLine.from_dict(d)
		"arc":
			return SketchArc.from_dict(d)
		"circle":
			return SketchCircle.from_dict(d)
		"spline":
			return SketchSpline.from_dict(d)
	push_error("[Sketch] unknown entity kind in file: %s" % String(d.get("kind", "?")))
	return null
