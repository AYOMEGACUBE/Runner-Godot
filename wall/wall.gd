extends Node2D
# ============================================================================
# wall.gd
# Оптимизированная архитектура стены на основе MultiMesh

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/FileLogger")
	if logger != null and logger.has_method("write_log"):
		logger.call("write_log", message)
	else:
		print(message)
# ============================================================================
# - Использует WallRenderer (MultiMeshInstance2D) вместо тысяч нод
# - Данные хранятся в WallData
# - Клики обрабатываются по координатам (без Area2D на каждый сегмент)
# ============================================================================
# Проверено: Godot 4.x
# ============================================================================

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")

# ЗАФИКСИРОВАННЫЕ ПАРАМЕТРЫ (сетка — из WorldSegmentGrid)
const SEGMENT_SIZE: int = WorldSegmentGrid.SEGMENT_SIZE_PX
const SEGMENTS_PER_SIDE: int = WorldSegmentGrid.SEGMENTS_PER_FACE_AXIS
const WORLD_SCREENS: int = 20
const VIEWPORT_WIDTH: int = 1152

# Минимальный сдвиг камеры / зума перед пересчётом видимой области (без периодического таймера)
const UPDATE_DISTANCE_THRESHOLD: float = 400.0  # Увеличено с 256.0 для более редких обновлений

# Размеры виртуальной стены в пикселях
const VIRTUAL_WALL_SIZE: int = SEGMENTS_PER_SIDE * SEGMENT_SIZE  # 153,600 px (было 34,560 px)

# Размер видимой области (в сегментах) с запасом
# В игровом режиме (Level): 1 экран во все стороны
# В режиме просмотра (CubeView): минимальный запас
const VISIBLE_MARGIN_GAME: float = 1.0  # В игровом режиме: 1 экран во все стороны (в единицах viewport_half)
const VISIBLE_MARGIN_VIEW: int = 2  # В режиме просмотра: 2 сегмента за пределами экрана

# Сторона мега-куба (для визуализации и отладки)
# Возможные значения: "front" | "back" | "left" | "right" | "top" | "bottom"
var side_id: String = "front"

# Флаг разрешения покупок сегментов (только для CubeView, не для Level)
var allow_purchases: bool = false

# Новый рендерер на основе MultiMesh
var wall_renderer: WallRenderer = null

var wall_data: WallData

# Для отладочного вывода (чтобы не спамить каждый кадр)oid/debug.keystore
var _last_debug_bounds: Dictionary = {}
var _debug_print_cooldown: float = 0.0
const DEBUG_PRINT_INTERVAL: float = 1.0  # Выводить раз в секунду

var _last_camera_position: Vector2 = Vector2.INF
var _last_camera_zoom: Vector2 = Vector2.ZERO
var _camera_ref: Camera2D = null
var update_counter: int = 0
var _debug_update_timer: float = 0.0
## [OPTIMIZATION] Не дергать MultiMesh, если камера/viewport/zoom не менялись (в т.ч. после call_deferred).
var _vis_cache_cam: Vector2 = Vector2(INF, INF)
var _vis_cache_zoom: Vector2 = Vector2.ZERO
var _vis_cache_vp: Vector2 = Vector2.ZERO
var _vis_cache_valid: bool = false
var _ownership_pull_accum: float = 0.0
const OWNERSHIP_PULL_INTERVAL_SEC: float = 4.0


