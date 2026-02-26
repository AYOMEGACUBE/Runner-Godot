extends Node2D

@onready var player: CharacterBody2D = $Player
@onready var platforms_root: Node2D = $Platforms

var platform_scene: PackedScene = preload("res://Platform.tscn")
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

const TILE_SIZE: float = 64.0
const PLATFORM_HEIGHT: float = 64.0
const DY_STEP: float = 64.0

const MAIN_MIN_SEGMENTS: int = 2
const MAIN_MAX_SEGMENTS: int = 6
const MIN_EDGE_GAP: float = 32.0
const MIN_VERTICAL_GAP: float = 0.0
const SAFE_MARGIN_X: float = 32.0
const MAX_STEP_ATTEMPTS: int = 12

const RED_PLATFORM_CHANCE: float = 0.4

const PLAYER_SPEED_X: float = 350.0
const SEGMENT_TIME_SECONDS: float = 7.0 * 60.0
const WORLD_WIDTH: float = PLAYER_SPEED_X * SEGMENT_TIME_SECONDS
const LEFT_WALL_X: float = 0.0
const RIGHT_WALL_X: float = WORLD_WIDTH

@export var WORLD_SCREENS: int = 20
@export var USE_FIXED_WORLD_WIDTH: bool = false
@export var FIXED_WORLD_WIDTH: float = 8000.0

@export var DIFFICULTY_PER_STEP: float = 0.0025
@export var DIFFICULTY_START: float = 0.01
@export var DIFFICULTY_MAX: float = 0.1

@export var GAP_MIN_PCT_EASY: float = 0.20
@export var GAP_MAX_PCT_EASY: float = 0.55
@export var GAP_MIN_PCT_HARD: float = 0.45
@export var GAP_MAX_PCT_HARD: float = 0.90

@export var MIN_MAIN_EDGE_GAP_ABS: float = 100.0
@export var MAX_MAIN_EDGE_GAP_ABS: float = 260.0

@export var DEBUG_LOG: bool = true

const CORRIDOR_HEIGHT_MULTIPLIER: float = 1.5

var difficulty: float = 0.0
var viewport_width: float = 0.0
var viewport_height: float = 0.0
var world_left: float = 0.0
var world_right: float = 0.0

var corridor_width: float = 0.0
var corridor_height: float = 0.0
var corridor_min_x: float = 0.0
var corridor_max_x: float = 0.0

var active_corridor_index: int = 0
var active_corridor: Dictionary = {}
var generated_corridors: Dictionary = {}

var platforms: Array[Node2D] = []
var platform_corridor_index: Dictionary = {}

var last_main_pos: Vector2 = Vector2.ZERO
var last_main_segments: int = 4
var going_right: bool = true
var _debug_log_frame_counter: int = 0
var wave_phase: int = 0

func _ready() -> void:
	rng.randomize()

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	viewport_width = viewport_size.x
	viewport_height = viewport_size.y

	world_left = LEFT_WALL_X
	world_right = RIGHT_WALL_X
	if USE_FIXED_WORLD_WIDTH:
		world_right = world_left + max(0.0, FIXED_WORLD_WIDTH)
	else:
		world_right = world_left + max(1, WORLD_SCREENS) * viewport_width

	corridor_width = max(1.0, world_right - world_left)
	corridor_height = max(1.0, floor(viewport_height * CORRIDOR_HEIGHT_MULTIPLIER))

	var start_x: float = clamp(world_left + 200.0, world_left + 64.0, world_right - 64.0)
	var start_y: float = viewport_height - 200.0
	if player:
		player.global_position = Vector2(start_x, start_y)
	else:
		push_error("Level.gd: player node not found at $Player")
		return

	corridor_min_x = world_left
	corridor_max_x = world_right

	if DEBUG_LOG:
		_log("[CORRIDOR_INIT] width=%s height=%s x=[%s,%s]" % [corridor_width, corridor_height, corridor_min_x, corridor_max_x])

	difficulty = clamp(DIFFICULTY_START, 0.0, DIFFICULTY_MAX)
	for child in platforms_root.get_children():
		child.queue_free()
	platforms.clear()
	platform_corridor_index.clear()
	generated_corridors.clear()

	var first_platform_y: float = player.global_position.y + 80.0
	_activate_corridor(0, first_platform_y + PLATFORM_HEIGHT * 0.5)
	_spawn_main_platform_at(Vector2(start_x, first_platform_y), 4, false)
	_generate_active_corridor_once()

