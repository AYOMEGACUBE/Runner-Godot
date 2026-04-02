extends RefCounted
class_name PathLibrary

const MODEL_COUNT: int = 50
const RES_LIBRARY_PATH: String = "res://DATA/PulseRunnerData/path_library_50.json"
const WAVES_PER_MODEL: int = 10
const BUILTIN_SEED: int = 3301

var models: Array[PathModel] = []

func load_all() -> void:
	models.clear()
	if _try_load_json(RES_LIBRARY_PATH):
		if models.size() > 0:
			if models.size() < MODEL_COUNT:
				push_warning("PathLibrary: loaded %d models (expected %d); random run picks within loaded set" % [models.size(), MODEL_COUNT])
			return
	_build_models_deterministic(BUILTIN_SEED)

func _try_load_json(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var raw: Variant = JSON.parse_string(f.get_as_text())
	if typeof(raw) != TYPE_ARRAY:
		return false
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		models.append(PathModel.from_dict(item))
	return models.size() > 0

## Детерминированная сборка 50 моделей без скрытого rand: фиксированный seed в RNG только здесь для офлайн-эквивалента библиотеки.
func _build_models_deterministic(seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	models.clear()
	for mid in range(1, MODEL_COUNT + 1):
		models.append(_generate_single_model(mid, rng))

func _generate_single_model(new_id: int, rng: RandomNumberGenerator) -> PathModel:
	var model: PathModel = PathModel.new()
	model.model_id = new_id
	model.trend_degrees = 2.0
	var base_rise_per_step: float = -8.0
	var x_gap_min: float = 140.0
	var x_gap_max: float = 260.0
	for wave_id in range(WAVES_PER_MODEL):
		var wave_steps: int = rng.randi_range(7, 13)
		var phase: float = rng.randf_range(0.1, 1.2)
		var amp_up: float = rng.randf_range(16.0, 42.0)
		var amp_down: float = rng.randf_range(10.0, 38.0)
		var skew: float = rng.randf_range(0.65, 1.55)
		var decoy_count: int = rng.randi_range(1, 3)
		for local_idx in range(wave_steps):
			var t: float = float(local_idx) / max(1.0, float(wave_steps - 1))
			var shaped_t: float = pow(t, skew)
			var wave_val: float = sin((shaped_t + phase) * TAU)
			var local_delta: float = 0.0
			if wave_val >= 0.0:
				local_delta = amp_up * wave_val
			else:
				local_delta = amp_down * wave_val
			var y_delta: float = base_rise_per_step + local_delta
			model.steps.append({
				"x_gap": rng.randf_range(x_gap_min, x_gap_max),
				"y_delta": y_delta,
				"wave_id": wave_id,
				"decoy_count": decoy_count,
			})
	return model

func get_model_by_index(i: int) -> PathModel:
	if i < 0 or i >= models.size():
		return null
	return models[i]

func size() -> int:
	return models.size()
