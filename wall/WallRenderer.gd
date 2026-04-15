extends Node2D
class_name WallRenderer
# ============================================================================
# WallRenderer.gd
# Оптимизированный рендерер стены на основе MultiMeshInstance2D
# ============================================================================
# Вместо тысяч нод использует один MultiMesh для батч-отрисовки
# Данные берутся из WallData, клики обрабатываются по координатам
# ============================================================================
# THREAD-АРХИТЕКТУРА загрузки текстур:
#   ЭТАП 1 (Thread): Image.load() + resize → Image готов
#   ЭТАП 2 (Main): ImageTexture.create_from_image() + запись кэша + Sprite2D
# ============================================================================

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")
const SEGMENT_SIZE: int = WorldSegmentGrid.SEGMENT_SIZE_PX
const SEGMENTS_PER_SIDE: int = WorldSegmentGrid.SEGMENTS_PER_FACE_AXIS

var multimesh_instance: MultiMeshInstance2D = null

var wall_data: WallData = null
var side_id: String = "front"
var allow_purchases: bool = false

# Видимая область (в сегментах)
var visible_min_x: int = 0
var visible_max_x: int = 0
var visible_min_y: int = 0
var visible_max_y: int = 0

# Пул трансформ для переиспользования
var _transforms: Array[Transform2D] = []
var _segment_ids: Array[String] = []
var _multimesh: MultiMesh = null

# Параметры дыхания для каждого сегмента (независимые)
var _breathing_params: Array[Dictionary] = []
var _breathing_time: float = 0.0
const BASE_BREATHING_AMPLITUDE: float = 1.2
const BASE_BREATHING_SPEED: float = PI * 0.4

# Смена сторон сегментов
var _segment_sides: Array[String] = []
var _side_change_timers: Array[float] = []
var _side_change_intervals: Array[float] = []
const SIDES: Array[String] = ["front", "back", "left", "right", "top", "bottom"]
## Потолок инстансов MultiMesh — защита от отдаления камеры
const MAX_VISIBLE_INSTANCES: int = 10000
const HEAVY_MESH_SKIP_PROCESS: int = 500000

## Один RNG на весь кадр обновления видимой области / смены сторон
var _shared_rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Отображение изображений поверх MultiMesh
var _images_layer: Node2D = null
var _segment_sprites: Dictionary = {}        # segment_id -> Sprite2D
var _sprite_pool: Array[Sprite2D] = []
var _segment_index: Dictionary = {}          # segment_id -> индекс в массивах
var _last_known_tile_side: Dictionary = {}

# Подсветка выбранных сегментов
var _highlighted_segment_ids: Array[String] = []
var pause_side_switching: bool = false
var dim_other_segments: bool = false
var _preview_image_paths: Dictionary = {}

# ─────────────────────────────────────────────────────────────────────────────
# КЭШИ ТЕКСТУР (LRU)
# ─────────────────────────────────────────────────────────────────────────────
var _texture_cache: Dictionary = {}          # img_path -> Texture2D
var _texture_cache_order: Array[String] = [] # LRU: oldest -> newest
const MAX_TEXTURE_CACHE_ENTRIES: int = 256

# ─────────────────────────────────────────────────────────────────────────────
# ОЧЕРЕДЬ ЗАДАЧ ДЛЯ MAIN-ПОТОКА (те же поля что и раньше — совместимость)
# ─────────────────────────────────────────────────────────────────────────────
var _texture_load_queue: Array[Dictionary] = []
var _texture_load_queued_keys: Dictionary = {}  # qkey -> true, защита от дублей
const MAX_TEXTURE_LOADS_PER_FRAME_GAME: int = 2
const MAX_TEXTURE_LOADS_PER_FRAME_VIEW: int = 24
const MAX_TEXTURE_QUEUE_LENGTH: int = 2000

# ─────────────────────────────────────────────────────────────────────────────
# THREAD-АРХИТЕКТУРА
# ─────────────────────────────────────────────────────────────────────────────
## Очередь задач для потока: [{path, key}]
var _thread_queue: Array = []
## Очередь результатов из потока: [{key, image, success}]
var _thread_results: Array = []
## Пути, уже отправленные в поток (защита от дублей на уровне пути)
var _thread_queued_paths: Dictionary = {}

var _thread_mutex: Mutex = Mutex.new()
var _results_mutex: Mutex = Mutex.new()
var _loader_thread: Thread = null
var _thread_stop: bool = false
## Семафор: сигнализирует потоку, что появились задачи
var _thread_semaphore: Semaphore = Semaphore.new()
## Максимум задач на одну итерацию потока
const MAX_THREAD_TASKS_PER_ITER: int = 6
## Максимум результатов, применяемых за один _process (создание ImageTexture в main)
const MAX_RESULTS_PER_FRAME: int = 8

