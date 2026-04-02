extends RefCounted
class_name PathGenerator

## Офлайн-утилита (полилинии). Не используется рантайм-уровнем Level. Для детерминизма задайте seed в params.

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _init() -> void:
	_rng.seed = 1

func generate_path(params: Dictionary) -> Array:
	if params.has("seed"):
		_rng.seed = int(params["seed"]) & 0x7FFFFFFF
		if _rng.seed == 0:
			_rng.seed = 1
	var length_px: float = float(params.get("length_px", 147560.0))
	var angle_deg: float = float(params.get("angle_deg", 5.0))
	var step_min: float = float(params.get("step_min", 120.0))
	var step_max: float = float(params.get("step_max", 180.0))
	var wave_amp_min: float = float(params.get("wave_amp_min", 50.0))
	var wave_amp_max: float = float(params.get("wave_amp_max", 150.0))
	
	if step_min > step_max:
		var step_tmp: float = step_min
		step_min = step_max
		step_max = step_tmp
	
	if wave_amp_min > wave_amp_max:
		var wave_tmp: float = wave_amp_min
		wave_amp_min = wave_amp_max
		wave_amp_max = wave_tmp
	
	var points: Array = []
	var start_x: float = 0.0
	var start_y: float = 500.0
	var x: float = start_x
	var angle_rad: float = deg_to_rad(angle_deg)
	
	points.append([start_x, start_y])
	
	while x < length_px:
		var step_x: float = _rng.randf_range(step_min, step_max)
		x += step_x
		
		var base_y: float = start_y - tan(angle_rad) * x
		var wave_amp: float = _rng.randf_range(wave_amp_min, wave_amp_max)
		var wave: float = sin(x * 0.005) * wave_amp
		var variation: float = _rng.randf_range(-10.0, 10.0)
		var y: float = base_y + wave + variation
		
		points.append([x, y])
	
	return points