func _physics_process(_delta: float) -> void:
	_debug_log_frame_counter += 1
	if DEBUG_LOG and _debug_log_frame_counter % 30 == 0:
		_log("[X_TRACK] player_x=%s last_main_x=%s corridor=[%s,%s]" % [player.global_position.x, last_main_pos.x, active_corridor.get("min_x", 0.0), active_corridor.get("max_x", 0.0)])
	_cleanup_old_corridor_platforms()
	_update_active_corridor()
	if not _is_corridor_generated(active_corridor_index):
		_generate_active_corridor_once()

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
	wave_phase = 0
	if DEBUG_LOG:
		_log("[CORRIDOR_ACTIVE] idx=%s x=[%s,%s] y=[%s,%s]" % [index, corridor_min_x, corridor_max_x, corridor_min_y, corridor_max_y])

func _is_corridor_generated(index: int) -> bool:
	return generated_corridors.has(index) and generated_corridors[index] == true

func _generate_active_corridor_once() -> void:
	if _is_corridor_generated(active_corridor_index):
		return

	var target_top_y: float = float(active_corridor["min_y"]) + PLATFORM_HEIGHT * 0.5
	var safety_steps: int = 0
	var safety_max: int = int(max(24.0, corridor_height / max(1.0, DY_STEP) * 6.0))

	while last_main_pos.y > target_top_y and safety_steps < safety_max:
		if not _spawn_step_in_active_corridor(target_top_y):
			if not _spawn_fallback_step():
				if DEBUG_LOG:
					_log("[CORRIDOR_STOP] idx=%s step=%s last_main_pos=%s" % [active_corridor_index, safety_steps, last_main_pos])
				break
		safety_steps += 1

	generated_corridors[active_corridor_index] = true
	if DEBUG_LOG:
		_log("[CORRIDOR_GENERATED] idx=%s steps=%s" % [active_corridor_index, safety_steps])