@export var DEBUG_LOG: bool = false

# Кэш ссылки на GameState
var _gs_cache: Node = null
var _breathing_was_enabled: bool = false

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if multimesh_instance == null:
		multimesh_instance = MultiMeshInstance2D.new()
		multimesh_instance.name = "MultiMeshInstance2D"
		multimesh_instance.z_index = -10
		add_child(multimesh_instance)

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.instance_count = 0

	var array_mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var half_size: float = SEGMENT_SIZE * 0.5
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-half_size, -half_size, 0),
		Vector3(half_size, -half_size, 0),
		Vector3(half_size, half_size, 0),
		Vector3(-half_size, half_size, 0)
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)
	])
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_multimesh.mesh = array_mesh
	multimesh_instance.multimesh = _multimesh

	_images_layer = Node2D.new()
	_images_layer.name = "ImagesLayer"
	_images_layer.z_index = -9
	add_child(_images_layer)

	# Запускаем фоновый поток загрузки
	_thread_stop = false
	_loader_thread = Thread.new()
	_loader_thread.start(_thread_load_loop)
	print("[THREAD] WallRenderer texture loader thread started")


func _exit_tree() -> void:
	# Корректная остановка потока
	_thread_stop = true
	_thread_semaphore.post()  # разбудить поток, чтобы он проверил флаг и вышел
	if _loader_thread != null and _loader_thread.is_started():
		_loader_thread.wait_to_finish()
		_loader_thread = null
	print("[THREAD] WallRenderer texture loader thread stopped")


func setup(data: WallData, side: String, purchases_enabled: bool = false) -> void:
	wall_data = data
	side_id = side
	allow_purchases = purchases_enabled


# ─────────────────────────────────────────────────────────────────────────────
# THREAD LOOP — выполняется в фоновом потоке
# Разрешено: Image.load, Image.resize, чтение файлов
# Запрещено: Node, ImageTexture, любые Godot-объекты владеющие GPU
# ─────────────────────────────────────────────────────────────────────────────
func _thread_load_loop() -> void:
	while true:
		_thread_semaphore.wait()  # спим пока нет задач
		if _thread_stop:
			break

		# Берём пачку задач
		_thread_mutex.lock()
		var tasks: Array = []
		var take: int = mini(_thread_queue.size(), MAX_THREAD_TASKS_PER_ITER)
		for _i in range(take):
			tasks.append(_thread_queue.pop_front())
		_thread_mutex.unlock()

		for task in tasks:
			if _thread_stop:
				break
			var path: String = str(task.get("path", ""))
			var key: String = str(task.get("key", ""))
			if path.is_empty() or key.is_empty():
				continue
			if DEBUG_LOG:
				print("[THREAD] loading image: ", path)
			var result: Dictionary = _thread_load_image(path)
			result["key"] = key
			_results_mutex.lock()
			_thread_results.append(result)
			_results_mutex.unlock()


func _thread_load_image(img_path: String) -> Dictionary:
	## THREAD: загружает Image и делает resize. Возвращает {image, success}.
	const TARGET_SIZE: int = 48
	var img: Image = Image.new()
	var err: Error

	if img_path.begins_with("res://") or img_path.begins_with("user://"):
		err = img.load(img_path)
		if err != OK:
			# Файл есть, но не PNG — пробуем через raw bytes (только user://)
			if img_path.begins_with("user://") and FileAccess.file_exists(img_path):
				var f: FileAccess = FileAccess.open(img_path, FileAccess.READ)
				if f != null:
					var bytes: PackedByteArray = f.get_buffer(f.get_length())
					f.close()
					err = img.load_png_from_buffer(bytes)
					if err != OK:
						err = img.load_jpg_from_buffer(bytes)
			if err != OK:
				return {"image": null, "success": false}
	else:
		# Абсолютный путь
		err = img.load(img_path)
		if err != OK:
			return {"image": null, "success": false}

	if img.is_empty():
		return {"image": null, "success": false}

	var src_w: int = img.get_width()
	var src_h: int = img.get_height()
	if src_w != TARGET_SIZE or src_h != TARGET_SIZE:
		img.resize(TARGET_SIZE, TARGET_SIZE, Image.INTERPOLATE_LANCZOS)
		if DEBUG_LOG:
			print("[THREAD] resized ", img_path, " from ", src_w, "x", src_h, " to 48x48")

	return {"image": img, "success": true}


