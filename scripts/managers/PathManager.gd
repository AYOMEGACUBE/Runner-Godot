extends Node
class_name PathManager
## Стриминг уровня по коленам (Z-path). Два колена в памяти: текущее и предзагруженное.
## Не трогает JSON на диске; чанки только из копий ChunkRegistry.

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")

## Совпадает с наклоном смещения Y в PlatformSpawner (подъём пути при росте |x − старт|).
const PATH_SLOPE_DEG: float = 5.0

signal leg_started(leg_index: int, direction: int)
signal leg_completed(leg_index: int, direction: int)
signal wall_top_reached

@export var player_path: NodePath = NodePath("../Player")
@export var platforms_parent_path: NodePath = NodePath("../Platforms")
@export var chunks_per_leg: int = 4
@export var leg_ascent_degrees: float = PATH_SLOPE_DEG
@export var first_leg_anchor: Vector2 = Vector2(2000.0, 1000.0)
@export var preload_progress: float = 0.90
@export var handoff_margin_px: float = 48.0
@export var hide_next_leg_until_handoff: bool = false
@export var debug_log: bool = false
@export var auto_start: bool = false
## Следующее колено по Y: смещение вверх (меньше y) от верхней точки текущего колена.
## Полный ΔY грани (~13438) здесь даёт колено вне досягаемости игрока за один горизонтальный проход — см. аудит.
@export_range(200, 800, 1.0) var leg_next_row_drop_px: float = 480.0
@export var audit_verbose: bool = false
## Одноразовые сообщения при старте стриминга (независимо от debug_log), для смоук-теста.
@export var log_streaming_startup: bool = true
## Лог каждого выбранного чанка: Leg | chunk i/N | model_id | direction.
@export var trace_chunk_selection: bool = false
## На каждое колено: перемешать все model_id и проходить по колоде (равномерное покрытие; при chunks_per_leg ≤ числа моделей — без повторов в одном колене).
@export var use_shuffled_chunk_deck_per_leg: bool = true

var current_leg_index: int = 0
var current_direction: int = 1
var current_leg_container: Node2D = null
var next_leg_container: Node2D = null
var next_leg_direction: int = 1
var leg_start_x: float = 0.0
var leg_end_x: float = 0.0
var leg_bounds_min_x: float = 0.0
var leg_bounds_max_x: float = 0.0
var leg_anchor_y: float = 1000.0

var _player: CharacterBody2D = null
var _platforms_parent: Node2D = null
var _registry: ChunkRegistry = ChunkRegistry.new()
var _scaler: DifficultyScaler = DifficultyScaler.new()
var _leg_builder: LegBuilder = null
var _spawner: PlatformSpawner = PlatformSpawner.new()
var _rng: RandomNumberGenerator = null
var _run_start_player_y: float = 0.0
var _run_start_player_x: float = 0.0


func _sync_slope_into_leg_builder() -> void:
	_leg_builder.path_slope_origin_x = _run_start_player_x
	_leg_builder.path_slope_deg = PATH_SLOPE_DEG
## Копии словарей чанков текущего колена (для валидации стыка с первым чанком следующего).
var _current_leg_chunk_data: Array = []
## Копия чанков, из которых собрано предзагруженное колено (до handoff).
var _staged_next_leg_chunk_data: Array = []
var _wall_emitted: bool = false
var _preload_logged: bool = false


func _ready() -> void:
	_leg_builder = LegBuilder.new(_registry, _scaler)
	_sync_leg_builder_from_rules()
	var sm: Node = get_node_or_null("/root/SeedManager")
	if sm != null and sm.has_method("get_rng_for"):
		_rng = sm.call("get_rng_for", "path_legs")
	else:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	_registry.debug_load = debug_log or trace_chunk_selection
	_registry.reload()
	if auto_start:
		call_deferred("start_streaming")


func _sync_leg_builder_from_rules() -> void:
	var dm: Node = get_node_or_null("/root/DataManager")
	var r: Dictionary = dm.get("rules_data") as Dictionary if dm != null else {}
	if r.is_empty():
		_leg_builder.jump_reach_fraction = 0.8
		_leg_builder.safe_margin_x = 32.0
	else:
		_leg_builder.jump_reach_fraction = float(r.get("jump_reach_max_fraction", 0.8))
		_leg_builder.safe_margin_x = float(r.get("safe_margin_x", 32.0))
	_leg_builder.leg_next_row_drop_px = leg_next_row_drop_px
	_leg_builder.max_y_correction_per_transition_px = 300.0
	_leg_builder.use_shuffled_chunk_deck = use_shuffled_chunk_deck_per_leg
	_leg_builder.trace_chunk_selection = trace_chunk_selection