func _spawn_step_in_active_corridor(target_top_y: float) -> bool:
	difficulty = clamp(difficulty + DIFFICULTY_PER_STEP, 0.0, DIFFICULTY_MAX)

	var seg_main: int = rng.randi_range(MAIN_MIN_SEGMENTS, MAIN_MAX_SEGMENTS)
	var next_y: float = _choose_next_y_in_active_corridor(target_top_y)
	var start_surface_y: float = last_main_pos.y - PLATFORM_HEIGHT * 0.5
	var target_surface_y: float = next_y - PLATFORM_HEIGHT * 0.5

	var p_jump: float = _get_player_param_float("JUMP_VELOCITY", -960.0)
	var p_grav: float = _get_player_param_float("GRAVITY", 2600.0)
	var p_speed: float = _get_player_param_float("MOVE_SPEED", 260.0)
	var reach: float = _max_horizontal_reach(start_surface_y, target_surface_y, p_jump, p_grav, p_speed)

	var chosen_seg: int = seg_main
	var attempts: int = 0
	while attempts < MAX_STEP_ATTEMPTS:
		var half_prev: float = float(last_main_segments) * TILE_SIZE * 0.5
		var half_new: float = float(chosen_seg) * TILE_SIZE * 0.5
		var max_edge_gap_physical: float = max(0.0, reach - SAFE_MARGIN_X - half_new)

		var cur_min_pct: float = lerp(GAP_MIN_PCT_EASY, GAP_MIN_PCT_HARD, difficulty)
		var cur_max_pct: float = lerp(GAP_MAX_PCT_EASY, GAP_MAX_PCT_HARD, difficulty)
		if cur_max_pct < cur_min_pct:
			var tmp: float = cur_min_pct
			cur_min_pct = cur_max_pct
			cur_max_pct = tmp

		var desired_min: float = max(0.0, cur_min_pct * reach)
		var desired_max: float = max(0.0, cur_max_pct * reach)
		var edge_gap_min_from_desired: float = max(0.0, desired_min - half_new)
		var edge_gap_max_from_desired: float = max(0.0, desired_max - half_new)

		var max_allowed_gap: float = min(MAX_MAIN_EDGE_GAP_ABS, max_edge_gap_physical)
		var allowed_min: float = max(edge_gap_min_from_desired, MIN_MAIN_EDGE_GAP_ABS)
		var allowed_max: float = min(edge_gap_max_from_desired, max_allowed_gap)

		if allowed_max < allowed_min:
			if DEBUG_LOG:
				_log("[SPAWN_STEP] attempt=%d allowed_max(%.1f) < allowed_min(%.1f), reducing seg %d->%d" % [attempts, allowed_max, allowed_min, chosen_seg, max(MAIN_MIN_SEGMENTS, chosen_seg - 1)])
			chosen_seg = max(MAIN_MIN_SEGMENTS, chosen_seg - 1)
			attempts += 1
			continue

		if DEBUG_LOG:
			_log("[SPAWN_STEP] attempt=%d chosen_seg=%d allowed_gap=[%.1f,%.1f] reach=%.1f going_right=%s" % [attempts, chosen_seg, allowed_min, allowed_max, reach, going_right])

		var candidates: Array[float] = [(allowed_min + allowed_max) * 0.5, allowed_min, allowed_max]
		for c in candidates:
			var dir_x: float = 1.0 if going_right else -1.0
			var tentative_x: float = last_main_pos.x + dir_x * (half_prev + half_new + c)
			var x_limits: Vector2 = _center_x_limits_for_segments(chosen_seg)
			var clamped_x: float = clamp(tentative_x, x_limits.x, x_limits.y)
			if clamped_x != tentative_x:
				going_right = not going_right
				continue

			var candidate_pos: Vector2 = Vector2(clamped_x, next_y)
			if DEBUG_LOG:
				_log("[SPAWN_STEP] candidate gap=%.1f tentative_x=%.1f clamped_x=%.1f candidate_pos=%s" % [c, tentative_x, clamped_x, candidate_pos])
			if _is_position_valid_for_platform(candidate_pos, chosen_seg):
				var p: Node2D = platform_scene.instantiate()
				platforms_root.add_child(p)
				p.global_position = candidate_pos
				p.scale.x = float(chosen_seg)
				var is_red: bool = rng.randf() < RED_PLATFORM_CHANCE
				_apply_red_rule(p, true)
				_register_platform(p, active_corridor_index)
				last_main_segments = chosen_seg
				last_main_pos = candidate_pos
				if DEBUG_LOG:
					_log("[SPAWN_STEP] SUCCESS pos=%s segs=%d is_red=%s attempts=%d" % [candidate_pos, chosen_seg, is_red, attempts])
				return true
			elif DEBUG_LOG:
				_log("[SPAWN_STEP] candidate_pos=%s INVALID (collision or out of bounds)" % candidate_pos)

		chosen_seg = max(MAIN_MIN_SEGMENTS, chosen_seg - 1)
		attempts += 1

	if DEBUG_LOG:
		_log("[SPAWN_STEP] FAILED after %d attempts" % attempts)
	return false

func _spawn_fallback_step() -> bool:
	if DEBUG_LOG:
		_log("[FALLBACK_STEP] starting fallback last_main_pos=%s last_main_segments=%d" % [last_main_pos, last_main_segments])
	var seg: int = max(MAIN_MIN_SEGMENTS, min(MAIN_MAX_SEGMENTS, last_main_segments))
	var next_y: float = clamp(last_main_pos.y - DY_STEP, float(active_corridor["min_y"]) + PLATFORM_HEIGHT * 0.5, float(active_corridor["max_y"]) - PLATFORM_HEIGHT * 0.5)
	var x_limits: Vector2 = _center_x_limits_for_segments(seg)
	var fallback_pos: Vector2 = Vector2(clamp(last_main_pos.x, x_limits.x, x_limits.y), next_y)
	if DEBUG_LOG:
		_log("[FALLBACK_STEP] seg=%d next_y=%.1f x_limits=%s fallback_pos=%s" % [seg, next_y, x_limits, fallback_pos])
	if not _is_position_valid_for_platform(fallback_pos, seg):
		if DEBUG_LOG:
			_log("[FALLBACK_STEP] FAILED - position invalid")
		return false

	var p: Node2D = platform_scene.instantiate()
	platforms_root.add_child(p)
	p.global_position = fallback_pos
	p.scale.x = float(seg)
	_apply_red_rule(p, true)
	_register_platform(p, active_corridor_index)
	last_main_segments = seg
	last_main_pos = fallback_pos
	if DEBUG_LOG:
		_log("[FALLBACK_STEP] SUCCESS pos=%s segs=%d" % [fallback_pos, seg])
	return true