# ─────────────────────────────────────────────────────────────────────────────
# ПОСТАНОВКА ЗАДАЧИ В THREAD
# ─────────────────────────────────────────────────────────────────────────────
func _enqueue_thread_load(img_path: String) -> void:
	if _thread_stop or img_path.is_empty():
		return
	if _texture_cache.has(img_path):
		return  # уже закэшировано
	_thread_mutex.lock()
	var already: bool = _thread_queued_paths.has(img_path)
	if not already:
		_thread_queued_paths[img_path] = true
		_thread_queue.append({"path": img_path, "key": img_path})
	_thread_mutex.unlock()
	if not already:
		_thread_semaphore.post()  # будим поток


# ─────────────────────────────────────────────────────────────────────────────
# ПРИМЕНЕНИЕ РЕЗУЛЬТАТОВ ИЗ ПОТОКА — вызывается в _process (main thread)
# ─────────────────────────────────────────────────────────────────────────────
func _apply_thread_results() -> void:
	if _thread_results.is_empty():
		return

	_results_mutex.lock()
	var batch: Array = []
	var take: int = mini(_thread_results.size(), MAX_RESULTS_PER_FRAME)
	for _i in range(take):
		batch.append(_thread_results.pop_front())
	_results_mutex.unlock()

	for res in batch:
		var key: String = str(res.get("key", ""))
		# Убираем из "в процессе загрузки"
		_thread_mutex.lock()
		_thread_queued_paths.erase(key)
		_thread_mutex.unlock()

		if not res.get("success", false):
			if DEBUG_LOG:
				print("[THREAD] FAIL image: ", key)
			continue

		var img: Image = res.get("image", null)
		if img == null or img.is_empty():
			continue

		# MAIN THREAD: создаём ImageTexture (GPU-объект, нельзя в потоке)
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		_texture_cache[key] = tex
		_touch_texture_cache_key(key)
		_evict_texture_cache_if_needed()
		if DEBUG_LOG:
			print("[MAIN] texture created and cached: ", key)

		# Применяем ко всем видимым сегментам, которым нужна эта текстура
		_apply_texture_to_segments_by_path(key)


func _apply_texture_to_segments_by_path(img_path: String) -> void:
	## Находим все видимые сегменты с нужным путём и применяем текстуру.
	for i in range(_segment_ids.size()):
		if i >= _segment_sides.size():
			continue
		var seg_id: String = _segment_ids[i]
		var current_side: String = _segment_sides[i]

		var path_for_seg: String = ""
		if _preview_image_paths.has(seg_id) and _preview_image_paths[seg_id] != "":
			path_for_seg = _preview_image_paths[seg_id]
		elif wall_data != null:
			path_for_seg = wall_data.get_face_image_path(seg_id, current_side)

		if path_for_seg == img_path:
			_update_single_image_sprite(seg_id, i, current_side)


# ─────────────────────────────────────────────────────────────────────────────
# ОСНОВНОЙ _process
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	# 1. Применяем результаты из потока (main thread)
	_apply_thread_results()
	# 2. Старая очередь: отправляем задачи в поток (вместо синхронного load)
	_process_texture_load_queue()

	if _multimesh != null and _multimesh.instance_count > HEAVY_MESH_SKIP_PROCESS:
		return
	_process_side_changes(delta)

	if _gs_cache == null:
		_gs_cache = get_node_or_null("/root/GameState")
	var breathing_enabled: bool = _gs_cache != null and bool(_gs_cache.get("wall_breathing_enabled"))

	if not breathing_enabled:
		if _breathing_was_enabled:
			_breathing_was_enabled = false
			var cnt: int = _multimesh.instance_count
			for i in range(cnt):
				if i < _transforms.size():
					_multimesh.set_instance_transform_2d(i, _transforms[i])
		return

	_breathing_was_enabled = true
	_breathing_time += delta
	var cnt2: int = _multimesh.instance_count
	for i in range(cnt2):
		if i >= _breathing_params.size():
			continue
		var base_transform: Transform2D = _transforms[i]
		var params: Dictionary = _breathing_params[i]
		var phase_x: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_x
		var phase_y: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_y
		var final_transform: Transform2D = base_transform
		final_transform.origin += Vector2(sin(phase_x) * params.amplitude_x, cos(phase_y) * params.amplitude_y)
		_multimesh.set_instance_transform_2d(i, final_transform)
		if i < _segment_ids.size():
			var seg_id := _segment_ids[i]
			if _segment_sprites.has(seg_id):
				var sprite: Sprite2D = _segment_sprites[seg_id]
				if sprite:
					sprite.position = final_transform.origin


