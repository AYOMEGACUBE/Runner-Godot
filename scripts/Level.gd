extends Node2D
# Level.gd — твой фундамент + безопасное чтение параметров Player через get()

@onready var player: CharacterBody2D = $Player
@onready var platforms_root: Node2D = $Platforms

var platform_scene: PackedScene = preload("res://Platform.tscn")
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

const TILE_SIZE: float = 64.0
const PLATFORM_HEIGHT: float = 64.0

const MAIN_MIN_SEGMENTS: int = 2
const MAIN_MAX_SEGMENTS: int = 6

const DECOY_MIN_SEGMENTS: int = 1
const DECOY_MAX_SEGMENTS: int = 10

const SAFE_MAIN_GAP_X: float = 220.0

const MIN_EDGE_GAP: float = 32.0
const MAX_EDGE_GAP: float = SAFE_MAIN_GAP_X

const MIN_VERTICAL_GAP: float = 32.0
const MIN_TOTAL_PLATFORMS: int = 10

const PLAYER_SPEED_X: float = 350.0
const SEGMENT_TIME_SECONDS: float = 7.0 * 60.0
const WORLD_WIDTH: float = PLAYER_SPEED_X * SEGMENT_TIME_SECONDS
const LEFT_WALL_X: float = 0.0
const RIGHT_WALL_X: float = WORLD_WIDTH

const DY_STEP: float = 10.0  # Изменено с 64.0 на 10.0 для угла подъёма ~5% вместо ~30%

const DECOY_OFFSET_X_MIN: float = SAFE_MAIN_GAP_X * 1.6
const DECOY_OFFSET_X_MAX: float = SAFE_MAIN_GAP_X * 2.0

@export var WORLD_SCREENS: int = 20
@export var USE_FIXED_WORLD_WIDTH: bool = false
@export var FIXED_WORLD_WIDTH: float = 8000.0
@export var HORIZONTAL_WORLD_MARGIN: float = 256.0

const SAFE_MARGIN_X: float = 32.0

@export var DIFFICULTY_PER_STEP: float = 0.0025
@export var DIFFICULTY_START: float = 0.01
@export var DIFFICULTY_MAX: float = 0.1
var difficulty: float = 0.0

@export var GAP_MIN_PCT_EASY: float = 0.20
@export var GAP_MAX_PCT_EASY: float = 0.55
@export var GAP_MIN_PCT_HARD: float = 0.45
@export var GAP_MAX_PCT_HARD: float = 0.90

@export var MIN_MAIN_EDGE_GAP_ABS: float = 100.0
@export var MAX_MAIN_EDGE_GAP_ABS: float = 260.0

var viewport_width: float = 0.0
var viewport_height: float = 0.0

var min_center_x: float = 0.0
var max_center_x: float = 0.0

var platforms: Array[Node2D] = []

var last_main_pos: Vector2 = Vector2.ZERO
var last_main_segments: int = 4

var going_right: bool = true

var wall_clamp_count: int = 0
const WALL_CLAMP_THRESHOLD: int = 2

@export var DEBUG_LOG: bool = true

func _ready() -> void:
	rng.randomize()

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	viewport_width = viewport_size.x
	viewport_height = viewport_size.y
	
	var world_left: float = LEFT_WALL_X
	var world_right: float = RIGHT_WALL_X

	if USE_FIXED_WORLD_WIDTH:
		world_right = world_left + max(0.0, FIXED_WORLD_WIDTH)
	else:
		var screens_width: float = max(1, WORLD_SCREENS) * viewport_width
		world_right = world_left + screens_width

	min_center_x = world_left + HORIZONTAL_WORLD_MARGIN
	max_center_x = world_right - HORIZONTAL_WORLD_MARGIN

	if max_center_x <= min_center_x:
		var safe_margin_try: float = max(8.0, viewport_width * 0.1)
		min_center_x = world_left + safe_margin_try
		max_center_x = world_right - safe_margin_try

	var start_x: float = clamp(min_center_x + 200.0, min_center_x, max_center_x)
	var start_y: float = viewport_height - 200.0
	if player:
		player.global_position = Vector2(start_x, start_y)
	else:
		push_error("Level.gd: player node not found at $Player")

	difficulty = clamp(DIFFICULTY_START, 0.0, DIFFICULTY_MAX)

	for child in platforms_root.get_children():
		child.queue_free()
	platforms.clear()

	_create_initial_platforms()

