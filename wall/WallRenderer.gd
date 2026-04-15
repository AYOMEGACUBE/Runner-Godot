extends Node2D
class_name WallRenderer
# ============================================================================
# WallRenderer.gd — Оптимизированный рендерер стены (MultiMeshInstance2D)
# ============================================================================
# THREAD-АРХИТЕКТУРА:
#   ЭТАП 1 (Thread) : Image.load() + resize → Image
#   ЭТАП 2 (Main)   : ImageTexture.create_from_image() + кэш + Sprite2D
#
# STREAM CONTROL:
#   • Приоритетная очередь (priority = dist к камере)
#   • MAX_ACTIVE_LOADING одновременно в потоке
#   • MAX_STREAM_QUEUE_SIZE  — ограничение очереди
#   • MAX_TEXTURES_IN_MEMORY — LRU eviction
#   • UNLOAD_IDLE_SEC       — выгрузка неиспользуемых текстур
#   • MAX_APPLY_PER_FRAME   — бюджет применения за кадр
#
# THREAD SAFETY:
#   • _thread_queue, _thread_queued_paths, _active_loading_count → _thread_mutex
#   • _thread_results                                            → _results_mutex
#   • _texture_cache, _texture_cache_order, _texture_last_used  → main thread only
#
# CACHE API: все операции через _cache_get / _cache_set / _cache_evict
# INCREMENTAL: _update_image_sprites() обрабатывает MAX_SPRITE_UPDATES_PER_FRAME за кадр
# ============================================================================

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")
const SEGMENT_SIZE: int    = WorldSegmentGrid.SEGMENT_SIZE_PX
const SEGMENTS_PER_SIDE: int = WorldSegmentGrid.SEGMENTS_PER_FACE_AXIS

var multimesh_instance: MultiMeshInstance2D = null
var wall_data: WallData   = null
var side_id: String       = "front"
var allow_purchases: bool = false

# Видимая область (в сегментах)
var visible_min_x: int = 0
var visible_max_x: int = 0
var visible_min_y: int = 0
var visible_max_y: int = 0

# Пул трансформ
var _transforms: Array[Transform2D] = []
var _segment_ids: Array[String]     = []
var _multimesh: MultiMesh           = null

# Дыхание сегментов
var _breathing_params: Array[Dictionary] = []
var _breathing_time: float               = 0.0
const BASE_BREATHING_AMPLITUDE: float   = 1.2
const BASE_BREATHING_SPEED: float       = PI * 0.4

# Смена сторон
var _segment_sides: Array[String]      = []
var _side_change_timers: Array[float]  = []
var _side_change_intervals: Array[float] = []
const SIDES: Array[String] = ["front", "back", "left", "right", "top", "bottom"]
const MAX_VISIBLE_INSTANCES: int  = 10000
const HEAVY_MESH_SKIP_PROCESS: int = 500000

var _shared_rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Спрайты поверх MultiMesh
var _images_layer: Node2D          = null
var _segment_sprites: Dictionary   = {}   # segment_id -> Sprite2D
var _sprite_pool: Array[Sprite2D]  = []
var _segment_index: Dictionary     = {}   # segment_id -> индекс
var _last_known_tile_side: Dictionary = {}

# Подсветка / предпросмотр
var _highlighted_segment_ids: Array[String] = []
var pause_side_switching: bool  = false
var dim_other_segments: bool    = false
var _preview_image_paths: Dictionary = {}

# ─────────────────────────────────────────────────────────────────────────────
# КЭШИ ТЕКСТУР — LRU
# ─────────────────────────────────────────────────────────────────────────────
var _texture_cache: Dictionary       = {}   # img_path -> Texture2D
var _texture_cache_order: Array[String] = [] # LRU: oldest → newest
## Время последнего использования каждой текстуры (img_path -> float)
var _texture_last_used: Dictionary   = {}
const MAX_TEXTURES_IN_MEMORY: int    = 384   # Memory Guard
const UNLOAD_IDLE_SEC: float         = 30.0  # выгружать если не использована N сек
var _unload_timer: float             = 0.0
const UNLOAD_CHECK_INTERVAL: float   = 5.0

# ─────────────────────────────────────────────────────────────────────────────
# СОВМЕСТИМАЯ ОЧЕРЕДЬ (main-thread feeder → thread)
# ─────────────────────────────────────────────────────────────────────────────
var _texture_load_queue: Array[Dictionary]    = []
var _texture_load_queued_keys: Dictionary     = {} # qkey -> true
const MAX_TEXTURE_LOADS_PER_FRAME_GAME: int  = 2
const MAX_TEXTURE_LOADS_PER_FRAME_VIEW: int  = 24
const MAX_TEXTURE_QUEUE_LENGTH: int          = 500  # Stream Control: hard cap