func _spawn_main_platform_at(pos: Vector2, segments: int, can_be_red: bool) -> Node2D:
	var clamped_segments: int = clamp(segments, MAIN_MIN_SEGMENTS, MAIN_MAX_SEGMENTS)
	var adjusted_pos: Vector2 = pos
	var attempts: int = 0
	while attempts < 8 and not _is_position_valid_for_platform(adjusted_pos, clamped_segments):
		adjusted_pos.y -= DY_STEP
		attempts += 1

	var x_limits: Vector2 = _center_x_limits_for_segments(clamped_segments)
	adjusted_pos.x = clamp(adjusted_pos.x, x_limits.x, x_limits.y)
	adjusted_pos.y = clamp(adjusted_pos.y, float(active_corridor["min_y"]) + PLATFORM_HEIGHT * 0.5, float(active_corridor["max_y"]) - PLATFORM_HEIGHT * 0.5)

	var p: Node2D = platform_scene.instantiate()
	platforms_root.add_child(p)
	p.global_position = adjusted_pos
	p.scale.x = float(clamped_segments)
	_apply_red_rule(p, can_be_red)
	_register_platform(p, active_corridor_index)
	last_main_segments = clamped_segments
	last_main_pos = adjusted_pos
	return p

func _choose_next_y_in_active_corridor(target_top_y: float) -> float:
	var half_h: float = PLATFORM_HEIGHT * 0.5
	var min_center_y: float = float(active_corridor["min_y"]) + half_h
	var max_center_y: float = float(active_corridor["max_y"]) - half_h

	var can_climb: bool = last_main_pos.y - DY_STEP >= min_center_y
	var can_descend: bool = last_main_pos.y + DY_STEP <= max_center_y
	var room_to_top: float = last_main_pos.y - target_top_y

	var dir: int = -1
	# Явная волна: 2 шага вверх, 1 шаг вниз (кроме зоны у верхней границы).
	if not can_climb and can_descend:
		dir = 1
	elif room_to_top <= DY_STEP * 2.0:
		dir = -1
	else:
		var cycle_step: int = wave_phase % 3
		if cycle_step == 2 and can_descend:
			dir = 1
		else:
			dir = -1
		wave_phase += 1

	var next_y: float = last_main_pos.y + float(dir) * DY_STEP
	var clamped_y: float = clamp(next_y, min_center_y, max_center_y)
	if DEBUG_LOG:
		_log("[CHOOSE_Y] target_top_y=%.1f can_climb=%s can_descend=%s room_to_top=%.1f wave_phase=%d dir=%d next_y=%.1f clamped=%.1f" % [target_top_y, can_climb, can_descend, room_to_top, wave_phase - 1, dir, next_y, clamped_y])
	return clamped_y

func _register_platform(p: Node2D, corridor_index: int) -> void:
	platforms.append(p)
	platform_corridor_index[p.get_instance_id()] = corridor_index
	if DEBUG_LOG:
		_log("[REGISTER_PLATFORM] pos=%s corridor=%d total_platforms=%d" % [p.global_position, corridor_index, platforms.size()])

