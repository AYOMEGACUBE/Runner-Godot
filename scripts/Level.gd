extends Node2D

@onready var player: CharacterBody2D = $Player
@onready var platforms_root: Node2D = $Platforms

var platform_scene: PackedScene = preload("res://Platform.tscn")
var coin_scene: PackedScene = preload("res://Coin.tscn")
const RunDebugOverlayScript = preload("res://scripts/debug/RunDebugOverlay.gd")

@export var DEBUG_LOG: bool = true
@export var show_run_debug_overlay: bool = false

var rules: Dictionary = {}

var viewport_width: float = 0.0
var viewport_height: float = 0.0
var world_left: float = 0.0
var world_right: float = 0.0

var corridor_min_x: float = 0.0
var corridor_max_x: float = 0.0
var corridor_height: float = 0.0

var active_corridor_index: int = 0
var active_corridor: Dictionary = {}

var platforms: Array[Node2D] = []
var platform_corridor_index: Dictionary = {}

var path_selector: PathSelector = null
var platform_pool: PlatformPool = null

var _active_layout: PathModel = null
var _fallback_snapshot: PathModel = null
var _layout_index: int = 0

var _debug_log_frame_counter: int = 0
var _tile_width: float = 64.0
var _platform_height: float = 64.0
var _min_edge_gap: float = 32.0
var _vertical_gap: float = 0.0
var _spawn_ahead_px: float = 480.0
var _release_below_px: float = 900.0
var _initial_spawn_target: int = 36
var _max_spawns_per_frame: int = 4
var _coin_spawn_chance: float = 0.3
var _max_visible_platforms: int = 7
var _fps_spawn_threshold: float = 50.0
var _coin_height_offset: float = 80.0

var last_main_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	PhysicsConfig.calculate_jump_metrics()
	SeedManager.ensure_seed()
	SeedManager.lock_seed(true)

	if not DataManager.is_data_ready:
		await DataManager.load_completed

	rules = DataManager.rules_data.duplicate(true)
	if not _validate_rules(rules):
		push_error("Level.gd: platform_rules.json invalid or incomplete")
		return

	_apply_rules_to_fields(rules)

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	viewport_width = viewport_size.x
	viewport_height = viewport_size.y

	world_left = 0.0
	if bool(rules["use_fixed_world_width"]):
		world_right = world_left + max(0.0, float(rules["fixed_world_width"]))
	elif int(rules["world_screens"]) > 0:
		world_right = world_left + max(1, int(rules["world_screens"])) * viewport_width
	else:
		var seg_min: float = float(rules["world_segment_minutes"]) * 60.0
		world_right = world_left + PhysicsConfig.MOVE_SPEED * seg_min

	corridor_height = max(1.0, floor(viewport_height * float(rules["corridor_height_multiplier"])))

	var ox: float = float(rules["player_spawn_offset_x"])
	var oy: float = float(rules["player_spawn_offset_y"])
	var start_x: float = clamp(world_left + ox, world_left + _tile_width, world_right - _tile_width)
	var start_y: float = viewport_height - oy
	if player:
		player.global_position = Vector2(start_x, start_y)
	else:
		push_error("Level.gd: player node not found at $Player")
		return

	corridor_min_x = world_left
	corridor_max_x = world_right

	var first_platform_y: float = player.global_position.y + float(rules["first_platform_offset_y"])
	active_corridor_index = 0
	_activate_corridor(0, first_platform_y + _platform_height * 0.5)

	for c in platforms_root.get_children():
		c.queue_free()
	platforms.clear()
	platform_corridor_index.clear()

	platform_pool = PlatformPool.new(platform_scene, platforms_root, int(rules["pool_initial_size"]))

	path_selector = PathSelector.new()
	path_selector.initialize()

	var start_center: Vector2 = Vector2(start_x, first_platform_y)
	var start_seg: int = _segment_count_for_size_key("medium")
	if not _prepare_path_layout(start_center, start_seg):
		push_error("Level.gd: path layout failed completely")
		return

	_layout_index = 0
	last_main_pos = start_center
	_burst_spawn_layout()

	if show_run_debug_overlay:
		var o: CanvasLayer = RunDebugOverlayScript.new()
		o.level_path = get_path()
		add_child(o)