func _physics_process(_delta: float) -> void:
	# ВАЖНО: сначала проверяем is_game_over, чтобы после смерти
	# не было лишних обновлений.
	if Engine.has_singleton("GameState") and GameState.is_game_over:
		return
	_update_platforms_around_player()

# --- FIX: безопасно читаем export-поля Player.gd через get() ---
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

func _can_place_platform_at(pos: Vector2, segments: int) -> bool:
	var half_new_x: float = float(segments) * TILE_SIZE * 0.5
	for p in platforms:
		if not p:
			continue
		var existing_segments: int = max(1, int(round(p.scale.x)))
		var half_ex_x: float = float(existing_segments) * TILE_SIZE * 0.5
		var dx: float = abs(pos.x - p.global_position.x)
		var dy: float = abs(pos.y - p.global_position.y)
		var min_allowed_dx: float = half_new_x + half_ex_x + MIN_EDGE_GAP
		var min_allowed_dy: float = PLATFORM_HEIGHT + MIN_VERTICAL_GAP
		if dx < min_allowed_dx and dy < min_allowed_dy:
			return false
	return true

func _create_initial_platforms() -> void:
	var start_platform_pos: Vector2 = player.global_position + Vector2(0.0, 80.0)
	var initial_segments: int = 4
	_spawn_main_platform_at(start_platform_pos, initial_segments)

	going_right = true
	for _i in range(MIN_TOTAL_PLATFORMS - 1):
		_spawn_next_step()

func _spawn_main_platform_at(pos: Vector2, segments: int) -> Node2D:
	var clamped_segments: int = clamp(segments, MAIN_MIN_SEGMENTS, MAIN_MAX_SEGMENTS)
	var adjusted_pos: Vector2 = pos
	var attempts: int = 0
	while attempts < 6 and not _can_place_platform_at(adjusted_pos, clamped_segments):
		adjusted_pos.y -= PLATFORM_HEIGHT + MIN_VERTICAL_GAP
		attempts += 1

	var p: Node2D = platform_scene.instantiate()
	platforms_root.add_child(p)
	p.global_position = adjusted_pos
	p.scale.x = float(clamped_segments)
	
	# Определяем, должна ли платформа быть обваливающейся.
	# Базовый шанс: 30%, увеличивается до 60% на высоте.
	var player_y: float = player.global_position.y if player else 0.0
	var platform_y: float = adjusted_pos.y
	var height_factor: float = abs(platform_y - player_y) / 5000.0  # Нормализуем по высоте
	height_factor = clamp(height_factor, 0.0, 1.0)
	var crumbling_chance: float = lerp(0.3, 0.6, height_factor)
	
	if rng.randf() < crumbling_chance:
		# Все платформы создаются из Platform.tscn, где есть свойство is_crumbling.
		# Поэтому можем безопасно установить его напрямую.
		p.set("is_crumbling", true)
	
	platforms.append(p)

	last_main_segments = clamped_segments
	last_main_pos = adjusted_pos

	return p