# ─────────────────────────────────────────────────────────────────────────────
# STREAM CONTROL
# ─────────────────────────────────────────────────────────────────────────────
const MAX_ACTIVE_LOADING: int   = 8    # одновременно в потоке
const MAX_STREAM_QUEUE_SIZE: int = 500  # лимит приоритетной очереди потока
const MAX_APPLY_PER_FRAME: int  = 8    # бюджет ImageTexture.create в кадр

## Текущая позиция камеры для вычисления приоритетов (px)
var _camera_position: Vector2 = Vector2.ZERO
## Счётчик активных задач в потоке (доступ только через _thread_mutex)
var _active_loading_count: int = 0

# ─────────────────────────────────────────────────────────────────────────────
# INCREMENTAL SPRITE UPDATE
# ─────────────────────────────────────────────────────────────────────────────
## Курсор инкрементального обхода _segment_ids в _update_image_sprites
var _sprite_update_cursor: int = 0
const MAX_SPRITE_UPDATES_PER_FRAME: int = 50

# ─────────────────────────────────────────────────────────────────────────────
# MEMORY GUARD (MB-based)
# ─────────────────────────────────────────────────────────────────────────────
const MAX_TEXTURE_MEMORY_MB: float = 120.0  # hard cap
const TEX_BYTES_ESTIMATE: int      = 48 * 48 * 4  # RGBA 48x48

# ─────────────────────────────────────────────────────────────────────────────
# THREAD
# ─────────────────────────────────────────────────────────────────────────────
## Приоритетная очередь задач: [{path, key, priority}]
var _thread_queue: Array = []
## Результаты из потока: [{key, image, success}]
var _thread_results: Array = []
## Пути, уже отправленные в поток
var _thread_queued_paths: Dictionary = {}

var _thread_mutex: Mutex    = Mutex.new()
var _results_mutex: Mutex   = Mutex.new()
var _loader_thread: Thread  = null
var _thread_stop: bool      = false
var _thread_semaphore: Semaphore = Semaphore.new()
const MAX_THREAD_TASKS_PER_ITER: int = 4

# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────
@export var DEBUG_LOG: bool = false
var _dbg_cache_hits: int   = 0
var _dbg_cache_misses: int = 0
var _dbg_dropped: int      = 0
var _dbg_log_timer: float  = 0.0
const DBG_LOG_INTERVAL: float = 5.0

# Кэш GameState
var _gs_cache: Node        = null
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
		Vector3(-half_size, -half_size, 0), Vector3(half_size, -half_size, 0),
		Vector3(half_size, half_size, 0),   Vector3(-half_size, half_size, 0)
	])
	arrays[Mesh.ARRAY_INDEX]  = PackedInt32Array([0, 1, 2, 0, 2, 3])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,1)
	])
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_multimesh.mesh = array_mesh
	multimesh_instance.multimesh = _multimesh

	_images_layer = Node2D.new()
	_images_layer.name = "ImagesLayer"
	_images_layer.z_index = -9
	add_child(_images_layer)

	_thread_stop = false
	_loader_thread = Thread.new()
	_loader_thread.start(_thread_load_loop)
	print("[THREAD] WallRenderer texture loader thread STARTED")


func _exit_tree() -> void:
	_thread_stop = true
	_thread_semaphore.post()
	if _loader_thread != null and _loader_thread.is_started():
		_loader_thread.wait_to_finish()
		_loader_thread = null
	print("[THREAD] WallRenderer texture loader thread STOPPED")


func setup(data: WallData, side: String, purchases_enabled: bool = false) -> void:
	wall_data       = data
	side_id         = side
	allow_purchases = purchases_enabled


# ─────────────────────────────────────────────────────────────────────────────
# THREAD LOOP
# Разрешено: Image.load, Image.resize, FileAccess
# Запрещено: Node, ImageTexture, GPU-объекты
# ─────────────────────────────────────────────────────────────────────────────
func _thread_load_loop() -> void:
	while true:
		_thread_semaphore.wait()
		if _thread_stop:
			break

		_thread_mutex.lock()
		var tasks: Array = []
		# Берём задачи с наибольшим приоритетом (очередь уже сортирована по убыванию)
		var take: int = mini(_thread_queue.size(), MAX_THREAD_TASKS_PER_ITER)
		for _i in range(take):
			tasks.append(_thread_queue.pop_front())
		_thread_mutex.unlock()

		for task in tasks:
			if _thread_stop:
				break
			var path: String = str(task.get("path", ""))
			var key: String  = str(task.get("key",  ""))
			if path.is_empty() or key.is_empty():
				continue
			if DEBUG_LOG:
				print("[THREAD] loading: ", path)
			var result: Dictionary = _thread_load_image(path)
			result["key"] = key
			_results_mutex.lock()
			_thread_results.append(result)
			_results_mutex.unlock()