func _prepare_path_layout(start_center: Vector2, start_seg: int) -> bool:
	var m: PathModel = path_selector.active_model
	if m != null and m.steps.size() > 0:
		m.bake_from_steps(rules, active_corridor, start_center, start_seg, path_selector.active_direction, _tile_width, _platform_height)
		if m.detect_stairs(_platform_height * 0.2, 6):
			m.smooth_path(_platform_height * 0.25)
			m.resolve_platform_overlaps(rules, active_corridor, _tile_width, _platform_height)
		if not m.validate_full(rules, active_corridor, _tile_width, _platform_height):
			m.smooth_path(_platform_height * 0.55)
			m.resolve_platform_overlaps(rules, active_corridor, _tile_width, _platform_height)
		if m.validate_full(rules, active_corridor, _tile_width, _platform_height):
			_active_layout = m
			_fallback_snapshot = _snapshot_layout(m)
			if DEBUG_LOG:
				_log("[PATH] baked model_id=%s slots=%d" % [m.model_id, m.platforms.size()])
			return true

	if DEBUG_LOG:
		_log("[PATH] primary layout invalid — fail-safe")

	var fb: PathModel = _fallback_snapshot
	if fb == null or not fb.validate_full(rules, active_corridor, _tile_width, _platform_height):
		fb = PathModel.create_minimal_safe(start_center, _tile_width, _platform_height, active_corridor)
	_active_layout = fb
	return _active_layout != null and _active_layout.platforms.size() > 0

func _snapshot_layout(src: PathModel) -> PathModel:
	var c: PathModel = PathModel.new()
	c.model_id = src.model_id
	c.platforms = src.platforms.duplicate(true)
	c.steps = src.steps.duplicate(true)
	return c

func _burst_spawn_layout() -> void:
	var n: int = mini(_initial_spawn_target, _active_layout.platforms.size())
	while _layout_index < n:
		if not _spawn_next_layout_slot():
			break

func _physics_process(_delta: float) -> void:
	if _active_layout == null or platform_pool == null:
		return

	_debug_log_frame_counter += 1
	if DEBUG_LOG and _debug_log_frame_counter % 30 == 0:
		_log("[LEVEL] layout_idx=%s active=%s pool_avail=%d" % [_layout_index, platforms.size(), platform_pool.available_count()])

	_update_active_corridor()
	_cleanup_platforms_below_player()

	var fps: float = Engine.get_frames_per_second()
	var budget: int = _max_spawns_per_frame
	if fps < _fps_spawn_threshold:
		budget = mini(1, _max_spawns_per_frame)

	var spawns: int = 0
	while spawns < budget and _should_spawn_ahead():
		if _count_platforms_in_view() >= _max_visible_platforms:
			break
		if not _spawn_next_layout_slot():
			break
		spawns += 1

func _count_platforms_in_view() -> int:
	var band: float = viewport_height * 0.65
	var y0: float = player.global_position.y - band
	var y1: float = player.global_position.y + band
	var n: int = 0
	for p in platforms:
		if p == null or not is_instance_valid(p) or not p.visible:
			continue
		var py: float = p.global_position.y
		if py >= y0 and py <= y1:
			n += 1
	return n

func _should_spawn_ahead() -> bool:
	if _layout_index >= _active_layout.platforms.size():
		return false
	if platforms.is_empty():
		return true
	var highest: float = 1.0e12
	for p in platforms:
		if p == null or not is_instance_valid(p) or not p.visible:
			continue
		highest = minf(highest, p.global_position.y)
	return highest > player.global_position.y - _spawn_ahead_px

func _spawn_next_layout_slot() -> bool:
	if _layout_index >= _active_layout.platforms.size():
		return false
	var slot: Dictionary = _active_layout.platforms[_layout_index]
	var pos: Vector2 = Vector2(float(slot["x"]), float(slot["y"]))
	var seg: int = int(slot["segments"])
	var vanish: bool = int(slot.get("vanish", 0)) != 0

	var p: Node2D = platform_pool.get_platform()
	if p == null:
		return false

	_configure_platform(p, pos, seg, vanish, _layout_index)
	_register_platform(p, active_corridor_index)
	_try_spawn_loot(_layout_index, pos)

	last_main_pos = pos
	_layout_index += 1
	return true

