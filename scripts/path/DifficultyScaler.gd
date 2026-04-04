extends RefCounted
class_name DifficultyScaler
## Прогрессия crumble 5% → 50% по высоте; запрет двух crumble подряд в support_chain.

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")

@export var total_wall_height_px: float = float(WorldSegmentGrid.FACE_AXIS_PX)
@export var crumble_chance_min: float = 0.05
@export var crumble_chance_max: float = 0.50

var global_path_height: float = 0.0


func get_crumble_chance() -> float:
	var progress: float = clampf(global_path_height / maxf(1.0, total_wall_height_px), 0.0, 1.0)
	return lerpf(crumble_chance_min, crumble_chance_max, progress)


func apply_crumble_to_chunk(_chunk: Dictionary, _rng: RandomNumberGenerator) -> void:
	## Устарело: crumble с платформ снимается из данных чанка; шанс задаётся в PlatformSpawner
	## по высоте (crumble_probability_at_y). Оставлено пустым для совместимости вызовов.
	pass