# ─────────────────────────────────────────────────────────────────────────────
# ОЧЕРЕДЬ ЗАГРУЗКИ — теперь отправляет в Thread вместо синхронного load
# ─────────────────────────────────────────────────────────────────────────────
func _process_texture_load_queue() -> void:
	if _texture_load_queue.is_empty():
		return
	var budget: int = MAX_TEXTURE_LOADS_PER_FRAME_VIEW if allow_purchases else MAX_TEXTURE_LOADS_PER_FRAME_GAME
	while budget > 0 and not _texture_load_queue.is_empty():
		var req: Dictionary = _texture_load_queue.pop_front()
		var qkey0: String = str(req.get("qkey", ""))
		if qkey0 != "":
			_texture_load_queued_keys.erase(qkey0)
		var seg_id: String = str(req.get("segment_id", ""))
		var img_path: String = str(req.get("img_path", ""))
		var idx: int = int(req.get("idx", -1))
		var seg_side: String = str(req.get("segment_side", ""))
		if seg_id == "" or img_path == "" or idx < 0:
			continue
		if not _segment_index.has(seg_id):
			continue  # сегмент ушёл из видимости
		if _texture_cache.has(img_path):
			_touch_texture_cache_key(img_path)
			_update_single_image_sprite(seg_id, idx, seg_side)
			budget -= 1
			continue
		# Отправляем в Thread (не синхронный load)
		_enqueue_thread_load(img_path)
		budget -= 1


# ─────────────────────────────────────────────────────────────────────────────
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (без изменения публичного API)
# ─────────────────────────────────────────────────────────────────────────────

func _remember_tile_side(segment_id: String, side_name: String) -> void:
	if segment_id.is_empty() or side_name.strip_edges().is_empty():
		return
	_last_known_tile_side[segment_id] = side_name


func _effective_face_data_for_ownership(segment_id: String, visual_side: String) -> Dictionary:
	if wall_data == null:
		return {}
	var fd: Dictionary = wall_data.get_face_data(segment_id, visual_side)
	if str(fd.get("owner", "")).strip_edges() != "":
		return fd
	for s in SIDES:
		var fd2: Dictionary = wall_data.get_face_data(segment_id, s)
		if str(fd2.get("owner", "")).strip_edges() != "":
			return fd2
	return fd


func _effective_image_side_for_texture(segment_id: String, visual_side: String) -> String:
	if wall_data == null:
		return visual_side
	var p0: String = wall_data.get_face_image_path(segment_id, visual_side).strip_edges()
	if p0 != "":
		return visual_side
	return visual_side


func _visual_face_data(segment_id: String, visual_side: String) -> Dictionary:
	if wall_data == null:
		return {}
	return wall_data.get_face_data(segment_id, visual_side)


func _visual_face_image_path(segment_id: String, visual_side: String) -> String:
	if wall_data == null:
		return ""
	return wall_data.get_face_image_path(segment_id, visual_side).strip_edges()


