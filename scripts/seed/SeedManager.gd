extends Node
## Централизованные потоки RNG. Ядро уровня использует только SeedManager.

signal seed_changed(new_seed: int)
signal lock_changed(locked: bool)

var global_seed: int = 0
var seed_assigned: bool = false
var _locked: bool = false
var _streams: Dictionary = {} # String -> RandomNumberGenerator

func _ready() -> void:
	ensure_seed()

func ensure_seed() -> void:
	if seed_assigned:
		return
	global_seed = int(hash(str(Time.get_unix_time_from_system()) + str(Time.get_ticks_usec()))) & 0x7FFFFFFF
	if global_seed == 0:
		global_seed = 3301
	seed_assigned = true
	_streams.clear()
	seed_changed.emit(global_seed)

func assign_run_seed(p_seed: int) -> void:
	if _locked:
		push_warning("SeedManager: seed locked, assign_run_seed ignored")
		return
	global_seed = int(p_seed)
	seed_assigned = true
	_streams.clear()
	seed_changed.emit(global_seed)

func lock_seed(locked: bool) -> void:
	_locked = locked
	lock_changed.emit(_locked)

func is_seed_locked() -> bool:
	return _locked

func get_rng_for(key: String) -> RandomNumberGenerator:
	if not seed_assigned:
		ensure_seed()
	if _streams.has(key):
		return _streams[key]
	var rng := RandomNumberGenerator.new()
	var sub: int = int(hash(str(global_seed) + "::" + key)) & 0x7FFFFFFF
	if sub == 0:
		sub = 1
	rng.seed = sub as int
	_streams[key] = rng
	return rng

func reset_streams() -> void:
	_streams.clear()