func _clone_chunk_array(src: Array) -> Array:
	var out: Array = []
	for el in src:
		if typeof(el) == TYPE_DICTIONARY:
			out.append((el as Dictionary).duplicate(true))
	return out


func start_streaming() -> void:
	_sync_leg_builder_from_rules()
	_clear_container(next_leg_container)
	next_leg_container = null
	_current_leg_chunk_data.clear()
	_staged_next_leg_chunk_data.clear()
	_wall_emitted = false
	_preload_logged = false
	current_leg_index = 0
	current_direction = 1 if ((_rng.randi() & 1) == 0) else -1
	next_leg_direction = -current_direction
	_player = get_node_or_null(player_path) as CharacterBody2D
	_platforms_parent = get_node_or_null(platforms_parent_path) as Node2D
	if _player == null or _platforms_parent == null:
		push_error("PathManager: assign player_path and platforms_parent_path")
		return
	_registry.debug_load = debug_log or trace_chunk_selection
	if _registry.size() == 0:
		_registry.reload()
	_run_start_player_y = _player.global_position.y
	_run_start_player_x = _player.global_position.x
	leg_anchor_y = first_leg_anchor.y
	_scaler.global_path_height = 0.0
	if log_streaming_startup:
		print("[ChunkRegistry] Loaded %d models" % _registry.size())
		print("[PathManager] Streaming started")
	_spawn_leg_initial()
	_sync_player_move_to_leg_direction()


## Горизонтальный бег/первый прыжок по инерции — в ту же сторону, куда собрано первое колено (+1 вправо, −1 влево).
func _sync_player_move_to_leg_direction() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var dir_f: float = 1.0 if current_direction >= 0 else -1.0
	# Player.gd: move_dir + DEFAULT_MOVE_DIR (после отпускания клавиш вернётся к умолчанию)
	_player.set("move_dir", dir_f)
	_player.set("DEFAULT_MOVE_DIR", dir_f)


func _spawn_leg_initial() -> void:
	_clear_container(current_leg_container)
	current_leg_container = null
	var start: Vector2 = Vector2(first_leg_anchor.x, leg_anchor_y)
	_audit_verbose("spawn initial start=%s dir=%d chunks_per_leg=%d registry_size=%d" % [str(start), current_direction, chunks_per_leg, _registry.size()])
	_sync_leg_builder_from_rules()
	_sync_slope_into_leg_builder()
	_leg_builder.trace_leg_index = current_leg_index
	if debug_log or trace_chunk_selection:
		print("[PathManager] Building leg %d with %d chunks (registry=%d models)" % [current_leg_index, chunks_per_leg, _registry.size()])
	var chunks: Array = _leg_builder.build_leg(start, current_direction, chunks_per_leg, _rng)
	if chunks.is_empty():
		push_error("PathManager: no chunks — check ChunkRegistry / chunks folder")
		return
	_current_leg_chunk_data = _clone_chunk_array(chunks)
	current_leg_container = _spawner.spawn_leg(chunks, _platforms_parent, _run_start_player_y, _rng)
	_update_leg_x_bounds(current_leg_container)
	leg_start_x = leg_bounds_min_x
	leg_end_x = leg_bounds_max_x
	leg_started.emit(current_leg_index, current_direction)
	if debug_log:
		_log("Leg %d started dir=%d x=[%.0f,%.0f] y=%.0f" % [current_leg_index, current_direction, leg_bounds_min_x, leg_bounds_max_x, leg_anchor_y])


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if current_leg_container == null or not is_instance_valid(current_leg_container):
		return
	_scaler.global_path_height = maxf(0.0, _run_start_player_y - _player.global_position.y)
	if not _wall_emitted and _scaler.global_path_height >= _scaler.total_wall_height_px * 0.995:
		_wall_emitted = true
		wall_top_reached.emit()
	var span: float = leg_end_x - leg_start_x
	if absf(span) < 1.0:
		return
	var t: float = (_player.global_position.x - leg_start_x) / span
	if current_direction < 0:
		t = (leg_end_x - _player.global_position.x) / span
	t = clampf(t, 0.0, 1.0)
	if audit_verbose and Engine.get_process_frames() % 45 == 0:
		print_debug("[PathManager][audit] progress t=%.3f leg=%d px=%.0f" % [t, current_leg_index, _player.global_position.x])
	if t >= preload_progress and next_leg_container == null:
		_prebuild_next_leg()
	if next_leg_container != null and is_instance_valid(next_leg_container):
		if _should_handoff():
			_commit_handoff()


