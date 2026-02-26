extends RefCounted
class_name PathSelector

var library: PathLibrary = PathLibrary.new()
var active_model: PathModel = null
var active_direction: int = 1
var step_index: int = 0

func initialize(rng: RandomNumberGenerator) -> void:
	library.load_or_generate(rng)
	select_random(rng)

func select_random(rng: RandomNumberGenerator) -> void:
	active_model = library.get_random_model(rng)
	active_direction = -1 if rng.randf() < 0.5 else 1
	step_index = 0

func next_step() -> Dictionary:
	if active_model == null or active_model.steps.is_empty():
		return {}
	var idx: int = step_index % active_model.steps.size()
	var step: Dictionary = active_model.steps[idx]
	step_index += 1
	return step