func _spawn_next_step() -> void:
	difficulty = clamp(difficulty + DIFFICULTY_PER_STEP, 0.0, DIFFICULTY_MAX)

	var seg_main: int = rng.randi_range(MAIN_MIN_SEGMENTS, MAIN_MAX_SEGMENTS)
	var half_prev: float = float(last_main_segments) * TILE_SIZE * 0.5
	var half_new: float = float(seg_main) * TILE_SIZE * 0.5

	var new_y: float = last_main_pos.y - DY_STEP

	var start_surface_y: float = last_main_pos.y - PLATFORM_HEIGHT * 0.5
	var target_surface_y: float = new_y - PLATFORM_HEIGHT * 0.5

	var p_jump: float = _get_player_param_float("JUMP_VELOCITY", -960.0)
	var p_grav: float = _get_player_param_float("GRAVITY", 2600.0)
	var p_speed: float = _get_player_param_float("MOVE_SPEED", 260.0)

	var reach: float = _max_horizontal_reach(start_surface_y, target_surface_y, p_jump, p_grav, p_speed)

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

	var max_allowed_gap: float = min(MAX_EDGE_GAP, max_edge_gap_physical)
	max_allowed_gap = min(max_allowed_gap, MAX_MAIN_EDGE_GAP_ABS)

	var allowed_min: float = max(edge_gap_min_from_desired, MIN_MAIN_EDGE_GAP_ABS)
	var allowed_max: float = min(edge_gap_max_from_desired, max_allowed_gap)

	var found: bool = false
	var chosen_edge_gap: float = 0.0
	var chosen_seg: int = seg_main
	var attempts: int = 0
	var max_attempts: int = 12

	while not found and attempts < max_attempts:
		half_new = float(chosen_seg) * TILE_SIZE * 0.5
		max_edge_gap_physical = max(0.0, reach - SAFE_MARGIN_X - half_new)

		edge_gap_min_from_desired = max(0.0, desired_min - half_new)
		edge_gap_max_from_desired = max(0.0, desired_max - half_new)

		max_allowed_gap = min(MAX_EDGE_GAP, max_edge_gap_physical)
		max_allowed_gap = min(max_allowed_gap, MAX_MAIN_EDGE_GAP_ABS)

		allowed_min = max(edge_gap_min_from_desired, MIN_MAIN_EDGE_GAP_ABS)
		allowed_max = min(edge_gap_max_from_desired, max_allowed_gap)

		if allowed_max < allowed_min:
			if chosen_seg > MAIN_MIN_SEGMENTS:
				chosen_seg -= 1
				attempts += 1
				continue
			else:
				break

		var candidates: Array[float] = [(allowed_min + allowed_max) * 0.5, allowed_min, allowed_max]

		for c in candidates:
			var dir_x: float = 1.0 if going_right else -1.0
			var tentative_x: float = last_main_pos.x + dir_x * (half_prev + half_new + c)
			var clamped_x: float = clamp(tentative_x, min_center_x, max_center_x)
			var candidate_pos: Vector2 = Vector2(clamped_x, new_y)

			if clamped_x != tentative_x:
				wall_clamp_count += 1
				if wall_clamp_count >= WALL_CLAMP_THRESHOLD:
					going_right = not going_right
					wall_clamp_count = 0
					break
				continue

			if _can_place_platform_at(candidate_pos, chosen_seg):
				found = true
				chosen_edge_gap = c
				break

		if not found:
			if chosen_seg > MAIN_MIN_SEGMENTS:
				chosen_seg -= 1
				attempts += 1
				continue
			else:
				break

	if found:
		var p: Node2D = platform_scene.instantiate()
		platforms_root.add_child(p)

		var dir_x_final: float = 1.0 if going_right else -1.0
		var tentative_x_final: float = last_main_pos.x + dir_x_final * (half_prev + float(chosen_seg) * TILE_SIZE * 0.5 + chosen_edge_gap)
		var clamped_x_final: float = clamp(tentative_x_final, min_center_x, max_center_x)

		var final_pos: Vector2 = Vector2(clamped_x_final, new_y)

		p.global_position = final_pos
		p.scale.x = float(chosen_seg)
		
		# Определяем, должна ли платформа быть обваливающейся
		var player_y2: float = player.global_position.y if player else 0.0
		var platform_y2: float = final_pos.y
		var height_factor2: float = abs(platform_y2 - player_y2) / 5000.0
		height_factor2 = clamp(height_factor2, 0.0, 1.0)
		var crumbling_chance2: float = lerp(0.3, 0.6, height_factor2)
		
		if rng.randf() < crumbling_chance2:
			p.set("is_crumbling", true)
		
		platforms.append(p)

		last_main_segments = chosen_seg
		last_main_pos = final_pos


		_spawn_decoys_around(p.global_position, chosen_seg)
		return

	# fallback
	var fallback_pos: Vector2 = Vector2(clamp(last_main_pos.x, min_center_x, max_center_x), new_y)
	var main_platform: Node2D = _spawn_main_platform_at(fallback_pos, seg_main)
	_spawn_decoys_around(main_platform.global_position, seg_main)