func _prebuild_next_leg() -> void:
	var top_y: float = _leg_top_platform_y(current_leg_container)
	var ny: float = top_y - leg_next_row_drop_px
	if ny != ny or absf(top_y) > 1.0e12:
		ny = leg_anchor_y - mini(leg_next_row_drop_px, _delta_y_per_leg())
	var anchor: Vector2 = Vector2.ZERO
	if current_direction > 0:
		anchor = Vector2(leg_bounds_max_x - 800.0, ny)
	else:
		anchor = Vector2(leg_bounds_min_x + 800.0, ny)
	next_leg_direction = -current_direction
	_sync_leg_builder_from_rules()
	_sync_slope_into_leg_builder()
	_leg_builder.trace_leg_index = current_leg_index + 1
	if debug_log or trace_chunk_selection:
		print("[PathManager] Building leg %d with %d chunks (registry=%d models)" % [current_leg_index + 1, chunks_per_leg, _registry.size()])
	var built: Array = _leg_builder.build_leg(anchor, next_leg_direction, chunks_per_leg, _rng)
	if built.is_empty():
		push_warning("PathManager: prebuild produced empty next leg (leg=%d dir=%d registry=%d)" % [current_leg_index + 1, next_leg_direction, _registry.size()])
		return
	if not _current_leg_chunk_data.is_empty():
		_leg_builder.validate_transition_adjust_landing_chunk(_current_leg_chunk_data[_current_leg_chunk_data.size() - 1], built[0])
		_ensure_leg_to_leg_reachable(_current_leg_chunk_data[_current_leg_chunk_data.size() - 1], built)
	if debug_log and not _preload_logged:
		_preload_logged = true
		var arrow: String = "→" if next_leg_direction > 0 else "←"
		_log("Prebuilding Leg %d (%s) at y=%.0f (row_drop=%.0f)" % [current_leg_index + 1, arrow, ny, leg_next_row_drop_px])
	_audit_verbose("prebuild next leg ny=%.1f anchor=%s" % [ny, str(anchor)])
	_staged_next_leg_chunk_data = _clone_chunk_array(built)
	next_leg_container = _spawner.spawn_leg(built, _platforms_parent, _run_start_player_y, _rng)
	if hide_next_leg_until_handoff:
		next_leg_container.visible = false


func _ensure_leg_to_leg_reachable(prev_last_chunk: Dictionary, next_leg_chunks: Array) -> void:
	if next_leg_chunks.is_empty():
		return
	if prev_last_chunk.is_empty() or typeof(next_leg_chunks[0]) != TYPE_DICTIONARY:
		return
	var landing_chunk: Dictionary = next_leg_chunks[0] as Dictionary
	var last_plat: Dictionary = _leg_builder._last_support_slot(prev_last_chunk)
	var first_plat: Dictionary = _leg_builder._first_support_slot(landing_chunk)
	if last_plat.is_empty() or first_plat.is_empty():
		return
	# ΔsurfaceY = (landing_y - 32) - (takeoff_y - 32) = landing_y - takeoff_y
	var delta_surf: float = float(first_plat.get("y", 0.0)) - float(last_plat.get("y", 0.0))
	var v0: float = PhysicsConfig.JUMP_VELOCITY
	var g: float = PhysicsConfig.GRAVITY
	var disc: float = v0 * v0 + 2.0 * g * delta_surf
	if disc >= 0.0:
		pass
	# Pull the whole next leg down so disc becomes valid.
	if disc < 0.0:
		var max_h: float = (v0 * v0) / (2.0 * g)
		var target_delta: float = clampf(delta_surf, -max_h * 0.92, max_h * 0.78)
		var dy: float = target_delta - delta_surf
		if absf(dy) > 0.01:
			for ch in next_leg_chunks:
				if typeof(ch) == TYPE_DICTIONARY:
					_leg_builder._apply_y_shift_to_chunk(ch as Dictionary, dy)
			_leg_builder.validate_transition_adjust_landing_chunk(prev_last_chunk, landing_chunk)

	# After Y correction, ensure the horizontal edge gap is within reach by shifting the whole next leg in X if needed.
	last_plat = _leg_builder._last_support_slot(prev_last_chunk)
	first_plat = _leg_builder._first_support_slot(landing_chunk)
	if last_plat.is_empty() or first_plat.is_empty():
		return
	delta_surf = float(first_plat.get("y", 0.0)) - float(last_plat.get("y", 0.0))
	var reach: float = PhysicsConfig.horizontal_reach_with_fraction(delta_surf, _leg_builder.jump_reach_fraction)
	var dx_centers: float = absf(float(first_plat.get("x", 0.0)) - float(last_plat.get("x", 0.0)))
	var edge_gap: float = dx_centers - _leg_builder._half_width_from_center(last_plat) - _leg_builder._half_width_from_center(first_plat)
	edge_gap = maxf(0.0, edge_gap)
	var max_gap: float = reach - _leg_builder.safe_margin_x
	if edge_gap > max_gap + 0.01:
		var excess: float = edge_gap - max_gap
		var dir_to_takeoff: float = -signf(float(first_plat.get("x", 0.0)) - float(last_plat.get("x", 0.0)))
		var dx: float = dir_to_takeoff * excess
		for ch in next_leg_chunks:
			if typeof(ch) != TYPE_DICTIONARY:
				continue
			var dch: Dictionary = ch as Dictionary
			var plats: Array = dch.get("platforms", []) as Array
			for pv in plats:
				if typeof(pv) != TYPE_DICTIONARY:
					continue
				var pd: Dictionary = pv as Dictionary
				pd["x"] = float(pd.get("x", 0.0)) + dx
		_leg_builder.validate_transition_adjust_landing_chunk(prev_last_chunk, landing_chunk)