func _ready() -> void:
	_log("[WALL] _ready side_id=%s allow_purchases=%s" % [side_id, allow_purchases])
	# Стена на заднем плане
	z_index = -10
	
	# Берём активную сторону из GameState (если есть)
	var gs: Node = get_node_or_null("/root/GameState")
	if gs != null and gs.has_method("get_active_wall_side"):
		side_id = str(gs.call("get_active_wall_side"))
		_log("[WALL] active side from GameState: %s" % side_id)
	
	_camera_ref = get_viewport().get_camera_2d()
	if _camera_ref:
		_last_camera_position = _camera_ref.global_position
		_last_camera_zoom = _camera_ref.zoom
		_log("[WALL] camera found at pos=%s" % _last_camera_position)

	# Локальное хранилище данных стены (без онлайна).
	wall_data = WallData.new()
	wall_data.name = "WallData"
	add_child(wall_data)
	# Загружаем сохранённые данные (если есть)
	wall_data.load_from_file()
	_log("[WALL] wall_data loaded, segments=%d" % wall_data.segments.size())

	# Создаём оптимизированный рендерер
	wall_renderer = WallRenderer.new()
	wall_renderer.name = "WallRenderer"
	add_child(wall_renderer)
	wall_renderer.setup(wall_data, side_id, allow_purchases)
	_log("[WALL] renderer setup complete")
	var ors: Node = get_node_or_null("/root/OwnershipRemoteSync")
	if ors != null:
		if ors.has_signal("ownership_updated") and not ors.ownership_updated.is_connected(_on_ownership_updated):
			ors.ownership_updated.connect(_on_ownership_updated)
		if ors.has_method("pull_ownership_then_merge"):
			ors.call_deferred("pull_ownership_then_merge")

	call_deferred("_update_visible_segments", true)

	var gs_disk: Node = get_node_or_null("/root/GameState")
	if gs_disk != null and gs_disk.has_signal("wall_segments_disk_updated"):
		if not gs_disk.wall_segments_disk_updated.is_connected(_on_wall_segments_disk_updated):
			gs_disk.wall_segments_disk_updated.connect(_on_wall_segments_disk_updated)


func _exit_tree() -> void:
	var gs_disk2: Node = get_node_or_null("/root/GameState")
	if gs_disk2 != null and gs_disk2.has_signal("wall_segments_disk_updated"):
		if gs_disk2.wall_segments_disk_updated.is_connected(_on_wall_segments_disk_updated):
			gs_disk2.wall_segments_disk_updated.disconnect(_on_wall_segments_disk_updated)


func _on_wall_segments_disk_updated() -> void:
	## Другой экран (CubeView) сохранил wall_segments.json — перечитать, иначе Level остаётся со старым WallData в памяти.
	if wall_data == null:
		return
	wall_data.load_from_file()
	if wall_renderer != null and wall_renderer.has_method("clear_texture_cache"):
		wall_renderer.clear_texture_cache()
	_vis_cache_valid = false
	_update_visible_segments(true)
	refresh_segment_textures()
	_log("[LOAD] wall reloaded from disk (wall_segments_disk_updated) segments=%d" % wall_data.segments.size())


func _process(delta: float) -> void:
	var gs2: Node = get_node_or_null("/root/GameState")
	if gs2 != null and bool(gs2.get("disable_wall")):
		clear_wall()
		return

	_debug_update_timer += delta
	_ownership_pull_accum += delta
	if _ownership_pull_accum >= OWNERSHIP_PULL_INTERVAL_SEC:
		_ownership_pull_accum = 0.0
		var ors: Node = get_node_or_null("/root/OwnershipRemoteSync")
		if ors != null and ors.has_method("pull_ownership_then_merge"):
			ors.call("pull_ownership_then_merge")

	var camera := _camera_ref
	if camera == null:
		camera = get_viewport().get_camera_2d()
		_camera_ref = camera
		if camera == null:
			return

	## [FIX] Раньше таймер срабатывал без движения камеры → фризы и спам логов.
	var need_update: bool = false
	var vp_now: Vector2 = get_viewport().get_visible_rect().size
	if _vis_cache_valid and not _vis_cache_vp.is_equal_approx(vp_now):
		need_update = true
	var cam_pos: Vector2 = camera.global_position
	var cam_zoom: Vector2 = camera.zoom
	if _last_camera_position == Vector2.INF:
		_last_camera_position = cam_pos
		_last_camera_zoom = cam_zoom
		need_update = true
	else:
		var dist: float = cam_pos.distance_to(_last_camera_position)
		var zoom_delta: float = cam_zoom.distance_to(_last_camera_zoom)
		if dist >= UPDATE_DISTANCE_THRESHOLD or zoom_delta > 0.0001:
			need_update = true
			_last_camera_position = cam_pos
			_last_camera_zoom = cam_zoom

	if not need_update:
		return

	update_counter += 1
	_log("[WALL] update triggered counter=%d camera_pos=%s" % [update_counter, camera.global_position if camera else "null"])
	_update_visible_segments(false)

	if _debug_update_timer >= 2.0:
		update_counter = 0
		_debug_update_timer = 0.0


