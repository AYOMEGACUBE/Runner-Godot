extends RefCounted
class_name PathLibrary

const LIBRARY_FILE_PATH: String = "user://path_models_3301.json"
const MODEL_COUNT: int = 50
const WAVES_PER_MODEL: int = 10

var models: Array[PathModel] = []

func load_or_generate(rng: RandomNumberGenerator) -> void:
	if _load_from_disk():
		return
	_generate_models(rng)
	_save_to_disk()

func get_random_model(rng: RandomNumberGenerator) -> PathModel:
	if models.is_empty():
		return null
	return models[rng.randi_range(0, models.size() - 1)]

func _load_from_disk() -> bool:
	if not FileAccess.file_exists(LIBRARY_FILE_PATH):
		return false
	var f: FileAccess = FileAccess.open(LIBRARY_FILE_PATH, FileAccess.READ)
	if f == null:
		return false
	var raw: Variant = JSON.parse_string(f.get_as_text())
	if typeof(raw) != TYPE_ARRAY:
		return false
	models.clear()
	for m in raw:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		models.append(PathModel.from_dict(m))
	return models.size() == MODEL_COUNT

func _save_to_disk() -> void:
	var arr: Array = []
	for m in models:
		arr.append(m.to_dict())
	var f: FileAccess = FileAccess.open(LIBRARY_FILE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(arr))
	f.flush()

func _generate_models(rng: RandomNumberGenerator) -> void:
	models.clear()
	for i in range(MODEL_COUNT):
		models.append(_generate_single_model(i + 1, rng))

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