func _should_handoff() -> bool:
	var nb: Dictionary = _container_x_bounds(next_leg_container)
	var nmin: float = nb.get("min", 0.0)
	var nmax: float = nb.get("max", 0.0)
	var px: float = _player.global_position.x
	if current_direction > 0:
		return px >= nmin - handoff_margin_px
	return px <= nmax + handoff_margin_px


func _commit_handoff() -> void:
	var done_idx: int = current_leg_index
	var done_dir: int = current_direction
	if current_leg_container != null and is_instance_valid(current_leg_container):
		current_leg_container.queue_free()
	current_leg_container = next_leg_container
	next_leg_container = null
	current_direction = next_leg_direction
	current_leg_index += 1
	if hide_next_leg_until_handoff and current_leg_container != null:
		current_leg_container.visible = true
	_update_leg_x_bounds(current_leg_container)
	leg_start_x = leg_bounds_min_x
	leg_end_x = leg_bounds_max_x
	var sync_y: float = _leg_top_platform_y(current_leg_container)
	if sync_y == sync_y and absf(sync_y) < 1.0e12:
		leg_anchor_y = sync_y
	_current_leg_chunk_data = _clone_chunk_array(_staged_next_leg_chunk_data)
	_staged_next_leg_chunk_data.clear()
	_preload_logged = false
	leg_completed.emit(done_idx, done_dir)
	leg_started.emit(current_leg_index, current_direction)
	_sync_player_move_to_leg_direction()
	if debug_log:
		_log("Handoff → leg %d dir=%d x=[%.0f,%.0f]" % [current_leg_index, current_direction, leg_bounds_min_x, leg_bounds_max_x])


func _delta_y_per_leg() -> float:
	var rad: float = deg_to_rad(leg_ascent_degrees)
	return float(WorldSegmentGrid.FACE_AXIS_PX) * tan(rad)


func _leg_top_platform_y(container: Node2D) -> float:
	if container == null or not is_instance_valid(container):
		return NAN
	var vmin: float = 1.0e20
	for c in container.get_children():
		if c is Node2D:
			vmin = minf(vmin, (c as Node2D).global_position.y)
	if vmin > 1.0e19:
		return NAN
	return vmin


func _audit_verbose(msg: String) -> void:
	if not audit_verbose:
		return
	print_debug("[PathManager][audit] ", msg)


func _update_leg_x_bounds(container: Node2D) -> void:
	var b: Dictionary = _container_x_bounds(container)
	leg_bounds_min_x = b.get("min", 0.0)
	leg_bounds_max_x = b.get("max", 0.0)


func _container_x_bounds(container: Node2D) -> Dictionary:
	var min_x: float = 1.0e15
	var max_x: float = -1.0e15
	if container == null:
		return {"min": 0.0, "max": 0.0}
	for c in container.get_children():
		if c is Node2D:
			var n: Node2D = c as Node2D
			var sx: float = 1.0
			if absf(n.scale.x) > 0.001:
				sx = absf(n.scale.x)
			var half: float = 32.0 * sx
			var gx: float = n.global_position.x
			min_x = minf(min_x, gx - half)
			max_x = maxf(max_x, gx + half)
	if min_x > max_x:
		return {"min": 0.0, "max": 0.0}
	return {"min": min_x, "max": max_x}


func _clear_container(c: Node2D) -> void:
	if c != null and is_instance_valid(c):
		c.queue_free()


func _log(msg: String) -> void:
	if not debug_log:
		return
	var line: String = "[PathManager] " + msg
	print(line)
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", line)
