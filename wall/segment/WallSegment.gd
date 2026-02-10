extends Node2D
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

var wall_data: WallData = null
var side_id: String = "front"  # Сторона мега-куба

# Внутренние переменные для анимации
var _time_accum: float = 0.0

# Вертикальное "дыхание" (амплитуда ~2–3 px, период ~2 сек)
var _breath_amplitude: float = 3.0
var _breath_speed: float = PI  # базовая скорость
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

func setup(id: String, side: String, data: WallData) -> void:
	segment_id = id
	side_id = side
	wall_data = data
	
	# Генерируем микро-вариацию яркости (±5-10%)
	_brightness_variation = 0.95 + randf() * 0.1  # От 0.95 до 1.05

	# Асинхронные параметры "дыхания"
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


func _ready() -> void:
	# Подключаем клики
	if area and not area.input_event.is_connected(_on_area_input):
		area.input_event.connect(_on_area_input)

	# Инициализируем микро-вариацию яркости, если не была установлена в setup()
	if _brightness_variation == 1.0:
		_brightness_variation = 0.95 + randf() * 0.1  # От 0.95 до 1.05

	# Если параметры "дыхания" / вращения / цвета ещё не заданы из setup()
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
	
	# Случайное начальное смещение для разнообразия
	_time_accum = randf() * TAU


func _process(delta: float) -> void:
	if wall_mode == WALL_MODE_STATIC:
		return

	# Остановка логики после смерти игрока / смены сцены
	# Пытаемся использовать GameState, если там есть флаг, иначе — текущую сцену.
	if Engine.has_singleton("GameState"):
		var gs = GameState
		var is_over: bool = false
		# Если в будущем появится флаг is_game_over / is_player_alive — поддержим его.
		if gs.get("is_game_over") != null:
			is_over = bool(gs.get("is_game_over"))
		if is_over:
			set_process(false)
			return
	
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		set_process(false)
		return
	
	# Если мы уже не в Level (например, в главном меню) — останавливаемся.
	if tree.current_scene.name != "Level":
		set_process(false)
		return

	# Обычный хаотичный режим
	if segment_mode == SEGMENT_MODE_RANDOM:
		_update_minimal_animation(delta)
		return

	# Режим синхронного показа (архитектура на будущее)
	if segment_mode == SEGMENT_MODE_SYNC_SHOW:
		if _sync_show_timer > 0.0:
			_sync_show_timer -= delta
			_update_minimal_animation(delta)
		else:
			segment_mode = SEGMENT_MODE_RANDOM
		return


# ---------------------------------------------------------------------------

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

	var buyer_uid: String = GameState.player_uid
	var ok: bool = wall_data.buy_side(segment_id, buyer_uid)

	if ok:
		print("✅ Куплено:", segment_id)
	else:
		print("⛔ Уже куплено:", segment_id)

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

	# Базовая локальная позиция по Y для "дыхания"
	sprite.position = Vector2.ZERO
	_base_y = sprite.position.y
	sprite.scale = Vector2.ONE
	sprite.rotation = 0.0


func _update_minimal_animation(delta: float) -> void:
	# "Дыхание" и вращение одного сегмента (куба).
	if sprite == null:
		return

	_time_accum += delta
	if _time_accum >= TAU:
		_time_accum = fmod(_time_accum, TAU)

	# Базовая амплитуда "дыхания" по вертикали
	var amp := _breath_amplitude
	var speed_factor := 1.0

	# Сторонозависимое движение (разные фазы/амплитуды по сторонам)
	match side_id:
		"front":
			# Почти неподвижен — еле заметное движение
			amp *= 0.3
		"left":
			# Чуть более заметное дыхание
			amp *= 1.0
		"right":
			# Чуть более заметное дыхание
			amp *= 1.0
		"top":
			# Более медленное движение
			amp *= 0.7
			speed_factor = 0.5
		"back", "bottom":
			# Слабее базового
			amp *= 0.6
		_:
			pass

	# DEBUG: усиленная амплитуда для наглядности (около 2–3 px)
	var offset_y: float = sin((_time_accum * _breath_speed * _breath_speed_factor + _breath_phase) * speed_factor) * amp
	sprite.position.y = _base_y + offset_y

	# Рандомное вращение с паузами (асинхронно для каждого сегмента)
	_rot_timer -= delta
	if _rot_timer <= 0.0:
		_rot_active = not _rot_active
		if _rot_active:
			_rot_timer = randf_range(0.6, 2.0)   # активная фаза
		else:
			_rot_timer = randf_range(0.8, 3.0)   # пауза (без вращения)

	if _rot_active and _rot_amp > 0.0:
		_rot_time += delta * _rot_speed
		var rot := sin(_rot_time + _rot_phase) * _rot_amp
		sprite.rotation = rot
	else:
		sprite.rotation = 0.0

	# Независимое "дыхание" цвета (очень мягкая дрожь яркости, без мигания)
	_color_time += delta
	var t := _color_time * _color_speed + _color_phase
	var jitter := 1.0 + 0.06 * sin(t)  # ±6% по яркости
	var col := Color(
		_base_color.r * jitter,
		_base_color.g * jitter,
		_base_color.b * jitter,
		_base_color.a
	)
	sprite.modulate = col

	# Консольный маркер жизни — один раз на сегмент (DEBUG)
	if not _animation_logged:
		_animation_logged = true
		print("[WallSegment] animation active: ", segment_id)