func update_visible_area(min_x: int, max_x: int, min_y: int, max_y: int) -> void:
	var width: int = max_x - min_x + 1
	var height: int = max_y - min_y + 1
	var total_segments: int = width * height
	if total_segments > MAX_VISIBLE_INSTANCES:
		var scale: float = sqrt(float(MAX_VISIBLE_INSTANCES) / float(total_segments))
		var cx: float = (float(min_x) + float(max_x)) * 0.5
		var cy: float = (float(min_y) + float(max_y)) * 0.5
		var half_w: float = (float(width) * 0.5) * scale
		var half_h: float = (float(height) * 0.5) * scale
		min_x = int(floor(cx - half_w))
		max_x = int(ceil(cx + half_w))
		min_y = int(floor(cy - half_h))
		max_y = int(ceil(cy + half_h))
		if min_x > max_x:
			var tmp: int = min_x; min_x = max_x; max_x = tmp
		if min_y > max_y:
			var tmp2: int = min_y; min_y = max_y; max_y = tmp2
		width = max_x - min_x + 1
		height = max_y - min_y + 1
		total_segments = width * height

	visible_min_x = min_x
	visible_max_x = max_x
	visible_min_y = min_y
	visible_max_y = max_y

	var old_sides: Dictionary = {}
	var old_timers: Dictionary = {}
	var old_intervals: Dictionary = {}
	for i in range(_segment_ids.size()):
		if i < _segment_sides.size():
			old_sides[_segment_ids[i]] = _segment_sides[i]
		if i < _side_change_timers.size():
			old_timers[_segment_ids[i]] = _side_change_timers[i]
		if i < _side_change_intervals.size():
			old_intervals[_segment_ids[i]] = _side_change_intervals[i]

	_multimesh.instance_count = total_segments
	_transforms.clear()
	_segment_ids.clear()
	_breathing_params.clear()
	_segment_sides.clear()
	_side_change_timers.clear()
	_side_change_intervals.clear()
	_segment_index.clear()
	_transforms.resize(total_segments)
	_segment_ids.resize(total_segments)
	_breathing_params.resize(total_segments)
	_segment_sides.resize(total_segments)
	_side_change_timers.resize(total_segments)
	_side_change_intervals.resize(total_segments)

	var _sm_cached: Node = get_node_or_null("/root/SeedManager")
	var _gs_seed_cached: int = int(_sm_cached.get("global_seed")) if _sm_cached != null else 0
	var idx: int = 0
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var segment_id: String = "%d_%d" % [x, y]
			var pos: Vector2 = Vector2(x * SEGMENT_SIZE, y * SEGMENT_SIZE)
			var seed_hash: int = int(hash(str(_gs_seed_cached) + "::" + segment_id)) & 0x7FFFFFFF
			_shared_rng.seed = seed_hash if seed_hash != 0 else 1

			var current_side: String
			if old_sides.has(segment_id):
				current_side = old_sides[segment_id]
				_side_change_timers[idx] = old_timers.get(segment_id, 0.0)
				_side_change_intervals[idx] = old_intervals.get(segment_id, _shared_rng.randf_range(30.0, 90.0))
			else:
				if _last_known_tile_side.has(segment_id):
					current_side = str(_last_known_tile_side[segment_id])
					var ci_r: float = _shared_rng.randf_range(30.0, 90.0)
					_side_change_intervals[idx] = ci_r
					_side_change_timers[idx] = _shared_rng.randf_range(0.0, ci_r * 0.3)
				else:
					current_side = SIDES[_shared_rng.randi() % SIDES.size()]
					var ci: float = _shared_rng.randf_range(30.0, 90.0)
					_side_change_intervals[idx] = ci
					_side_change_timers[idx] = _shared_rng.randf_range(0.0, ci * 0.3)

			_segment_sides[idx] = current_side
			_remember_tile_side(segment_id, current_side)

			var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, current_side)
			var color: Color = _get_segment_color_by_side(current_side, face_data, segment_id)
			var transform: Transform2D = Transform2D.IDENTITY
			transform.origin = pos
			_transforms[idx] = transform
			_segment_ids[idx] = segment_id
			_segment_index[segment_id] = idx
			_breathing_params[idx] = {
				"phase": _shared_rng.randf() * TAU,
				"speed_factor": _shared_rng.randf_range(0.6, 1.4),
				"amplitude_x": _shared_rng.randf_range(0.3, 0.8) * BASE_BREATHING_AMPLITUDE,
				"amplitude_y": _shared_rng.randf_range(0.5, 1.2) * BASE_BREATHING_AMPLITUDE,
				"offset_x": _shared_rng.randf_range(-0.5, 0.5),
				"offset_y": _shared_rng.randf_range(-0.5, 0.5)
			}
			_multimesh.set_instance_transform_2d(idx, transform)
			_multimesh.set_instance_color(idx, color)
			idx += 1

	_update_image_sprites()


func _process_side_changes(delta: float) -> void:
	if pause_side_switching:
		return
	for i in range(_multimesh.instance_count):
		if i >= _side_change_timers.size() or i >= _segment_sides.size():
			continue
		_side_change_timers[i] += delta
		if _side_change_timers[i] >= _side_change_intervals[i]:
			var current_side: String = _segment_sides[i]
			var new_side: String = current_side
			var available_sides: Array[String] = []
			for side in SIDES:
				if side != current_side:
					available_sides.append(side)
			if available_sides.size() > 0:
				if _gs_cache == null:
					_gs_cache = get_node_or_null("/root/GameState")
				var sm2: Node = get_node_or_null("/root/SeedManager")
				var gs_seed2: int = int(sm2.get("global_seed")) if sm2 != null else 0
				var seed_hash: int = int(hash(str(gs_seed2) + "::" + _segment_ids[i] + "::sidepick")) & 0x7FFFFFFF
				_shared_rng.seed = seed_hash if seed_hash != 0 else 1
				new_side = available_sides[_shared_rng.randi() % available_sides.size()]
			_segment_sides[i] = new_side
			_remember_tile_side(_segment_ids[i], new_side)
			var segment_id2: String = _segment_ids[i]
			var sm3: Node = get_node_or_null("/root/SeedManager")
			var gs_seed3: int = int(sm3.get("global_seed")) if sm3 != null else 0
			var seed_iv: int = int(hash(str(gs_seed3) + "::" + segment_id2 + "::interval")) & 0x7FFFFFFF
			_shared_rng.seed = seed_iv if seed_iv != 0 else 1
			_side_change_intervals[i] = _shared_rng.randf_range(30.0, 90.0)
			_side_change_timers[i] = 0.0
			var face_data: Dictionary = _effective_face_data_for_ownership(segment_id2, new_side)
			var color: Color = _get_segment_color_by_side(new_side, face_data, segment_id2)
			_multimesh.set_instance_color(i, color)
			_request_image_sprite_update(segment_id2, i, new_side)