func _cleanup_old_corridor_platforms() -> void:
	var cleaned_count: int = 0
	for p in platforms.duplicate():
		if not is_instance_valid(p):
			platforms.erase(p)
			cleaned_count += 1
			continue
		var idx: int = int(platform_corridor_index.get(p.get_instance_id(), active_corridor_index))
		if idx < active_corridor_index - 1:
			if DEBUG_LOG:
				_log("[CLEANUP] removing platform pos=%s corridor=%d (active=%d)" % [p.global_position, idx, active_corridor_index])
			_remove_platform(p)
			p.queue_free()
			cleaned_count += 1
	if DEBUG_LOG and cleaned_count > 0:
		_log("[CLEANUP] removed %d platforms, remaining=%d" % [cleaned_count, platforms.size()])

func _remove_platform(platform: Node2D) -> void:
	if platforms.has(platform):
		platforms.erase(platform)
	platform_corridor_index.erase(platform.get_instance_id())

func _apply_red_rule(platform: Node2D, can_be_red: bool) -> void:
	if platform == null:
		return
	var roll: float = rng.randf()
	var is_red: bool = can_be_red and roll < RED_PLATFORM_CHANCE
	platform.set("is_crumbling", is_red)
	if DEBUG_LOG:
		_log("[RED_RULE] pos=%s can_be_red=%s roll=%.3f is_red=%s" % [platform.global_position, can_be_red, roll, is_red])

func _center_x_limits_for_segments(segments: int) -> Vector2:
	var half_w: float = float(segments) * TILE_SIZE * 0.5
	var min_x: float = float(active_corridor["min_x"]) + half_w
	var max_x: float = float(active_corridor["max_x"]) - half_w
	if max_x < min_x:
		var mid: float = (min_x + max_x) * 0.5
		return Vector2(mid, mid)
	return Vector2(min_x, max_x)

func _is_platform_fully_inside_active_corridor(pos: Vector2, segments: int, extra_x: float = 0.0, extra_y: float = 0.0) -> bool:
	var half_w: float = float(segments) * TILE_SIZE * 0.5 + extra_x
	var half_h: float = PLATFORM_HEIGHT * 0.5 + extra_y
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

	var half_new_x: float = float(segments) * TILE_SIZE * 0.5 + extra_x
	var half_new_y: float = PLATFORM_HEIGHT * 0.5 + extra_y

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
		var half_ex_x: float = float(existing_segments) * TILE_SIZE * 0.5
		var half_ex_y: float = PLATFORM_HEIGHT * 0.5

		var dx: float = abs(pos.x - p.global_position.x)
		var dy: float = abs(pos.y - p.global_position.y)
		var min_dx: float = half_new_x + half_ex_x + MIN_EDGE_GAP
		var min_dy: float = half_new_y + half_ex_y + MIN_VERTICAL_GAP
		if dx < min_dx and dy < min_dy:
			return false
	return true

func _is_position_valid_for_visual_only(pos: Vector2, segments: int) -> bool:
	return _is_position_valid_for_platform(pos, segments, null, 0.0, 0.0, true)

func _get_player_param_float(param_name: String, fallback_value: float) -> float:
	if player == null:
		return fallback_value
	var v: Variant = player.get(param_name)
	if v == null:
		return fallback_value
	return float(v)

func _max_horizontal_reach(start_surface_y: float, target_surface_y: float, v_jump: float, g: float, v_x: float) -> float:
	var delta_y: float = target_surface_y - start_surface_y
	var disc: float = v_jump * v_jump + 2.0 * g * delta_y
	if disc < 0.0:
		return 0.0
	var t: float = (-v_jump + sqrt(disc)) / g
	return abs(v_x) * t

func _center_to_next_edge_is_reachable(target_center: Vector2, next_half_width: float, v_jump: float, g: float, v_x: float) -> bool:
	var start_surface_y: float = last_main_pos.y - PLATFORM_HEIGHT * 0.5
	var target_surface_y: float = target_center.y - PLATFORM_HEIGHT * 0.5
	var reach: float = _max_horizontal_reach(start_surface_y, target_surface_y, v_jump, g, v_x)
	var center_dx: float = abs(target_center.x - last_main_pos.x)
	var edge_dx: float = max(0.0, center_dx - next_half_width)
	return edge_dx <= reach

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/Logger")
	if logger != null and logger.has_method("log"):
		logger.call("log", message)
	else:
		print(message)