func _update_visible_segments(force: bool = false) -> void:
	if wall_renderer == null:
		return
	
	# Получаем позицию камеры
	var camera_pos: Vector2 = Vector2.ZERO
	var cam_zoom: Vector2 = Vector2.ONE
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera:
		camera_pos = camera.global_position
		cam_zoom = camera.zoom
	else:
		# Fallback: пытаемся найти через Player
		var player: Node = get_tree().get_first_node_in_group("player")
		if player == null:
			# Ищем Player в Level
			var level: Node = get_tree().get_first_node_in_group("level")
			if level == null:
				level = get_parent()
			if level:
				player = level.get_node_or_null("Player")
		
		if player:
			camera = player.get_node_or_null("Camera2D")
			if camera:
				camera_pos = camera.global_position
				cam_zoom = camera.zoom
			else:
				# Используем позицию игрока как приближение
				camera_pos = player.global_position

	# Вычисляем видимую область в мировых координатах
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if not force and _vis_cache_valid:
		if _vis_cache_cam.is_equal_approx(camera_pos) and _vis_cache_zoom.is_equal_approx(cam_zoom) and _vis_cache_vp.is_equal_approx(viewport_size):
			return
	var viewport_half_width: float = viewport_size.x * 0.5
	var viewport_half_height: float = viewport_size.y * 0.5
	
	# Учитываем зум камеры: при ОТДАЛЕНИИ (zoom < 1) камера видит
	# БОЛЬШУЮ область мира, а при ПРИБЛИЖЕНИИ (zoom > 1) — меньшую.
	# Видимый размер в мировых координатах = viewport_size / zoom.
	if camera:
		if camera.zoom.x != 0.0:
			viewport_half_width /= camera.zoom.x
		if camera.zoom.y != 0.0:
			viewport_half_height /= camera.zoom.y

	# Определяем запас в зависимости от режима (игра или просмотр)
	# В игровом режиме (allow_purchases = false) загружаем 1 экран во все стороны
	# В режиме просмотра (allow_purchases = true) минимальный запас
	var margin_x: float
	var margin_y: float
	if allow_purchases:
		# Режим просмотра (CubeView) - минимальный запас
		margin_x = VISIBLE_MARGIN_VIEW * SEGMENT_SIZE
		margin_y = VISIBLE_MARGIN_VIEW * SEGMENT_SIZE
	else:
		# Игровой режим (Level) - 1 экран во все стороны
		margin_x = viewport_half_width * VISIBLE_MARGIN_GAME
		margin_y = viewport_half_height * VISIBLE_MARGIN_GAME
	
	# Границы видимой области в сегментах
	var min_x_seg: int = int(floor((camera_pos.x - viewport_half_width - margin_x) / SEGMENT_SIZE))
	var max_x_seg: int = int(ceil((camera_pos.x + viewport_half_width + margin_x) / SEGMENT_SIZE))
	var min_y_seg: int = int(floor((camera_pos.y - viewport_half_height - margin_y) / SEGMENT_SIZE))
	var max_y_seg: int = int(ceil((camera_pos.y + viewport_half_height + margin_y) / SEGMENT_SIZE))

	# Ограничиваем виртуальными границами стены
	min_x_seg = max(min_x_seg, -SEGMENTS_PER_SIDE / 2)
	max_x_seg = min(max_x_seg, SEGMENTS_PER_SIDE / 2)
	min_y_seg = max(min_y_seg, -SEGMENTS_PER_SIDE / 2)
	max_y_seg = min(max_y_seg, SEGMENTS_PER_SIDE / 2)

	# Обновляем рендерер (вместо создания/удаления нод)
	var visible_count: int = (max_x_seg - min_x_seg + 1) * (max_y_seg - min_y_seg + 1)
	_log("[WALL] update_visible_segments bounds=[%d,%d]x[%d,%d] visible=%d" % [min_x_seg, max_x_seg, min_y_seg, max_y_seg, visible_count])
	wall_renderer.update_visible_area(min_x_seg, max_x_seg, min_y_seg, max_y_seg)
	_vis_cache_cam = camera_pos
	_vis_cache_zoom = cam_zoom
	_vis_cache_vp = viewport_size
	_vis_cache_valid = true

	# Отладочный вывод (с кулдауном, чтобы не спамить)
	if _debug_print_cooldown <= 0.0:
		var current_bounds := {
			"min_x": min_x_seg,
			"max_x": max_x_seg,
			"min_y": min_y_seg,
			"max_y": max_y_seg
		}
		
		# Выводим только если границы изменились или это первый запуск
		if _last_debug_bounds != current_bounds or _last_debug_bounds.is_empty():
			_print_debug_info(min_x_seg, max_x_seg, min_y_seg, max_y_seg)
			_last_debug_bounds = current_bounds
			_debug_print_cooldown = DEBUG_PRINT_INTERVAL