func update_segment(segment_id: String) -> void:
	if wall_data == null or _multimesh == null:
		return
	var idx: int = -1
	if _segment_index.has(segment_id):
		idx = int(_segment_index[segment_id])
	else:
		for i in range(_segment_ids.size()):
			if _segment_ids[i] == segment_id:
				idx = i
				_segment_index[segment_id] = i
				break
	if idx < 0 or idx >= _multimesh.instance_count:
		return
	var current_side: String = _segment_sides[idx] if idx < _segment_sides.size() else side_id
	var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, current_side)
	var color: Color = _get_segment_color_by_side(current_side, face_data, segment_id)
	_multimesh.set_instance_color(idx, color)
	_request_image_sprite_update(segment_id, idx, current_side)


func force_segment_visual_side(segment_id: String, forced_side: String) -> void:
	if wall_data == null or _multimesh == null:
		return
	var side_norm: String = str(forced_side).strip_edges().to_lower()
	if side_norm == "" or side_norm not in SIDES:
		return
	_remember_tile_side(segment_id, side_norm)
	if not _segment_index.has(segment_id):
		return
	var idx: int = int(_segment_index[segment_id])
	if idx < 0 or idx >= _multimesh.instance_count:
		return
	if idx < _segment_sides.size():
		_segment_sides[idx] = side_norm
	if idx < _side_change_timers.size():
		_side_change_timers[idx] = 0.0
	var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, side_norm)
	var color: Color = _get_segment_color_by_side(side_norm, face_data, segment_id)
	_multimesh.set_instance_color(idx, color)
	_request_image_sprite_update(segment_id, idx, side_norm)


func _request_image_sprite_update(segment_id: String, idx: int, segment_side: String) -> void:
	if idx < 0 or idx >= _segment_ids.size():
		return
	var img_path: String = ""
	if _preview_image_paths.has(segment_id) and _preview_image_paths[segment_id] != "":
		img_path = _preview_image_paths[segment_id]
	elif wall_data != null:
		img_path = wall_data.get_face_image_path(segment_id, segment_side).strip_edges()
	if img_path == "":
		if _segment_sprites.has(segment_id):
			_release_sprite(segment_id)
		return
	if _texture_cache.has(img_path):
		_update_single_image_sprite(segment_id, idx, segment_side)
		return
	var qkey: String = "%s|%s" % [segment_id, img_path]
	if not _texture_load_queued_keys.has(qkey):
		_texture_load_queued_keys[qkey] = true
		_texture_load_queue.append({
			"segment_id": segment_id,
			"idx": idx,
			"segment_side": segment_side,
			"img_path": img_path,
			"qkey": qkey,
		})
		if _texture_load_queue.size() > MAX_TEXTURE_QUEUE_LENGTH:
			var drop: Dictionary = _texture_load_queue.pop_front()
			var dk: String = str(drop.get("qkey", ""))
			if dk != "":
				_texture_load_queued_keys.erase(dk)


func _get_segment_color_by_side(segment_side: String, face_data: Dictionary, segment_id: String = "") -> Color:
	var base_color: Color = _get_side_color(segment_side)
	var owner: String = str(face_data.get("owner", "")).strip_edges()
	var is_owned: bool = owner != ""
	if is_owned:
		base_color = base_color.lightened(0.15)

	if dim_other_segments and segment_id != "":
		var is_highlighted: bool = segment_id in _highlighted_segment_ids
		var gs: Node = get_node_or_null("/root/GameState")
		var buyer_uid: String = str(gs.get("player_uid")) if gs != null else ""
		var is_my_segment: bool = owner == buyer_uid
		if not is_my_segment and segment_id != "" and wall_data != null and buyer_uid != "":
			for s in SIDES:
				var ofd: Dictionary = wall_data.get_face_data(segment_id, s)
				if str(ofd.get("owner", "")) == buyer_uid:
					is_my_segment = true
					break
		if not is_highlighted and not is_my_segment:
			base_color = base_color.darkened(0.6)
			base_color.a *= 0.4

	if segment_id != "" and segment_id in _highlighted_segment_ids:
		base_color = base_color.lerp(Color(1.0, 1.0, 1.0, 0.8), 0.5)

	var has_visual_image: bool = _visual_face_image_path(segment_id, segment_side) != ""
	if has_visual_image:
		base_color.a = 0.0

	return base_color


func set_highlighted_segment(segment_id: String) -> void:
	set_highlighted_segments([segment_id] if segment_id != "" else [])


func set_highlighted_segments(segment_ids: Array) -> void:
	var new_ids: Array[String] = []
	for id_val in segment_ids:
		var s: String = str(id_val)
		if s != "" and s not in new_ids:
			new_ids.append(s)
	var old_ids: Array[String] = _highlighted_segment_ids.duplicate()
	_highlighted_segment_ids = new_ids
	for sid in old_ids:
		if sid not in new_ids:
			update_segment(sid)
	for sid in new_ids:
		update_segment(sid)


