extends RefCounted
class_name PlatformSpawner
## Инстансинг платформ колена через существующую Platform.tscn (StaticBody2D + Platform.gd).
## Crumble назначается процедурно по высоте (не из JSON слота).

const TILE_W: float = 64.0
const TILE_H: float = 64.0
const PLATFORM_HEIGHT_LEVELS: int = 7
const PLATFORM_LEVEL_HEIGHTS: Array[int] = [1000, 5000, 10000, 20000, 50000, 100000, 200000]

var _platform_scene: PackedScene = preload("res://scenes/platform/Platform.tscn")
var _platform_store: PlatformDataStore = PlatformDataStore.new()
var _platform_store_loaded: bool = false
var _slot_index_by_level: Dictionary = {}


## Прогресс по вертикали относительно старта забега; шанс crumble линейно 5% → 90%.
static func crumble_probability_at_y(platform_y: float, run_start_y: float) -> float:
	var max_h: float = float(WorldSegmentGrid.FACE_AXIS_PX)
	var progress: float = (run_start_y - platform_y) / maxf(1.0, max_h)
	progress = clampf(progress, 0.0, 1.0)
	return lerpf(0.05, 0.90, progress)


func spawn_leg(chunks: Array, parent: Node, run_start_y: float, rng: RandomNumberGenerator) -> Node2D:
	if not _platform_store_loaded:
		_platform_store.load_from_file()
		_platform_store_loaded = true
	var leg_root: Node2D = Node2D.new()
	leg_root.name = "LegContainer"
	parent.add_child(leg_root)
	for ch_variant in chunks:
		if typeof(ch_variant) != TYPE_DICTIONARY:
			continue
		var chunk: Dictionary = ch_variant as Dictionary
		var plats: Array = chunk.get("platforms", []) as Array
		# Platforms on support_chain are the "intended" path. They must not crumble,
		# otherwise the run can produce unavoidable falls that look like impossible gaps.
		var chain: Array = chunk.get("support_chain_indices", []) as Array
		for idx_var in chain:
			var pi: int = int(idx_var)
			if pi >= 0 and pi < plats.size() and typeof(plats[pi]) == TYPE_DICTIONARY:
				(plats[pi] as Dictionary)["__support_chain"] = true
		var sorted: Array = plats.duplicate()
		sorted.sort_custom(func(a: Variant, b: Variant) -> bool:
			return int((a as Dictionary).get("order", 0)) < int((b as Dictionary).get("order", 0))
		)
		for p_variant in sorted:
			if typeof(p_variant) != TYPE_DICTIONARY:
				continue
			var slot: Dictionary = p_variant as Dictionary
			var node: Node2D = _platform_scene.instantiate() as Node2D
			if node == null:
				continue
			leg_root.add_child(node)
			_apply_slot(node, slot, run_start_y, rng)
	return leg_root


func _apply_slot(p: Node2D, slot: Dictionary, run_start_y: float, rng: RandomNumberGenerator) -> void:
	var pos: Vector2 = Vector2(float(slot.get("x", 0.0)), float(slot.get("y", 0.0)))
	var seg: int = maxi(1, int(slot.get("segments", 1)))
	var kind: String = str(slot.get("kind", "")).to_lower()
	var decoy: bool = bool(slot.get("is_decoy", false)) or kind == "decoy"
	var is_support_chain: bool = bool(slot.get("__support_chain", false))
	p.global_position = pos
	p.scale = Vector2(float(seg), 1.0)
	p.set("suppress_auto_coin", true)
	p.set("coin_spawn_chance", 0.0)
	p.set("size", Vector2(TILE_W, TILE_H))
	p.set("is_decoy", decoy)
	p.set("fake_visual_only", decoy)
	if decoy:
		p.set("is_crumbling", false)
	elif is_support_chain:
		p.set("is_crumbling", false)
	else:
		var p_crumb: float = crumble_probability_at_y(pos.y, run_start_y)
		p.set("is_crumbling", rng.randf() < p_crumb)
	if p.has_method("apply_size_to_shape"):
		p.call("apply_size_to_shape")
	var cs: Node = p.get_node_or_null("CollisionShape2D")
	if cs is CollisionShape2D:
		if decoy:
			(cs as CollisionShape2D).disabled = true
		else:
			(cs as CollisionShape2D).disabled = false
	if decoy:
		p.set_collision_layer_value(1, false)
		p.set_collision_mask_value(1, false)
	else:
		p.set_collision_layer_value(1, true)
		p.set_collision_mask_value(1, true)
	_apply_purchase_override(p, pos, run_start_y)


func _height_level_for_platform_y(pos_y: float, run_start_y: float) -> int:
	var climb: float = maxf(0.0, run_start_y - pos_y)
	var thresholds: Array = PLATFORM_LEVEL_HEIGHTS
	var lvl: int = 1
	for i in range(thresholds.size()):
		if climb >= float(thresholds[i]):
			lvl = i + 1
	return clampi(lvl, 1, PLATFORM_HEIGHT_LEVELS)


func _next_platform_id_for_height(pos_y: float, run_start_y: float) -> String:
	var lvl: int = _height_level_for_platform_y(pos_y, run_start_y)
	var idx: int = int(_slot_index_by_level.get(lvl, 0))
	_slot_index_by_level[lvl] = idx + 1
	return "h%d_slot_%d" % [lvl, idx]


func _apply_purchase_override(p: Node2D, pos: Vector2, run_start_y: float) -> void:
	var pid: String = _next_platform_id_for_height(pos.y, run_start_y)
	p.set_meta("__platform_purchase_id", pid)
	if not _platform_store.platforms.has(pid):
		return
	var rec: Dictionary = _platform_store.get_platform(pid)
	var owner: String = str(rec.get("owner_uid", "")).strip_edges()
	if owner == "":
		return
	var exp: int = int(rec.get("expires_at_timestamp", 0))
	if exp > 0 and exp <= int(Time.get_unix_time_from_system()):
		return
	# Keep streaming-generated physics as-is; apply purchased visuals only.
	var up_path: String = str(rec.get("jump_image_up_path", rec.get("image_path", ""))).strip_edges()
	var down_path: String = str(rec.get("jump_image_down_path", rec.get("image_path", ""))).strip_edges()
	if p.has_method("set_runtime_images"):
		p.call("set_runtime_images", up_path, down_path)