func _thread_load_image(img_path: String) -> Dictionary:
	const TARGET_SIZE: int = 48
	var img: Image = Image.new()
	var err: Error

	if img_path.begins_with("res://") or img_path.begins_with("user://"):
		err = img.load(img_path)
		if err != OK and img_path.begins_with("user://") and FileAccess.file_exists(img_path):
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
		err = img.load(img_path)
		if err != OK:
			return {"image": null, "success": false}

	if img.is_empty():
		return {"image": null, "success": false}

	var sw: int = img.get_width()
	var sh: int = img.get_height()
	if sw != TARGET_SIZE or sh != TARGET_SIZE:
		img.resize(TARGET_SIZE, TARGET_SIZE, Image.INTERPOLATE_LANCZOS)

	return {"image": img, "success": true}


# ─────────────────────────────────────────────────────────────────────────────
# CACHE API — единственная точка доступа к кэшу текстур (main thread only)
# ─────────────────────────────────────────────────────────────────────────────
func _cache_get(img_path: String) -> Texture2D:
	var tex: Variant = _texture_cache.get(img_path, null)
	if tex != null:
		_texture_last_used[img_path] = Time.get_ticks_msec() * 0.001
		_touch_texture_cache_key(img_path)
		_dbg_cache_hits += 1
		return tex as Texture2D
	return null


func _cache_set(img_path: String, tex: Texture2D) -> void:
	_texture_cache[img_path] = tex
	_texture_last_used[img_path] = Time.get_ticks_msec() * 0.001
	_touch_texture_cache_key(img_path)
	_evict_texture_cache_if_needed()


func _cache_evict(img_path: String) -> void:
	_texture_cache.erase(img_path)
	_texture_last_used.erase(img_path)
	var ix: int = _texture_cache_order.find(img_path)
	if ix >= 0:
		_texture_cache_order.remove_at(ix)


# ─────────────────────────────────────────────────────────────────────────────
# STREAM CONTROL: постановка задачи в Thread с приоритетом
# ─────────────────────────────────────────────────────────────────────────────
func _enqueue_thread_load(img_path: String, priority: float = 0.0) -> void:
	if _thread_stop or img_path.is_empty():
		return
	# Проверяем кэш ДО мьютекса — main thread only, безопасно
	if _cache_get(img_path) != null:
		return
	_thread_mutex.lock()
	var already: bool = _thread_queued_paths.has(img_path)
	if not already:
		if _thread_queue.size() >= MAX_STREAM_QUEUE_SIZE:
			# Вытесняем последнюю (наименее приоритетную) задачу
			var min_idx: int = _thread_queue.size() - 1
			var dropped_path: String = str(_thread_queue[min_idx].get("key", ""))
			_thread_queue.remove_at(min_idx)
			if dropped_path != "":
				_thread_queued_paths.erase(dropped_path)
				_active_loading_count = maxi(0, _active_loading_count - 1)
			_dbg_dropped += 1
		_thread_queued_paths[img_path] = true
		# Вставляем по приоритету (убывание: высокий → начало)
		var inserted: bool = false
		for i in range(_thread_queue.size()):
			if float(_thread_queue[i].get("priority", 0.0)) < priority:
				_thread_queue.insert(i, {"path": img_path, "key": img_path, "priority": priority})
				inserted = true
				break
		if not inserted:
			_thread_queue.append({"path": img_path, "key": img_path, "priority": priority})
		_active_loading_count += 1
	var has_work: bool = _thread_queue.size() > 0
	_thread_mutex.unlock()
	# Semaphore.post() только если есть работа — защита от spurious wakeup
	if not already and has_work:
		_thread_semaphore.post()


func _calc_priority(seg_id: String) -> float:
	## Ближе к камере = выше приоритет. Видимые сегменты получают +большой бонус.
	var coords: PackedStringArray = seg_id.split("_")
	if coords.size() < 2:
		return 0.0
	var wx: float = float(int(coords[0])) * SEGMENT_SIZE
	var wy: float = float(int(coords[1])) * SEGMENT_SIZE
	var dist: float = _camera_position.distance_to(Vector2(wx, wy))
	var is_visible: bool = _segment_index.has(seg_id)
	var base: float = 1.0 / (1.0 + dist * 0.001)
	return base + (1.0 if is_visible else 0.0)


# ─────────────────────────────────────────────────────────────────────────────
# ПРИМЕНЕНИЕ РЕЗУЛЬТАТОВ ИЗ ПОТОКА (Main Thread)
# ─────────────────────────────────────────────────────────────────────────────
func _apply_thread_results() -> void:
	if _thread_results.is_empty():
		return
	_results_mutex.lock()
	var batch: Array = []
	var take: int = mini(_thread_results.size(), MAX_APPLY_PER_FRAME)
	for _i in range(take):
		batch.append(_thread_results.pop_front())
	_results_mutex.unlock()

	for res in batch:
		var key: String = str(res.get("key", ""))
		_thread_mutex.lock()
		_thread_queued_paths.erase(key)
		_active_loading_count = maxi(0, _active_loading_count - 1)
		_thread_mutex.unlock()

		if not res.get("success", false):
			if DEBUG_LOG:
				print("[THREAD] FAIL: ", key)
			continue
		var img: Image = res.get("image", null)
		if img == null or img.is_empty():
			continue

		# MAIN THREAD: только здесь создаём GPU-объект
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		_cache_set(key, tex)  # единственная точка записи в кэш
		if DEBUG_LOG:
			print("[MAIN] texture ready: ", key)
		_apply_texture_to_segments_by_path(key)