func clear_wall() -> void:
	_vis_cache_valid = false
	# Очищаем рендерер
	if wall_renderer:
		wall_renderer.update_visible_area(0, 0, 0, 0)
	
	# Очищаем старые ноды (если остались)
	for child in get_children():
		if child is WallData or child is WallRenderer:
			continue
		child.queue_free()


func _print_debug_info(min_x: int, max_x: int, min_y: int, max_y: int) -> void:
	# Отладочный вывод информации о стене
	var width: int = max_x - min_x + 1
	var height: int = max_y - min_y + 1
	var segment_count: int = width * height
	# print("Wall: visible segments: %d (%d x %d)" % [segment_count, width, height])

# Обработка клика по координатам (для CubeView)
func handle_click(global_pos: Vector2, for_price_preview: bool = false) -> Dictionary:
	if wall_renderer == null:
		_log("[WALL] handle_click FAILED - renderer is null")
		return {}
	var result: Dictionary = wall_renderer.handle_click(global_pos, for_price_preview)
	if not result.is_empty():
		_log("[WALL] handle_click pos=%s segment_id=%s segment_side=%s" % [global_pos, result.get("segment_id", "unknown"), result.get("segment_side", "")])
		SegmentManager.notify_wall_segment_selected(self, wall_data, result)
	return result

# Обновление конкретного сегмента после покупки
func update_segment_visual(segment_id: String) -> void:
	if wall_renderer:
		wall_renderer.update_segment(segment_id)


func refresh_segment_textures() -> void:
	## После записи image_path в WallData — перерисовать спрайты в CubeView / Level.
	if wall_renderer and wall_renderer.has_method("refresh_images_from_wall_data"):
		wall_renderer.refresh_images_from_wall_data()

# Подсветка сегмента (для CubeView)
func set_highlighted_segment(segment_id: String) -> void:
	if wall_renderer:
		wall_renderer.set_highlighted_segment(segment_id)

func set_highlighted_segments(segment_ids: Array) -> void:
	if wall_renderer:
		wall_renderer.set_highlighted_segments(segment_ids)

func clear_highlight() -> void:
	if wall_renderer:
		wall_renderer.clear_highlight()

## Остановить смену сторон сегментов во время покупки
func set_pause_side_switching(pause: bool) -> void:
	if wall_renderer:
		wall_renderer.pause_side_switching = pause

## Затемнять чужие сегменты во время предпросмотра
func set_dim_other_segments(enabled: bool) -> void:
	if wall_renderer:
		wall_renderer.set_dim_other_segments(enabled)

## Установить временные пути изображений для предпросмотра (segment_id -> path). В режиме предпросмотра выбранные сегменты отображают эти картинки.
func set_preview_image_paths(paths: Dictionary) -> void:
	if wall_renderer:
		wall_renderer.set_preview_image_paths(paths)


func _on_ownership_updated(wall_changed: bool, _platform_changed: bool) -> void:
	if not wall_changed or wall_data == null:
		return
	wall_data.load_from_file()
	_log("[WALL] ownership_updated -> wall_data reloaded, segments=%d" % wall_data.segments.size())
	if wall_renderer != null and wall_renderer.has_method("clear_texture_cache"):
		wall_renderer.clear_texture_cache()
	_vis_cache_valid = false
	_update_visible_segments(true)
	refresh_segment_textures()