func clear_texture_cache() -> void:
	_texture_cache.clear()
	_texture_cache_order.clear()
	_texture_load_queue.clear()
	_texture_load_queued_keys.clear()
	# Очищаем также thread-очередь
	_thread_mutex.lock()
	_thread_queue.clear()
	_thread_queued_paths.clear()
	_thread_mutex.unlock()
	_results_mutex.lock()
	_thread_results.clear()
	_results_mutex.unlock()


func clear_highlight() -> void:
	if _highlighted_segment_ids.is_empty() and _preview_image_paths.is_empty():
		return
	var old_ids: Array[String] = _highlighted_segment_ids.duplicate()
	_highlighted_segment_ids.clear()
	_preview_image_paths.clear()
	for sid in old_ids:
		update_segment(sid)
	_update_image_sprites()


func refresh_images_from_wall_data() -> void:
	clear_texture_cache()
	_update_image_sprites()
	print("[APPLY] wall image sprites refreshed from WallData (visible instances=", _multimesh.instance_count, ")")


func set_dim_other_segments(enabled: bool) -> void:
	if dim_other_segments == enabled:
		return
	dim_other_segments = enabled
	for i in range(_multimesh.instance_count):
		if i < _segment_ids.size():
			update_segment(_segment_ids[i])


func set_preview_image_paths(paths: Dictionary) -> void:
	if DEBUG_LOG:
		print("WallRenderer: set_preview_image_paths вызван с ", paths.size(), " путями")
	_preview_image_paths.clear()
	for k in paths:
		var v: String = str(paths[k])
		if v != "":
			_preview_image_paths[str(k)] = v
	_update_image_sprites()
	for sid in _highlighted_segment_ids:
		update_segment(sid)


func _get_side_color(segment_side: String) -> Color:
	match segment_side:
		"front":   return Color(0.0, 0.8, 0.7)
		"back":    return Color(0.0, 0.5, 0.5)
		"left":    return Color(0.2, 0.7, 0.6)
		"right":   return Color(0.1, 0.6, 0.8)
		"top":     return Color(0.3, 0.9, 0.8)
		"bottom":  return Color(0.0, 0.4, 0.6)
		_:         return Color(0.0, 0.8, 0.7)


func handle_click(global_pos: Vector2, for_price_preview: bool = false) -> Dictionary:
	if wall_data == null:
		return {}
	if not for_price_preview and not allow_purchases:
		return {}
	var local_pos: Vector2 = to_local(global_pos)
	var seg_x: int = int(floor((local_pos.x + SEGMENT_SIZE * 0.5) / SEGMENT_SIZE))
	var seg_y: int = int(floor((local_pos.y + SEGMENT_SIZE * 0.5) / SEGMENT_SIZE))
	var segment_id: String = "%d_%d" % [seg_x, seg_y]
	if not _segment_index.has(segment_id):
		return {}
	var seg_height: float = wall_data.get_segment_height(segment_id)
	var gs2: Node = get_node_or_null("/root/GameState")
	if not for_price_preview and gs2 != null:
		var gate_y: float = float(gs2.get("max_height_reached"))
		if gs2.has_method("get_wall_height_gate"):
			gate_y = float(gs2.call("get_wall_height_gate"))
		if seg_height < gate_y:
			return {}
	var segment_side_name: String = side_id
	if _segment_index.has(segment_id):
		var ix: int = int(_segment_index[segment_id])
		if ix >= 0 and ix < _segment_sides.size():
			segment_side_name = str(_segment_sides[ix])
	var em: Node = get_node_or_null("/root/EconomyManager")
	var listing_price: int = int(wall_data.get_segment_price(segment_id))
	var fid: int = 0
	if em != null and em.has_method("get_listing_price_for_hit"):
		listing_price = int(em.call("get_listing_price_for_hit", side_id, segment_id, segment_side_name, wall_data))
	if em != null and em.has_method("face_id_from_wall_segment"):
		fid = int(em.call("face_id_from_wall_segment", side_id, segment_id, segment_side_name))
	return {
		"segment_id": segment_id,
		"side": side_id,
		"segment_side": segment_side_name,
		"price": listing_price,
		"height": seg_height,
		"face_id": fid
	}


func get_visible_segment_side(segment_id: String) -> String:
	if _segment_index.has(segment_id):
		var ix: int = int(_segment_index[segment_id])
		if ix >= 0 and ix < _segment_sides.size():
			return str(_segment_sides[ix])
	if _last_known_tile_side.has(segment_id):
		return str(_last_known_tile_side[segment_id])
	return ""