func _apply_texture_to_segments_by_path(img_path: String) -> void:
	for i in range(_segment_ids.size()):
		if i >= _segment_sides.size():
			continue
		var seg_id: String      = _segment_ids[i]
		var cur_side: String    = _segment_sides[i]
		var path_for_seg: String = ""
		if _preview_image_paths.has(seg_id) and _preview_image_paths[seg_id] != "":
			path_for_seg = _preview_image_paths[seg_id]
		elif wall_data != null:
			path_for_seg = wall_data.get_face_image_path(seg_id, cur_side)
		if path_for_seg == img_path:
			_update_single_image_sprite(seg_id, i, cur_side)


# ─────────────────────────────────────────────────────────────────────────────
# TEXTURE UNLOADING — выгрузка давно неиспользуемых текстур
# ─────────────────────────────────────────────────────────────────────────────
func _process_texture_unload(delta: float) -> void:
	_unload_timer += delta
	if _unload_timer < UNLOAD_CHECK_INTERVAL:
		return
	_unload_timer = 0.0
	var now: float = Time.get_ticks_msec() * 0.001
	# Собираем активные пути (видимые сегменты + preview)
	var active_paths: Dictionary = {}
	for i in range(_segment_ids.size()):
		if i >= _segment_sides.size():
			continue
		var seg_id: String   = _segment_ids[i]
		var cur_side: String = _segment_sides[i]
		var p: String = ""
		if _preview_image_paths.has(seg_id):
			p = _preview_image_paths[seg_id]
		elif wall_data != null:
			p = wall_data.get_face_image_path(seg_id, cur_side)
		if p != "":
			active_paths[p] = true

	var to_evict: Array[String] = []
	for path in _texture_last_used.keys():
		if active_paths.has(path):
			continue  # текстура активна — не трогаем
		var last: float = float(_texture_last_used[path])
		if now - last > UNLOAD_IDLE_SEC:
			to_evict.append(path)

	for path in to_evict:
		_cache_evict(path)
	if to_evict.size() > 0 and DEBUG_LOG:
		print("[UNLOAD] evicted ", to_evict.size(), " idle textures")


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG LOG
# ─────────────────────────────────────────────────────────────────────────────
func _process_debug_log(delta: float) -> void:
	if not DEBUG_LOG:
		return
	_dbg_log_timer += delta
	if _dbg_log_timer < DBG_LOG_INTERVAL:
		return
	_dbg_log_timer = 0.0
	_thread_mutex.lock()
	var tq: int = _thread_queue.size()
	var al: int = _active_loading_count
	_thread_mutex.unlock()
	_results_mutex.lock()
	var rq: int = _thread_results.size()
	_results_mutex.unlock()
	var mem_kb: int  = _texture_cache.size() * TEX_BYTES_ESTIMATE / 1024
	var mem_mb: float = float(mem_kb) / 1024.0
	var hit_ratio: float = 0.0
	var total_req: int = _dbg_cache_hits + _dbg_cache_misses
	if total_req > 0:
		hit_ratio = float(_dbg_cache_hits) / float(total_req) * 100.0
	print("[PERF] cache=%d/%d(%.1fMB/%.0fMB)  main_q=%d  thread_q=%d  active=%d  results=%d  hit=%.0f%%  miss=%d  dropped=%d  sprite_cur=%d" % [
		_texture_cache.size(), MAX_TEXTURES_IN_MEMORY, mem_mb, MAX_TEXTURE_MEMORY_MB,
		_texture_load_queue.size(), tq, al, rq,
		hit_ratio, _dbg_cache_misses, _dbg_dropped, _sprite_update_cursor
	])


# ─────────────────────────────────────────────────────────────────────────────
# ОСНОВНОЙ _process
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_apply_thread_results()
	_process_texture_load_queue()
	_tick_sprite_update()         # incremental sprite update (MAX_SPRITE_UPDATES_PER_FRAME)
	_process_texture_unload(delta)
	_process_debug_log(delta)

	# Обновляем позицию камеры для приоритетов
	var cam: Camera2D = get_viewport().get_camera_2d() if get_viewport() != null else null
	if cam != null:
		_camera_position = cam.global_position

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
		var base_t: Transform2D   = _transforms[i]
		var params: Dictionary    = _breathing_params[i]
		var px: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_x
		var py: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_y
		var final_t: Transform2D  = base_t
		final_t.origin += Vector2(sin(px) * params.amplitude_x, cos(py) * params.amplitude_y)
		_multimesh.set_instance_transform_2d(i, final_t)
		if i < _segment_ids.size():
			var seg_id := _segment_ids[i]
			if _segment_sprites.has(seg_id):
				var sprite: Sprite2D = _segment_sprites[seg_id]
				if sprite:
					sprite.position = final_t.origin


