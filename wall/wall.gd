extends Node2D
# ============================================================================
# wall.gd
# Оптимизированная архитектура стены на основе MultiMesh
# ============================================================================
# - Использует WallRenderer (MultiMeshInstance2D) вместо тысяч нод
# - Данные хранятся в WallData
# - Клики обрабатываются по координатам (без Area2D на каждый сегмент)
# ============================================================================
# Проверено: Godot 4.x
# ============================================================================

# ЗАФИКСИРОВАННЫЕ ПАРАМЕТРЫ
const SEGMENT_SIZE: int = 48
const WORLD_SCREENS: int = 20
const VIEWPORT_WIDTH: int = 1152

# Размер стороны мега-куба должен покрывать весь мир
# Мир может быть: WORLD_WIDTH = PLAYER_SPEED_X * SEGMENT_TIME_SECONDS = 350 * 420 = 147,000 px
# Или: WORLD_SCREENS * VIEWPORT_WIDTH = 20 * 1152 = 23,040 px
# Берём максимум и добавляем запас: 147,000 / 48 ≈ 3,063 сегмента
# Округляем до 3,200 для удобства (64 * 50)
const SEGMENTS_PER_SIDE: int = 3200  # Виртуальная сторона мега-куба (было 720)

# Интервал обновления и минимальный сдвиг камеры (оптимизировано для производительности)
const UPDATE_INTERVAL: float = 0.8  # Увеличено с 0.4 для уменьшения частоты апдейтов
const UPDATE_DISTANCE_THRESHOLD: float = 400.0  # Увеличено с 256.0 для более редких обновлений

# Размеры виртуальной стены в пикселях
const VIRTUAL_WALL_SIZE: int = SEGMENTS_PER_SIDE * SEGMENT_SIZE  # 153,600 px (было 34,560 px)

# Размер видимой области (в сегментах) с запасом
const VISIBLE_MARGIN: int = 2  # Дополнительные сегменты за пределами экрана

# Сторона мега-куба (для визуализации и отладки)
# Возможные значения: "front" | "back" | "left" | "right" | "top" | "bottom"
var side_id: String = "front"

# Флаг разрешения покупок сегментов (только для CubeView, не для Level)
var allow_purchases: bool = false

# Новый рендерер на основе MultiMesh
var wall_renderer: WallRenderer = null

var wall_data: WallData

# Для отладочного вывода (чтобы не спамить каждый кадр)
var _last_debug_bounds: Dictionary = {}
var _debug_print_cooldown: float = 0.0
const DEBUG_PRINT_INTERVAL: float = 1.0  # Выводить раз в секунду

var _update_timer: float = 0.0
var _last_camera_position: Vector2 = Vector2.INF
var _camera_ref: Camera2D = null
var update_counter: int = 0
var _debug_update_timer: float = 0.0


func _ready() -> void:
	# Стена на заднем плане
	z_index = -10
	
	# Берём активную сторону из GameState (если есть)
	if Engine.has_singleton("GameState") and GameState.has_method("get_active_wall_side"):
		side_id = GameState.get_active_wall_side()
	
	_camera_ref = get_viewport().get_camera_2d()
	if _camera_ref:
		_last_camera_position = _camera_ref.global_position

	# Локальное хранилище данных стены (без онлайна).
	wall_data = WallData.new()
	add_child(wall_data)
	# Загружаем сохранённые данные (если есть)
	wall_data.load_from_file()

	# Создаём оптимизированный рендерер
	wall_renderer = WallRenderer.new()
	add_child(wall_renderer)
	wall_renderer.setup(wall_data, side_id, allow_purchases)

	call_deferred("_update_visible_segments")


func _process(delta: float) -> void:
	if GameState.disable_wall:
		clear_wall()
		return

	_update_timer += delta
	_debug_update_timer += delta

	var camera := _camera_ref
	if camera == null:
		camera = get_viewport().get_camera_2d()
		_camera_ref = camera
		if camera == null:
			return

	var need_update: bool = false

	if _update_timer >= UPDATE_INTERVAL:
		need_update = true

	if camera:
		var cam_pos: Vector2 = camera.global_position
		if _last_camera_position == Vector2.INF:
			_last_camera_position = cam_pos
		else:
			var dist: float = cam_pos.distance_to(_last_camera_position)
			if dist >= UPDATE_DISTANCE_THRESHOLD:
				need_update = true
				_last_camera_position = cam_pos

	if not need_update:
		return

	_update_timer = 0.0
	update_counter += 1
	_update_visible_segments()

	if _debug_update_timer >= 2.0:
		update_counter = 0
		_debug_update_timer = 0.0


func _update_visible_segments() -> void:
	if wall_renderer == null:
		return
	
	# Получаем позицию камеры
	var camera_pos: Vector2 = Vector2.ZERO
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera:
		camera_pos = camera.global_position
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
			else:
				# Используем позицию игрока как приближение
				camera_pos = player.global_position

	# Вычисляем видимую область в мировых координатах
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var viewport_half_width: float = viewport_size.x * 0.5
	var viewport_half_height: float = viewport_size.y * 0.5
	
	# Учитываем зум камеры: при отдалении камера видит большую область,
	# значит нужно подгружать больше сегментов стены.
	if camera:
		viewport_half_width *= camera.zoom.x
		viewport_half_height *= camera.zoom.y

	# Границы видимой области в сегментах
	var min_x_seg: int = int(floor((camera_pos.x - viewport_half_width - VISIBLE_MARGIN * SEGMENT_SIZE) / SEGMENT_SIZE))
	var max_x_seg: int = int(ceil((camera_pos.x + viewport_half_width + VISIBLE_MARGIN * SEGMENT_SIZE) / SEGMENT_SIZE))
	var min_y_seg: int = int(floor((camera_pos.y - viewport_half_height - VISIBLE_MARGIN * SEGMENT_SIZE) / SEGMENT_SIZE))
	var max_y_seg: int = int(ceil((camera_pos.y + viewport_half_height + VISIBLE_MARGIN * SEGMENT_SIZE) / SEGMENT_SIZE))

	# Ограничиваем виртуальными границами стены
	min_x_seg = max(min_x_seg, -SEGMENTS_PER_SIDE / 2)
	max_x_seg = min(max_x_seg, SEGMENTS_PER_SIDE / 2)
	min_y_seg = max(min_y_seg, -SEGMENTS_PER_SIDE / 2)
	max_y_seg = min(max_y_seg, SEGMENTS_PER_SIDE / 2)

	# Обновляем рендерер (вместо создания/удаления нод)
	wall_renderer.update_visible_area(min_x_seg, max_x_seg, min_y_seg, max_y_seg)

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
func handle_click(global_pos: Vector2) -> Dictionary:
	if wall_renderer == null:
		return {}
	return wall_renderer.handle_click(global_pos)

# Обновление конкретного сегмента после покупки
func update_segment_visual(segment_id: String) -> void:
	if wall_renderer:
		wall_renderer.update_segment(segment_id)

# Подсветка сегмента (для CubeView)
func set_highlighted_segment(segment_id: String) -> void:
	if wall_renderer:
		wall_renderer.set_highlighted_segment(segment_id)

func clear_highlight() -> void:
	if wall_renderer:
		wall_renderer.clear_highlight()