# ─────────────────────────────────────────────────────────────────────────────
# СПРАЙТЫ (Sprite2D поверх MultiMesh)
# ─────────────────────────────────────────────────────────────────────────────

func _get_or_create_sprite(segment_id: String) -> Sprite2D:
	if _segment_sprites.has(segment_id):
		var existing: Sprite2D = _segment_sprites[segment_id]
		if existing:
			existing.visible = true
			return existing
	var sprite: Sprite2D = null
	if _sprite_pool.size() > 0:
		sprite = _sprite_pool.pop_back()
	else:
		sprite = Sprite2D.new()
		sprite.centered = true
		sprite.name = "SegSprite_" + segment_id
		_images_layer.add_child(sprite)
	_segment_sprites[segment_id] = sprite
	sprite.visible = true
	return sprite


func _release_sprite(segment_id: String) -> void:
	if not _segment_sprites.has(segment_id):
		return
	var sprite: Sprite2D = _segment_sprites[segment_id]
	_segment_sprites.erase(segment_id)
	if sprite:
		sprite.visible = false
		_sprite_pool.append(sprite)


func _update_image_sprites() -> void:
	if wall_data == null and _preview_image_paths.is_empty():
		return
	var visible_ids: Dictionary = {}
	for seg_id in _segment_ids:
		visible_ids[seg_id] = true
	for seg_id in _segment_sprites.keys():
		if not visible_ids.has(seg_id):
			_release_sprite(seg_id)
	for i in range(_segment_ids.size()):
		var seg_id: String = _segment_ids[i]
		if i >= _segment_sides.size():
			continue
		var current_side: String = _segment_sides[i]
		var img_path: String = ""
		if _preview_image_paths.has(seg_id) and _preview_image_paths[seg_id] != "":
			img_path = _preview_image_paths[seg_id]
		elif wall_data != null:
			img_path = wall_data.get_face_image_path(seg_id, current_side)
		if img_path == "":
			if _segment_sprites.has(seg_id):
				_release_sprite(seg_id)
			continue
		if not _texture_cache.has(img_path):
			var qkey: String = "%s|%s" % [seg_id, img_path]
			if not _texture_load_queued_keys.has(qkey):
				_texture_load_queued_keys[qkey] = true
				_texture_load_queue.append({
					"segment_id": seg_id,
					"idx": i,
					"segment_side": current_side,
					"img_path": img_path,
					"qkey": qkey,
				})
				if _texture_load_queue.size() > MAX_TEXTURE_QUEUE_LENGTH:
					var drop: Dictionary = _texture_load_queue.pop_front()
					var dk: String = str(drop.get("qkey", ""))
					if dk != "":
						_texture_load_queued_keys.erase(dk)
			continue
		_update_single_image_sprite(seg_id, i, current_side)


func _touch_texture_cache_key(img_path: String) -> void:
	var ix: int = _texture_cache_order.find(img_path)
	if ix >= 0:
		_texture_cache_order.remove_at(ix)
	_texture_cache_order.append(img_path)


func _evict_texture_cache_if_needed() -> void:
	while _texture_cache_order.size() > MAX_TEXTURE_CACHE_ENTRIES:
		var oldest: String = _texture_cache_order.pop_front()
		_texture_cache.erase(oldest)


func _update_single_image_sprite(segment_id: String, idx: int, segment_side: String) -> void:
	if idx < 0 or idx >= _segment_ids.size():
		return
	var img_path: String = ""
	if _preview_image_paths.has(segment_id) and _preview_image_paths[segment_id] != "":
		img_path = _preview_image_paths[segment_id]
	elif wall_data != null:
		img_path = wall_data.get_face_image_path(segment_id, segment_side)
	if img_path == "":
		if _segment_sprites.has(segment_id):
			_release_sprite(segment_id)
		return
	var tex: Texture2D = _texture_cache.get(img_path, null)
	if tex == null:
		# Текстура ещё не готова — отправляем в очередь → Thread
		_enqueue_thread_load(img_path)
		return
	if DEBUG_LOG:
		print("[MAIN] applying texture to segment: ", segment_id, " path=", img_path)
	var sprite: Sprite2D = _get_or_create_sprite(segment_id)
	sprite.texture = tex
	if _gs_cache == null:
		_gs_cache = get_node_or_null("/root/GameState")
	var breathing_enabled2: bool = _gs_cache != null and bool(_gs_cache.get("wall_breathing_enabled"))
	var current_transform: Transform2D
	if breathing_enabled2 and idx < _multimesh.instance_count:
		current_transform = _multimesh.get_instance_transform_2d(idx)
	else:
		current_transform = _transforms[idx]
	sprite.position = current_transform.origin
