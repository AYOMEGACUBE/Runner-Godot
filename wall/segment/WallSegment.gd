extends Node2D
# Класс сегмента стены, используется в разных сценах
class_name WallSegment
# ============================================================================
# WallSegment.gd
# Один сегмент стены (48x48)
# Визуал: Sprite2D
# Взаимодействие: Area2D
# Минимальная анимация: мягкое покачивание
# ============================================================================

@export var segment_id: String = ""

# Режим стены: статика / "живая" стена
const WALL_MODE_STATIC: int = 0
const WALL_MODE_LIVING: int = 1
@export var wall_mode: int = WALL_MODE_LIVING

# Режим сегмента: хаотичный / синхронный показ
const SEGMENT_MODE_RANDOM: int = 0
const SEGMENT_MODE_SYNC_SHOW: int = 1
var segment_mode: int = SEGMENT_MODE_RANDOM

@onready var area: Area2D = $Area2D
@onready var sprite: Sprite2D = $Sprite2D
@onready var visibility_notifier: VisibleOnScreenNotifier2D = $VisibleOnScreenNotifier2D

var wall_data: WallData = null
var side_id: String = "front"  # Сторона мега-куба

# Параметры дыхания: каждый сегмент двигается рандомно
var _time_accum: float = 0.0
var _breath_amplitude: float = 1.2
var _breath_speed: float = PI * 0.4
var _breath_speed_factor: float = 1.0
var _breath_phase: float = 0.0

# Микро-вариация яркости для визуального разнообразия
var _brightness_variation: float = 1.0

# Независимый таймер цвета (для лёгкой дрожи яркости)
var _color_time: float = 0.0
var _color_speed: float = 0.0
var _color_phase: float = 0.0

# Базовая локальная позиция по Y (для дыхания)
var _base_y: float = 0.0

# Базовая Y позиция узла сегмента (для централизованного дыхания в wall.gd)
var base_position_y: float = 0.0

# Текущий базовый цвет сегмента
var _base_color: Color = Color(1, 1, 1, 1)

# Параметры вращения (асинхронно, с паузами)
var _rot_time: float = 0.0
var _rot_amp: float = 0.0
var _rot_speed: float = 1.0
var _rot_phase: float = 0.0
var _rot_timer: float = 0.0
var _rot_active: bool = false

# Параметры синхронного показа (архитектура на будущее)
var _sync_show_timer: float = 0.0
var _sync_show_side: String = ""
@export var sync_show_interval: float = 60.0

# Флаг, чтобы один раз вывести в консоль, что анимация активна
var _animation_logged: bool = false


func start_sync_show(side: String, duration: float) -> void:
	# В будущем wall.gd или другой менеджер может вызывать это
	# для синхронного показа выбранной стороны на группе сегментов.
	segment_mode = SEGMENT_MODE_SYNC_SHOW
	_sync_show_side = side
	_sync_show_timer = max(0.0, duration)
	side_id = side


# ---------------------------------------------------------------------------
# ОБЯЗАТЕЛЬНЫЙ МЕТОД — его вызывает wall.gd
# ---------------------------------------------------------------------------

func setup(id: String, side: String, data: WallData, allow_purchases_flag: bool = false) -> void:
	segment_id = id
	side_id = side
	wall_data = data
	base_position_y = position.y
	
	# Отключаем/включаем покупки в зависимости от флага
	if area:
		area.input_pickable = allow_purchases_flag
		area.monitoring = allow_purchases_flag
	
	# Генерируем микро-вариацию яркости (±5-10%)
	_brightness_variation = 0.95 + randf() * 0.1  # От 0.95 до 1.05

	# Рандомные параметры "дыхания" — каждый сегмент двигается по-своему
	_breath_speed_factor = randf_range(0.6, 1.4)
	_breath_phase = randf() * TAU

	# Асинхронные параметры цвета (очень медленная дрожь яркости)
	_color_speed = randf_range(0.15, 0.4)
	_color_phase = randf() * TAU

	_rot_amp = deg_to_rad(randf_range(1.0, 4.0))   # небольшая амплитуда вращения
	_rot_speed = randf_range(0.5, 1.5)
	_rot_phase = randf() * TAU
	_rot_timer = randf_range(0.5, 2.5)
	_rot_active = randf() < 0.7  # иногда кубы могут не вращаться долго
	
	_update_visual_state()
	_reset_geometry()


var _change_timer: float = 0.0
var _change_interval: float = 0.0


func _ready() -> void:
	# _process только для видимых сегментов (оптимизация)
	if visibility_notifier:
		if not visibility_notifier.screen_entered.is_connected(_on_screen_entered):
			visibility_notifier.screen_entered.connect(_on_screen_entered)
		if not visibility_notifier.screen_exited.is_connected(_on_screen_exited):
			visibility_notifier.screen_exited.connect(_on_screen_exited)
		set_process(visibility_notifier.is_on_screen())
	else:
		set_process(true)

	_change_timer = 0.0
	_change_interval = randf_range(30.0, 90.0)

	# Подключаем клики
	if area and not area.input_event.is_connected(_on_area_input):
		area.input_event.connect(_on_area_input)

	# Инициализируем микро-вариацию яркости, если не была установлена в setup()
	if _brightness_variation == 1.0:
		_brightness_variation = 0.95 + randf() * 0.1  # От 0.95 до 1.05

	# Если параметры дыхания / вращения / цвета ещё не заданы из setup()
	if _breath_speed_factor == 1.0 and _breath_phase == 0.0:
		_breath_speed_factor = randf_range(0.6, 1.4)
		_breath_phase = randf() * TAU
	if _color_speed == 0.0:
		_color_speed = randf_range(0.15, 0.4)
		_color_phase = randf() * TAU
	if _rot_amp == 0.0:
		_rot_amp = deg_to_rad(randf_range(1.0, 4.0))
		_rot_speed = randf_range(0.5, 1.5)
		_rot_phase = randf() * TAU
		_rot_timer = randf_range(0.5, 2.5)
		_rot_active = randf() < 0.7

	_update_visual_state()
	_reset_geometry()

	# Случайный старт фазы для разнообразия
	_time_accum = randf() * TAU