func _configure_platform(p: Node2D, pos: Vector2, seg: int, vanish: bool, slot_idx: int) -> void:
	p.global_position = pos
	p.scale.x = float(seg)
	p.set("is_crumbling", vanish)
	p.set("coin_spawn_chance", 0.0)
	p.set("size", Vector2(_tile_width, _platform_height))
	p.call("apply_size_to_shape")
	if p.has_signal("platform_lifecycle_ended") and not p.platform_lifecycle_ended.is_connected(_on_platform_lifecycle_ended):
		p.platform_lifecycle_ended.connect(_on_platform_lifecycle_ended)

func _on_platform_lifecycle_ended(p: Node2D) -> void:
	release_platform_from_level(p)

func _try_spawn_loot(slot_idx: int, platform_center: Vector2) -> void:
	if _coin_spawn_chance <= 0.0:
		return
	var h: int = int(abs(hash(str(SeedManager.global_seed) + ":" + str(path_selector.active_model_index) + ":" + str(slot_idx)))) % 10000
	if (float(h) / 10000.0) >= _coin_spawn_chance:
		return
	var c: Node2D = coin_scene.instantiate() as Node2D
	var root: Node = get_tree().current_scene
	if root:
		root.add_child(c)
		c.global_position = platform_center + Vector2(0.0, -_coin_height_offset)

func _update_active_corridor() -> void:
	if active_corridor.is_empty():
		return
	if player.global_position.y <= float(active_corridor["min_y"]):
		var next_max_y: float = float(active_corridor["min_y"]) - 1.0
		_activate_corridor(active_corridor_index + 1, next_max_y)

func _activate_corridor(index: int, corridor_max_y: float) -> void:
	active_corridor_index = index
	var corridor_min_y: float = corridor_max_y - corridor_height + 1.0
	active_corridor = {
		"index": index,
		"min_x": corridor_min_x,
		"max_x": corridor_max_x,
		"min_y": corridor_min_y,
		"max_y": corridor_max_y
	}
	if DEBUG_LOG:
		_log("[CORRIDOR_ACTIVE] idx=%s y=[%s,%s]" % [index, corridor_min_y, corridor_max_y])

func _cleanup_platforms_below_player() -> void:
	var threshold: float = player.global_position.y + _release_below_px
	var to_release: Array[Node2D] = []
	for p in platforms:
		if p == null or not is_instance_valid(p):
			continue
		if p.global_position.y > threshold:
			to_release.append(p)
	for p in to_release:
		_remove_platform(p)
		platform_pool.release_platform(p)

func _register_platform(p: Node2D, corridor_index: int) -> void:
	platforms.append(p)
	platform_corridor_index[p.get_instance_id()] = corridor_index

func _remove_platform(platform: Node2D) -> void:
	if platforms.has(platform):
		platforms.erase(platform)
	platform_corridor_index.erase(platform.get_instance_id())

func release_platform_from_level(platform: Node2D) -> void:
	if platform == null or not is_instance_valid(platform):
		return
	_remove_platform(platform)
	platform_pool.release_platform(platform)

func _segment_count_for_size_key(key: String) -> int:
	var sizes: Dictionary = rules["platform_sizes"]
	if not sizes.has(key):
		return 1
	var arr: Variant = sizes[key]
	if typeof(arr) != TYPE_ARRAY or (arr as Array).size() < 1:
		return 1
	var w: float = float((arr as Array)[0])
	if _tile_width <= 0.0:
		return 1
	return maxi(1, int(round(w / _tile_width)))

func _validate_rules(r: Dictionary) -> bool:
	var required: Array[String] = [
		"min_gap", "max_gap", "height_variation", "vanish_chance", "platform_sizes",
		"pool_initial_size", "world_segment_minutes", "world_screens", "use_fixed_world_width",
		"fixed_world_width", "corridor_height_multiplier", "min_edge_gap", "vertical_gap",
		"safe_margin_x", "coin_spawn_chance", "spawn_ahead_pixels", "release_below_player_pixels",
		"initial_platforms_to_spawn", "max_spawns_per_frame",
		"player_spawn_offset_x", "player_spawn_offset_y", "first_platform_offset_y",
		"max_visible_platforms", "fps_spawn_threshold", "coin_height_offset"
	]
	for k in required:
		if not r.has(k):
			return false
	var ps: Variant = r["platform_sizes"]
	if typeof(ps) != TYPE_DICTIONARY:
		return false
	var pd: Dictionary = ps
	return pd.has("small") and pd.has("medium") and pd.has("large")

