extends Node2D
# ============================================================================
# wall.gd
# Архитектура стены из сегментов 48x48
# Менеджер сегментов с поддержкой виртуальной стены 720×720
# ============================================================================
# - работает только с Node2D / Sprite2D / Area2D
# - создаёт ТОЛЬКО видимые сегменты
# - сам ничего не рисует
# ============================================================================
# Проверено: Godot 4.x
# ============================================================================

# ЗАФИКСИРОВАННЫЕ ПАРАМЕТРЫ
const SEGMENT_SIZE: int = 48
const WORLD_SCREENS: int = 20
const VIEWPORT_WIDTH: int = 1152
const SEGMENTS_PER_SIDE: int = 720  # Виртуальная сторона мега-куба

# Интервал обновления и минимальный сдвиг камеры
const UPDATE_INTERVAL: float = 0.4
const UPDATE_DISTANCE_THRESHOLD: float = 256.0

# Размеры виртуальной стены в пикселях
const VIRTUAL_WALL_SIZE: int = SEGMENTS_PER_SIDE * SEGMENT_SIZE  # 34560 px

# Размер видимой области (в сегментах) с запасом
const VISIBLE_MARGIN: int = 2  # Дополнительные сегменты за пределами экрана

# Сторона мега-куба (для визуализации и отладки)
# Возможные значения: "front" | "back" | "left" | "right" | "top" | "bottom"
var side_id: String = "front"

@onready var segment_scene: PackedScene = preload("res://wall/segment/WallSegment.tscn")

var wall_data: WallData

# Кэш созданных сегментов для управления видимостью
var active_segments: Dictionary = {}  # "x_y" -> Node2D

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
	_camera_ref = get_viewport().get_camera_2d()
	if _camera_ref:
		_last_camera_position = _camera_ref.global_position

	# Локальное хранилище данных стены (без онлайна).
	wall_data = WallData.new()
	add_child(wall_data)

	call_deferred("_update_visible_segments")


func _process(delta: float) -> void:
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

	# Удаляем сегменты вне видимой области
	var keys_to_remove: Array = []
	for key in active_segments:
		var coords: Array = key.split("_")
		if coords.size() != 2:
			continue
		var seg_x: int = int(coords[0])
		var seg_y: int = int(coords[1])
		
		if seg_x < min_x_seg or seg_x > max_x_seg or seg_y < min_y_seg or seg_y > max_y_seg:
			var segment: Node = active_segments[key]
			if segment:
				segment.queue_free()
			keys_to_remove.append(key)

	for key in keys_to_remove:
		active_segments.erase(key)

	# Создаём новые сегменты в видимой области
	for y in range(min_y_seg, max_y_seg + 1):
		for x in range(min_x_seg, max_x_seg + 1):
			var key: String = "%d_%d" % [x, y]
			if active_segments.has(key):
				continue  # Сегмент уже существует

			var segment := segment_scene.instantiate()
			if segment == null:
				continue

			add_child(segment)

			# Геометрия: идеальный квадрат 48×48, стена к стене
			var pos := Vector2(
				x * SEGMENT_SIZE,
				y * SEGMENT_SIZE
			)
			segment.position = pos

			if segment.has_method("setup"):
				segment.setup(key, side_id, wall_data)
			else:
				segment.segment_id = key

			active_segments[key] = segment

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
	for key in active_segments:
		var segment: Node = active_segments[key]
		if segment:
			segment.queue_free()
	active_segments.clear()

	for child in get_children():
		if child is WallData:
			continue
		child.queue_free()


func _print_debug_info(min_x: int, max_x: int, min_y: int, max_y: int) -> void:
	# Отладочный вывод информации о стене
	var segment_count: int = active_segments.size()
