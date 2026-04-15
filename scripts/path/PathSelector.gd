extends RefCounted
class_name PathSelector

var library: PathLibrary = PathLibrary.new()
var active_model: PathModel = null
var active_model_index: int = -1
var active_direction: int = 1
var step_index: int = 0

func initialize() -> void:
	library.load_all()
	select_model_for_run()

func select_model_for_run() -> void:
	active_model = null
	active_model_index = -1
	if library.size() == 0:
		return
	var sm: Node = _resolve_seed_manager()
	if sm == null:
		push_warning("PathSelector: SeedManager autoload missing")
		return
	var rng: RandomNumberGenerator = sm.call("get_rng_for", "path") as RandomNumberGenerator
	if rng == null:
		push_warning("PathSelector: SeedManager.get_rng_for returned null")
		return
	var idx: int = rng.randi_range(0, library.size() - 1)
	active_model = library.get_model_by_index(idx)
	active_model_index = idx
	if active_model != null:
		var gs: int = int(sm.get("global_seed"))
		active_direction = 1 if ((gs ^ int(active_model.model_id)) & 1) == 0 else -1
	step_index = 0

func _resolve_seed_manager() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).root.get_node_or_null("/root/SeedManager")
	return null

func next_step() -> Dictionary:
	if active_model == null or active_model.steps.is_empty():
		return {}
	var idx: int = step_index % active_model.steps.size()
	var step: Dictionary = active_model.steps[idx]
	step_index += 1
	return step