func _apply_rules_to_fields(r: Dictionary) -> void:
	var ps: Dictionary = r["platform_sizes"]
	var small: Array = ps["small"]
	_tile_width = float(small[0])
	_platform_height = float(small[1])
	_min_edge_gap = float(r["min_edge_gap"])
	_vertical_gap = float(r["vertical_gap"])
	_spawn_ahead_px = float(r["spawn_ahead_pixels"])
	_release_below_px = float(r["release_below_player_pixels"])
	_initial_spawn_target = int(r["initial_platforms_to_spawn"])
	_max_spawns_per_frame = int(r["max_spawns_per_frame"])
	_coin_spawn_chance = float(r["coin_spawn_chance"])
	_max_visible_platforms = int(r["max_visible_platforms"])
	_fps_spawn_threshold = float(r["fps_spawn_threshold"])
	_coin_height_offset = float(r["coin_height_offset"])

# --- Тестовые и вспомогательные хуки (overlap / reach), без физики уровневой генерации ---

func _is_platform_fully_inside_active_corridor(pos: Vector2, segments: int, extra_x: float = 0.0, extra_y: float = 0.0) -> bool:
	if active_corridor.is_empty():
		return true
	var half_w: float = float(segments) * _tile_width * 0.5 + extra_x
	var half_h: float = _platform_height * 0.5 + extra_y
	if pos.x - half_w < float(active_corridor["min_x"]):
		return false
	if pos.x + half_w > float(active_corridor["max_x"]):
		return false
	if pos.y - half_h < float(active_corridor["min_y"]):
		return false
	if pos.y + half_h > float(active_corridor["max_y"]):
		return false
	return true

func _is_position_valid_for_platform(pos: Vector2, segments: int, _from_platform: Node2D = null, extra_x: float = 0.0, extra_y: float = 0.0, include_visual_only: bool = false) -> bool:
	if not _is_platform_fully_inside_active_corridor(pos, segments, extra_x, extra_y):
		return false
	var half_new_x: float = float(segments) * _tile_width * 0.5 + extra_x
	var half_new_y: float = _platform_height * 0.5 + extra_y
	for p in platforms:
		if p == null or not is_instance_valid(p):
			continue
		var p_corridor_idx: int = int(platform_corridor_index.get(p.get_instance_id(), active_corridor_index))
		if p_corridor_idx != active_corridor_index:
			continue
		if not include_visual_only:
			var is_decoy_like: bool = p.get("is_decoy") == true or p.get("fake_visual_only") == true
			if is_decoy_like:
				continue
		var existing_segments: int = max(1, int(round(p.scale.x)))
		var half_ex_x: float = float(existing_segments) * _tile_width * 0.5
		var half_ex_y: float = _platform_height * 0.5
		var dx: float = abs(pos.x - p.global_position.x)
		var dy: float = abs(pos.y - p.global_position.y)
		var min_dx: float = half_new_x + half_ex_x + _min_edge_gap
		var min_dy: float = half_new_y + half_ex_y + _vertical_gap
		if dx < min_dx and dy < min_dy:
			return false
	return true

func _is_position_valid_for_visual_only(pos: Vector2, segments: int) -> bool:
	return _is_position_valid_for_platform(pos, segments, null, 0.0, 0.0, true)

func _max_horizontal_reach(start_surface_y: float, target_surface_y: float, v_jump: float, g: float, v_x: float) -> float:
	var delta_y: float = target_surface_y - start_surface_y
	var disc: float = v_jump * v_jump + 2.0 * g * delta_y
	if disc < 0.0:
		return 0.0
	var t: float = (-v_jump + sqrt(disc)) / g
	return abs(v_x) * t

func _center_to_next_edge_is_reachable(target_center: Vector2, next_half_width: float, v_jump: float, g: float, v_x: float) -> bool:
	var start_surface_y: float = last_main_pos.y - _platform_height * 0.5
	var target_surface_y: float = target_center.y - _platform_height * 0.5
	var reach: float = _max_horizontal_reach(start_surface_y, target_surface_y, v_jump, g, v_x)
	var center_dx: float = abs(target_center.x - last_main_pos.x)
	var edge_dx: float = max(0.0, center_dx - next_half_width)
	return edge_dx <= reach

func _log(message: String) -> void:
	FileLogger.write_log(message)
	if DEBUG_LOG:
		print(message)