# ─────────────────────────────────────────────────────────────────────────────
# ОЧЕРЕДЬ ЗАГРУЗКИ → Thread (Frame budget: MAX_TEXTURE_LOADS_PER_FRAME_*)
# ─────────────────────────────────────────────────────────────────────────────
func _process_texture_load_queue() -> void:
	if _texture_load_queue.is_empty():
		return
	var budget: int = MAX_TEXTURE_LOADS_PER_FRAME_VIEW if allow_purchases else MAX_TEXTURE_LOADS_PER_FRAME_GAME
	while budget > 0 and not _texture_load_queue.is_empty():
		var req: Dictionary = _texture_load_queue.pop_front()
		var qkey0: String   = str(req.get("qkey", ""))
		if qkey0 != "":
			_texture_load_queued_keys.erase(qkey0)
		var seg_id: String   = str(req.get("segment_id", ""))
		var img_path: String = str(req.get("img_path", ""))
		var idx: int         = int(req.get("idx", -1))
		var seg_side: String = str(req.get("segment_side", ""))
		if seg_id == "" or img_path == "" or idx < 0:
			continue
		if not _segment_index.has(seg_id):
			continue  # сегмент вне видимости
		if _cache_get(img_path) != null:
			_update_single_image_sprite(seg_id, idx, seg_side)
			budget -= 1
			continue
		_dbg_cache_misses += 1
		# Backpressure: не превышаем MAX_ACTIVE_LOADING
		_thread_mutex.lock()
		var al: int = _active_loading_count
		_thread_mutex.unlock()
		if al < MAX_ACTIVE_LOADING:
			_enqueue_thread_load(img_path, _calc_priority(seg_id))
		budget -= 1


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
	if wall_data.get_face_image_path(segment_id, visual_side).strip_edges() != "":
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
	var width: int  = max_x - min_x + 1
	var height: int = max_y - min_y + 1
	var total_segments: int = width * height
	if total_segments > MAX_VISIBLE_INSTANCES:
		var scale: float = sqrt(float(MAX_VISIBLE_INSTANCES) / float(total_segments))
		var cx: float = (float(min_x) + float(max_x)) * 0.5
		var cy: float = (float(min_y) + float(max_y)) * 0.5
		var half_w: float = (float(width)  * 0.5) * scale
		var half_h: float = (float(height) * 0.5) * scale
		min_x = int(floor(cx - half_w))
		max_x = int(ceil(cx  + half_w))
		min_y = int(floor(cy - half_h))
		max_y = int(ceil(cy  + half_h))
		if min_x > max_x:
			var t: int = min_x; min_x = max_x; max_x = t
		if min_y > max_y:
			var t2: int = min_y; min_y = max_y; max_y = t2
		width  = max_x - min_x + 1
		height = max_y - min_y + 1
		total_segments = width * height

	visible_min_x = min_x;  visible_max_x = max_x
	visible_min_y = min_y;  visible_max_y = max_y

	var old_sides: Dictionary     = {}
	var old_timers: Dictionary    = {}
	var old_intervals: Dictionary = {}
	for i in range(_segment_ids.size()):
		if i < _segment_sides.size():
			old_sides[_segment_ids[i]]     = _segment_sides[i]
		if i < _side_change_timers.size():
			old_timers[_segment_ids[i]]    = _side_change_timers[i]
		if i < _side_change_intervals.size():
			old_intervals[_segment_ids[i]] = _side_change_intervals[i]

	_multimesh.instance_count = total_segments
	_transforms.clear();        _segment_ids.clear()
	_breathing_params.clear();  _segment_sides.clear()
	_side_change_timers.clear(); _side_change_intervals.clear()
	_segment_index.clear()
	_transforms.resize(total_segments);       _segment_ids.resize(total_segments)
	_breathing_params.resize(total_segments); _segment_sides.resize(total_segments)
	_side_change_timers.resize(total_segments); _side_change_intervals.resize(total_segments)

	var _sm: Node    = get_node_or_null("/root/SeedManager")
	var _gs_seed: int = int(_sm.get("global_seed")) if _sm != null else 0
	var idx: int = 0
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var segment_id: String = "%d_%d" % [x, y]
			var pos: Vector2       = Vector2(x * SEGMENT_SIZE, y * SEGMENT_SIZE)
			var seed_hash: int = int(hash(str(_gs_seed) + "::" + segment_id)) & 0x7FFFFFFF
			_shared_rng.seed = seed_hash if seed_hash != 0 else 1

			var current_side: String
			if old_sides.has(segment_id):
				current_side               = old_sides[segment_id]
				_side_change_timers[idx]   = old_timers.get(segment_id, 0.0)
				_side_change_intervals[idx]= old_intervals.get(segment_id, _shared_rng.randf_range(30.0, 90.0))
			elif _last_known_tile_side.has(segment_id):
				current_side = str(_last_known_tile_side[segment_id])
				var ci_r: float = _shared_rng.randf_range(30.0, 90.0)
				_side_change_intervals[idx] = ci_r
				_side_change_timers[idx]    = _shared_rng.randf_range(0.0, ci_r * 0.3)
			else:
				current_side = SIDES[_shared_rng.randi() % SIDES.size()]
				var ci: float = _shared_rng.randf_range(30.0, 90.0)
				_side_change_intervals[idx] = ci
				_side_change_timers[idx]    = _shared_rng.randf_range(0.0, ci * 0.3)

			_segment_sides[idx] = current_side
			_remember_tile_side(segment_id, current_side)

			var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, current_side)
			var color: Color = _get_segment_color_by_side(current_side, face_data, segment_id)
			var transform: Transform2D = Transform2D.IDENTITY
			transform.origin = pos
			_transforms[idx]     = transform
			_segment_ids[idx]    = segment_id
			_segment_index[segment_id] = idx
			_breathing_params[idx] = {
				"phase":        _shared_rng.randf() * TAU,
				"speed_factor": _shared_rng.randf_range(0.6, 1.4),
				"amplitude_x":  _shared_rng.randf_range(0.3, 0.8) * BASE_BREATHING_AMPLITUDE,
				"amplitude_y":  _shared_rng.randf_range(0.5, 1.2) * BASE_BREATHING_AMPLITUDE,
				"offset_x":     _shared_rng.randf_range(-0.5, 0.5),
				"offset_y":     _shared_rng.randf_range(-0.5, 0.5)
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
			var cur_side: String = _segment_sides[i]
			var new_side: String = cur_side
			var avail: Array[String] = []
			for s in SIDES:
				if s != cur_side:
					avail.append(s)
			if avail.size() > 0:
				if _gs_cache == null:
					_gs_cache = get_node_or_null("/root/GameState")
				var sm2: Node    = get_node_or_null("/root/SeedManager")
				var gs2: int     = int(sm2.get("global_seed")) if sm2 != null else 0
				var sh: int      = int(hash(str(gs2) + "::" + _segment_ids[i] + "::sidepick")) & 0x7FFFFFFF
				_shared_rng.seed = sh if sh != 0 else 1
				new_side         = avail[_shared_rng.randi() % avail.size()]
			_segment_sides[i] = new_side
			_remember_tile_side(_segment_ids[i], new_side)
			var seg_id2: String = _segment_ids[i]
			var sm3: Node    = get_node_or_null("/root/SeedManager")
			var gs3: int     = int(sm3.get("global_seed")) if sm3 != null else 0
			var sh2: int     = int(hash(str(gs3) + "::" + seg_id2 + "::interval")) & 0x7FFFFFFF
			_shared_rng.seed = sh2 if sh2 != 0 else 1
			_side_change_intervals[i] = _shared_rng.randf_range(30.0, 90.0)
			_side_change_timers[i]    = 0.0
			var fd: Dictionary = _effective_face_data_for_ownership(seg_id2, new_side)
			_multimesh.set_instance_color(i, _get_segment_color_by_side(new_side, fd, seg_id2))
			_request_image_sprite_update(seg_id2, i, new_side)


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
	var cur_side: String       = _segment_sides[idx] if idx < _segment_sides.size() else side_id
	var fd: Dictionary         = _effective_face_data_for_ownership(segment_id, cur_side)
	_multimesh.set_instance_color(idx, _get_segment_color_by_side(cur_side, fd, segment_id))
	_request_image_sprite_update(segment_id, idx, cur_side)


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
	var fd: Dictionary = _effective_face_data_for_ownership(segment_id, side_norm)
	_multimesh.set_instance_color(idx, _get_segment_color_by_side(side_norm, fd, segment_id))
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
	if _cache_get(img_path) != null:
		_update_single_image_sprite(segment_id, idx, segment_side)
		return
	var qkey: String = "%s|%s" % [segment_id, img_path]
	if not _texture_load_queued_keys.has(qkey):
		_texture_load_queued_keys[qkey] = true
		# Stream Control: не добавляем если очередь уже полная
		if _texture_load_queue.size() < MAX_TEXTURE_QUEUE_LENGTH:
			_texture_load_queue.append({
				"segment_id":   segment_id,
				"idx":          idx,
				"segment_side": segment_side,
				"img_path":     img_path,
				"qkey":         qkey,
				"priority":     _calc_priority(segment_id),
			})
		else:
			# Очередь полная — вытесняем запись с наименьшим приоритетом
			var min_idx: int = _texture_load_queue.size() - 1
			var min_p: float = float(_texture_load_queue[min_idx].get("priority", 0.0))
			var new_p: float = _calc_priority(segment_id)
			if new_p > min_p:
				var drop: Dictionary = _texture_load_queue[min_idx]
				var dk: String = str(drop.get("qkey", ""))
				if dk != "":
					_texture_load_queued_keys.erase(dk)
				_texture_load_queue[min_idx] = {
					"segment_id":   segment_id,
					"idx":          idx,
					"segment_side": segment_side,
					"img_path":     img_path,
					"qkey":         qkey,
					"priority":     new_p,
				}
			else:
				_texture_load_queued_keys.erase(qkey)
				_dbg_dropped += 1


func _get_segment_color_by_side(segment_side: String, face_data: Dictionary, segment_id: String = "") -> Color:
	var base_color: Color = _get_side_color(segment_side)
	var owner: String     = str(face_data.get("owner", "")).strip_edges()
	if owner != "":
		base_color = base_color.lightened(0.15)

	if dim_other_segments and segment_id != "":
		var is_highlighted: bool = segment_id in _highlighted_segment_ids
		var gs: Node         = get_node_or_null("/root/GameState")
		var buyer_uid: String = str(gs.get("player_uid")) if gs != null else ""
		var is_mine: bool    = owner == buyer_uid
		if not is_mine and segment_id != "" and wall_data != null and buyer_uid != "":
			for s in SIDES:
				if str(wall_data.get_face_data(segment_id, s).get("owner", "")) == buyer_uid:
					is_mine = true
					break
		if not is_highlighted and not is_mine:
			base_color = base_color.darkened(0.6)
			base_color.a *= 0.4

	if segment_id != "" and segment_id in _highlighted_segment_ids:
		base_color = base_color.lerp(Color(1.0, 1.0, 1.0, 0.8), 0.5)

	if _visual_face_image_path(segment_id, segment_side) != "":
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
	_highlighted_segment_ids   = new_ids
	for sid in old_ids:
		if sid not in new_ids:
			update_segment(sid)
	for sid in new_ids:
		update_segment(sid)


func clear_texture_cache() -> void:
	_texture_cache.clear()
	_texture_cache_order.clear()
	_texture_last_used.clear()
	_texture_load_queue.clear()
	_texture_load_queued_keys.clear()
	_sprite_update_cursor = 0
	_thread_mutex.lock()
	_thread_queue.clear()
	_thread_queued_paths.clear()
	_active_loading_count = 0
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
	print("[APPLY] wall image sprites refreshed from WallData (visible=", _multimesh.instance_count, ")")


func set_dim_other_segments(enabled: bool) -> void:
	if dim_other_segments == enabled:
		return
	dim_other_segments = enabled
	for i in range(_multimesh.instance_count):
		if i < _segment_ids.size():
			update_segment(_segment_ids[i])


func set_preview_image_paths(paths: Dictionary) -> void:
	if DEBUG_LOG:
		print("WallRenderer: set_preview_image_paths n=", paths.size())
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
		"front":  return Color(0.0, 0.8, 0.7)
		"back":   return Color(0.0, 0.5, 0.5)
		"left":   return Color(0.2, 0.7, 0.6)
		"right":  return Color(0.1, 0.6, 0.8)
		"top":    return Color(0.3, 0.9, 0.8)
		"bottom": return Color(0.0, 0.4, 0.6)
		_:        return Color(0.0, 0.8, 0.7)


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
	var em: Node        = get_node_or_null("/root/EconomyManager")
	var listing_price: int = int(wall_data.get_segment_price(segment_id))
	var fid: int        = 0
	if em != null and em.has_method("get_listing_price_for_hit"):
		listing_price = int(em.call("get_listing_price_for_hit", side_id, segment_id, segment_side_name, wall_data))
	if em != null and em.has_method("face_id_from_wall_segment"):
		fid = int(em.call("face_id_from_wall_segment", side_id, segment_id, segment_side_name))
	return {
		"segment_id":   segment_id,
		"side":         side_id,
		"segment_side": segment_side_name,
		"price":        listing_price,
		"height":       seg_height,
		"face_id":      fid
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
# СПРАЙТЫ
# ─────────────────────────────────────────────────────────────────────────────

func _get_or_create_sprite(segment_id: String) -> Sprite2D:
	if _segment_sprites.has(segment_id):
		var ex: Sprite2D = _segment_sprites[segment_id]
		if ex:
			ex.visible = true
			return ex
	var sprite: Sprite2D = null
	if _sprite_pool.size() > 0:
		sprite = _sprite_pool.pop_back()
	else:
		sprite = Sprite2D.new()
		sprite.centered = true
		sprite.name     = "SegSprite_" + segment_id
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
	## Инкрементальная версия: обрабатывает MAX_SPRITE_UPDATES_PER_FRAME за вызов.
	## Курсор _sprite_update_cursor сбрасывается при вызове (full pass разбит на кадры).
	if wall_data == null and _preview_image_paths.is_empty():
		return
	# Одноразовый проход для удаления вышедших из видимости спрайтов
	var visible_ids: Dictionary = {}
	for seg_id in _segment_ids:
		visible_ids[seg_id] = true
	for seg_id in _segment_sprites.keys():
		if not visible_ids.has(seg_id):
			_release_sprite(seg_id)
	# Сброс курсора — incremental pass начнётся с 0
	_sprite_update_cursor = 0
	# Немедленно обрабатываем первый chunk (остальное — в _process через _tick_sprite_update)
	_tick_sprite_update()


func _tick_sprite_update() -> void:
	## Обрабатывает один chunk сегментов за кадр. Вызывается из _process.
	if wall_data == null and _preview_image_paths.is_empty():
		return
	var total: int = _segment_ids.size()
	if _sprite_update_cursor >= total:
		return
	var end_idx: int = mini(_sprite_update_cursor + MAX_SPRITE_UPDATES_PER_FRAME, total)
	for i in range(_sprite_update_cursor, end_idx):
		if i >= _segment_sides.size():
			continue
		var seg_id: String   = _segment_ids[i]
		var cur_side: String = _segment_sides[i]
		var img_path: String = ""
		if _preview_image_paths.has(seg_id) and _preview_image_paths[seg_id] != "":
			img_path = _preview_image_paths[seg_id]
		elif wall_data != null:
			img_path = wall_data.get_face_image_path(seg_id, cur_side)
		if img_path == "":
			if _segment_sprites.has(seg_id):
				_release_sprite(seg_id)
			continue
		if _cache_get(img_path) == null:
			var qkey: String = "%s|%s" % [seg_id, img_path]
			if not _texture_load_queued_keys.has(qkey):
				_texture_load_queued_keys[qkey] = true
				if _texture_load_queue.size() < MAX_TEXTURE_QUEUE_LENGTH:
					_texture_load_queue.append({
						"segment_id":   seg_id,
						"idx":          i,
						"segment_side": cur_side,
						"img_path":     img_path,
						"qkey":         qkey,
						"priority":     _calc_priority(seg_id),
					})
				else:
					_texture_load_queued_keys.erase(qkey)
					_dbg_dropped += 1
			continue
		_update_single_image_sprite(seg_id, i, cur_side)
	_sprite_update_cursor = end_idx


func _touch_texture_cache_key(img_path: String) -> void:
	var ix: int = _texture_cache_order.find(img_path)
	if ix >= 0:
		_texture_cache_order.remove_at(ix)
	_texture_cache_order.append(img_path)


func _evict_texture_cache_if_needed() -> void:
	## Memory Guard: MB-based cap + count cap. LRU, не трогаем активные текстуры.
	var tex_count: int = _texture_cache_order.size()
	var mem_mb: float  = float(tex_count * TEX_BYTES_ESTIMATE) / (1024.0 * 1024.0)
	if tex_count <= MAX_TEXTURES_IN_MEMORY and mem_mb <= MAX_TEXTURE_MEMORY_MB:
		return

	# Собираем активные пути однократно
	var active_now: Dictionary = {}
	for i in range(_segment_ids.size()):
		if i >= _segment_sides.size():
			continue
		var p: String = ""
		if _preview_image_paths.has(_segment_ids[i]):
			p = _preview_image_paths[_segment_ids[i]]
		elif wall_data != null:
			p = wall_data.get_face_image_path(_segment_ids[i], _segment_sides[i])
		if p != "":
			active_now[p] = true

	while _texture_cache_order.size() > MAX_TEXTURES_IN_MEMORY or \
		  float(_texture_cache_order.size() * TEX_BYTES_ESTIMATE) / (1024.0 * 1024.0) > MAX_TEXTURE_MEMORY_MB:
		var evicted: bool = false
		for i in range(_texture_cache_order.size()):
			var oldest: String = _texture_cache_order[i]
			if not active_now.has(oldest):
				_cache_evict(oldest)
				evicted = true
				break
		if not evicted:
			# Все активны — выбрасываем старейший принудительно
			if _texture_cache_order.is_empty():
				break
			_cache_evict(_texture_cache_order[0])
			break


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
	var tex: Texture2D = _cache_get(img_path)
	if tex == null:
		_dbg_cache_misses += 1
		_enqueue_thread_load(img_path, _calc_priority(segment_id))
		return
	if DEBUG_LOG:
		print("[MAIN] apply sprite: ", segment_id, " path=", img_path)
	var sprite: Sprite2D = _get_or_create_sprite(segment_id)
	sprite.texture = tex
	if _gs_cache == null:
		_gs_cache = get_node_or_null("/root/GameState")
	var breathing_on: bool = _gs_cache != null and bool(_gs_cache.get("wall_breathing_enabled"))
	var cur_t: Transform2D
	if breathing_on and idx < _multimesh.instance_count:
		cur_t = _multimesh.get_instance_transform_2d(idx)
	else:
		cur_t = _transforms[idx]
	sprite.position = cur_t.origin