func _spawn_decoys_around(main_pos: Vector2, main_segments: int) -> void:
	var num_decoys: int = rng.randi_range(2, 3)
	if num_decoys <= 0:
		return

	for _i in range(num_decoys):
		var seg: int = rng.randi_range(DECOY_MIN_SEGMENTS, DECOY_MAX_SEGMENTS)
		var side: float = 1.0 if rng.randf() < 0.5 else -1.0
		var extra_offset: float = rng.randf_range(DECOY_OFFSET_X_MIN, DECOY_OFFSET_X_MAX)

		var half_main: float = float(main_segments) * TILE_SIZE * 0.5
		var half_decoy: float = float(seg) * TILE_SIZE * 0.5

		var decoy_center_x: float = main_pos.x + side * (half_main + half_decoy + extra_offset)
		decoy_center_x = clamp(decoy_center_x, min_center_x, max_center_x)

		var offset_y: float = rng.randf_range(-2.0 * PLATFORM_HEIGHT, 2.0 * PLATFORM_HEIGHT)
		var decoy_pos: Vector2 = Vector2(decoy_center_x, main_pos.y + offset_y)

		if not _can_place_platform_at(decoy_pos, seg):
			continue

		var decoy: Node2D = platform_scene.instantiate()
		platforms_root.add_child(decoy)
		decoy.global_position = decoy_pos
		decoy.scale.x = float(seg)
		
		# Определяем, должна ли платформа быть обваливающейся (те же правила)
		var player_y3: float = player.global_position.y if player else 0.0
		var platform_y3: float = decoy_pos.y
		var height_factor3: float = abs(platform_y3 - player_y3) / 5000.0
		height_factor3 = clamp(height_factor3, 0.0, 1.0)
		var crumbling_chance3: float = lerp(0.3, 0.6, height_factor3)
		
		if rng.randf() < crumbling_chance3:
			decoy.set("is_crumbling", true)
		
		platforms.append(decoy)

func _update_platforms_around_player() -> void:
	var player_y: float = player.global_position.y

	var remove_below: float = player_y + viewport_height
	# Используем обратный порядок итерации для безопасного удаления
	var platforms_to_remove: Array[Node2D] = []
	for p in platforms:
		# Проверяем, что объект всё ещё валиден перед доступом к свойствам
		if not is_instance_valid(p):
			platforms_to_remove.append(p)
			continue
		
		# Проверяем, не освобождён ли объект
		if p.is_queued_for_deletion():
			platforms_to_remove.append(p)
			continue
		
		# Проверяем позицию платформы
		if p.global_position.y > remove_below:
			platforms_to_remove.append(p)
	
	# Удаляем платформы из массива и освобождаем их
	for p in platforms_to_remove:
		if platforms.has(p):
			platforms.erase(p)
		if is_instance_valid(p) and not p.is_queued_for_deletion():
			p.queue_free()

	var upper_limit: float = player_y - viewport_height
	while platforms.size() < MIN_TOTAL_PLATFORMS or last_main_pos.y > upper_limit:
		_spawn_next_step()

func _remove_platform(platform: Node2D) -> void:
	"""Вспомогательная функция для безопасного удаления платформы из массива."""
	if platforms.has(platform):
		platforms.erase(platform)