func _on_screen_entered() -> void:
	set_process(true)


func _on_screen_exited() -> void:
	set_process(false)
	if sprite:
		sprite.position = Vector2.ZERO


func _process(delta: float) -> void:
	if wall_mode == WALL_MODE_STATIC:
		return

	# Проверка настройки: если выключено — стена статична
	if not GameState.wall_breathing_enabled:
		if sprite:
			sprite.position = Vector2.ZERO
		return

	# Дыхание каждый кадр — каждый сегмент двигается рандомно (дыхание мира)
	_update_minimal_animation(delta)

	_change_timer += delta
	if _change_interval <= 0.0:
		_change_interval = randf_range(30.0, 90.0)

	if _change_timer >= _change_interval:
		_change_timer = 0.0
		_change_interval = randf_range(30.0, 90.0)
		change_side_randomly()


func change_side_randomly() -> void:
	# Лёгкая смена оттенка для видимого "мигания" без тяжёлых вычислений
	if sprite == null:
		return
	# Немного меняем коэффициент яркости и пересчитываем цвет
	_brightness_variation = lerp(0.8, 1.2, randf())
	_update_visual_state()


func _on_area_input(
	viewport: Viewport,
	event: InputEvent,
	shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed:
		_try_buy()


func _try_buy() -> void:
	if wall_data == null:
		push_warning("WallSegment: wall_data == null")
		return

	if not Engine.has_singleton("GameState"):
		push_warning("GameState singleton not found")
		return

	var buyer_uid: String = GameState.player_uid if Engine.has_singleton("GameState") else ""
	# Цена сегмента берётся из WallData с учётом высоты
	var price: int = 0
	if wall_data != null and segment_id != "":
		price = wall_data.get_segment_price(segment_id)
	# Покупаем текущую сторону сегмента
	var ok: bool = wall_data.buy_side(segment_id, side_id, buyer_uid, price)
	_update_visual_state()


func _update_visual_state() -> void:
	if sprite == null:
		return

	# Базовый бирюзовый цвет по стороне мега-куба
	var base_color: Color = _get_side_color()

	# Микро-вариация яркости (фиксированная для сегмента, НЕ по времени)
	base_color.r *= _brightness_variation
	base_color.g *= _brightness_variation
	base_color.b *= _brightness_variation

	# Если сегмент куплен, слегка подмешиваем зелёный (для будущего UI)
	if wall_data != null:
		var seg := wall_data.get_segment(segment_id)
		if seg != null:
			var owner := str(seg.get("owner", ""))
			if owner != "":
				var owned_color := Color(0.1, 0.8, 0.2)
				base_color = base_color.lerp(owned_color, 0.3)

	_base_color = base_color
	# Немедленно применяем цвет (дальше он будет чуть "дрожать" по яркости)
	sprite.modulate = _base_color


func get_base_position_y() -> float:
	return base_position_y


func _get_side_color() -> Color:
	# ВРЕМЕННАЯ ВИЗУАЛИЗАЦИЯ: разные оттенки бирюзового для каждой стороны
	match side_id:
		"front":
			return Color(0.0, 0.8, 0.7)  # Яркий бирюзовый
		"back":
			return Color(0.0, 0.5, 0.5)  # Тёмно-бирюзовый
		"left":
			return Color(0.2, 0.7, 0.6)  # Зелёно-бирюзовый
		"right":
			return Color(0.1, 0.6, 0.8)  # Голубовато-бирюзовый
		"top":
			return Color(0.3, 0.9, 0.8)  # Светло-бирюзовый
		"bottom":
			return Color(0.0, 0.4, 0.6)  # Холодный сине-бирюзовый
		_:
			return Color(0.0, 0.8, 0.7)  # По умолчанию яркий бирюзовый


# ---------------------------------------------------------------------------
# Геометрия и минимальная анимация
# ---------------------------------------------------------------------------

func _reset_geometry() -> void:
	# КРИТИЧНО: идеальный квадрат 48×48, стена к стене
	# Запрещено: scale ≠ Vector2.ONE, rotation ≠ 0, диагональные смещения
	if sprite == null:
		return

	# Базовая локальная позиция для "дыхания"
	sprite.position = Vector2.ZERO
	_base_y = sprite.position.y
	sprite.scale = Vector2.ONE
	sprite.rotation = 0.0


func _update_minimal_animation(delta: float) -> void:
	# Каждый сегмент двигается рандомно — дыхание мира
	if sprite == null:
		return

	_time_accum += delta
	if _time_accum >= TAU:
		_time_accum = fmod(_time_accum, TAU)

	var phase: float = _time_accum * _breath_speed * _breath_speed_factor + _breath_phase
	var amp: float = _breath_amplitude

	var offset_y: float = sin(phase) * amp
	var offset_x: float = cos(phase) * (amp * 0.5)
	sprite.position = Vector2(offset_x, _base_y + offset_y)
