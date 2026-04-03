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


func apply_crumble_to_chunk(chunk: Dictionary, rng: RandomNumberGenerator) -> void:
	if chunk.is_empty():
		return
	var plats: Array = chunk.get("platforms", []) as Array
	if plats.is_empty():
		return
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.size() < 1:
		return
	var p_crumb: float = get_crumble_chance()
	var prev_was_crumble: bool = false
	for idx_variant in chain:
		var pi: int = int(idx_variant)
		if pi < 0 or pi >= plats.size():
			continue
		var slot: Dictionary = plats[pi] as Dictionary
		if bool(slot.get("is_decoy", false)):
			continue
		var force_normal: bool = prev_was_crumble
		if force_normal:
			slot["vanish"] = 0
			slot["kind"] = "normal"
			prev_was_crumble = false
			continue
		if rng.randf() < p_crumb:
			slot["vanish"] = 1
			slot["kind"] = "crumble"
			prev_was_crumble = true
		else:
			slot["vanish"] = 0
			slot["kind"] = "normal"
			prev_was_crumble = false
