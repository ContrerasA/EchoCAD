class_name ThreadedSolver
extends Node
## Runs ConstraintSolver.solve on a worker thread so a heavy drag re-solve
## cannot stutter the UI (M16, echo_vector's approach). The solver is static
## and pure — it reads a Sketch and returns proposed moves — which is exactly
## the shape this needs: the main thread SNAPSHOTS the sketch (to_dict) at
## request time, the worker solves the snapshot, and the main thread polls
## `take_result` once per frame and applies what lands.
##
## Only the NEWEST request matters. Each request bumps a generation counter;
## the worker always picks up the latest job, and a result whose generation
## is no longer current is dropped, never applied — a gesture that outruns
## the solver simply skips the intermediate states. Correctness at gesture
## end is not this class's job: the drag finishes with one synchronous solve
## before its undo batch seals (see SelectTool.pointer_up).

var _thread: Thread = null
var _sem := Semaphore.new()
var _mutex := Mutex.new()
var _exit := false
var _busy := false
var _gen := 0
var _job := {}      # {gen, sketch_id, dict, pinned}
var _result := {}   # {gen, sketch_id, points, radii}


func _ready() -> void:
	_thread = Thread.new()
	_thread.start(_worker)


func _exit_tree() -> void:
	_mutex.lock()
	_exit = true
	_mutex.unlock()
	_sem.post()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


func available() -> bool:
	return _thread != null and _thread.is_started()


## Queue a solve of `sk` (snapshotted HERE, on the calling thread) with
## `pinned` point ids held fixed. Supersedes any earlier request.
func request(sketch_id: String, sk: Sketch, pinned = []) -> void:
	var snap := sk.to_dict()
	var pins: Array = []
	for p in pinned:
		pins.append(String(p))
	_mutex.lock()
	_gen += 1
	_job = {"gen": _gen, "sketch_id": sketch_id, "dict": snap, "pinned": pins}
	_result = {}   # anything already computed is for an older state
	_mutex.unlock()
	_sem.post()


## Drop any queued job and any un-taken result (gesture over / cancelled).
func cancel() -> void:
	_mutex.lock()
	_gen += 1
	_job = {}
	_result = {}
	_mutex.unlock()


## True while a job is queued or being solved.
func busy() -> bool:
	_mutex.lock()
	var b := _busy or not _job.is_empty()
	_mutex.unlock()
	return b


## The newest finished result, or {} when there is none — results computed
## for anything but the CURRENT generation have already been dropped.
## -> {gen, sketch_id, points: {id: Vector2}, radii: {id: float}}
func take_result() -> Dictionary:
	_mutex.lock()
	var out := {}
	if not _result.is_empty() and int(_result["gen"]) == _gen:
		out = _result
	_result = {}
	_mutex.unlock()
	return out


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _exit:
			_mutex.unlock()
			return
		var job := _job
		_job = {}
		_busy = not job.is_empty()
		_mutex.unlock()
		if job.is_empty():
			continue
		# Pure work on a private copy — no shared mutable state to guard.
		var sk := Sketch.from_dict(job["dict"] as Dictionary)
		var res := ConstraintSolver.solve(sk, job["pinned"])
		_mutex.lock()
		# Stale results die here: a newer request has moved the goalposts.
		if int(job["gen"]) == _gen:
			_result = {"gen": job["gen"], "sketch_id": job["sketch_id"],
				"points": res["points"], "radii": res["radii"]}
		_busy = false
		_mutex.unlock()
