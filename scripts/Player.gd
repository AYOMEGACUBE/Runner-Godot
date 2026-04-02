extends CharacterBody2D

const PhysicsConfig = preload("res://scripts/config/PhysicsConfig.gd")

# ============================================================================
# Player.gd — Улучшенная логика смерти: падение на 2 экрана от последней платформы
# ----------------------------------------------------------------------------
# - Смерть наступает, если игрок упал на 2 экрана ниже последней безопасной позиции
# - Резерв: абсолютный предел FALL_LIMIT_Y_ABSOLUTE
# - Защита от ложных срабатываний: условие должно держаться FALL_DEATH_HOLD_SECONDS
# - DEBUG вывод можно отключить
# ============================================================================

func _log(message: String) -> void:
	FileLogger.write_log(message)
	if DEBUG:
		print(message)

@export var GRAVITY: float = PhysicsConfig.GRAVITY
@export var MOVE_SPEED: float = PhysicsConfig.MOVE_SPEED
@export var JUMP_VELOCITY: float = PhysicsConfig.JUMP_VELOCITY
@export var DEFAULT_MOVE_DIR: float = 1.0

@export var JUMP_COOLDOWN: float = 0.08
@export var USE_PIXEL_SNAP: bool = true

# Камера / абсолютные параметры
@export var DEATH_SCREENS: float = 2.0  # Количество экранов ниже последней безопасной позиции для смерти
@export var FALL_LIMIT_Y_ABSOLUTE: float = 15000.0

# Сколько секунд условие должно держаться, прежде чем вызвать _die()
@export var FALL_DEATH_HOLD_SECONDS: float = 0.5

# Включить/выключить подробный лог
@export var DEBUG: bool = true

@export_file("*.tscn") var main_menu_scene: String = "res://MainMenu.tscn"

# Отдельная сцена для экрана Game Over.
@export_file("*.tscn") var game_over_scene: String = "res://GameOver.tscn"

# ----------------------------------------------------------------------------
# Ресурсы героев (настраиваются в инспекторе)
# ----------------------------------------------------------------------------
@export var frames_default: SpriteFrames
@export var frames_monster: SpriteFrames
@export var frames_red: SpriteFrames
@export var frames_blue: SpriteFrames
@export var frames_orange: SpriteFrames

var move_dir: float = 0.0
var jump_timer: float = 0.0
var _was_touching_floor: bool = false

# Кастом-аватар
var _custom_tex_up: Texture2D = null
var _custom_tex_down: Texture2D = null
var _using_custom_avatar: bool = false
const CUSTOM_AVATAR_TARGET_SIZE_PX: int = 128

# Таймеры для "удержания" условия смерти
var _fall_death_timer: float = 0.0

# Последняя безопасная позиция Y (где стоял на платформе)
var last_safe_y: float = 0.0

@onready var cam: Camera2D = $Camera2D
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var custom_sprite: Sprite2D = $CustomAvatarSprite

func _ready() -> void:
	PhysicsConfig.calculate_jump_metrics()
	if DEBUG:
		_log("[PLAYER_READY] initializing at pos=%s" % global_position)
	# Коллизии: игрок = слой 1, реагируем на платформы (1) и монеты (2)
	set_collision_layer_value(1, true)
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, true)
	for i in range(3, 33):
		set_collision_mask_value(i, false)

	if abs(DEFAULT_MOVE_DIR) < 0.001:
		DEFAULT_MOVE_DIR = 1.0
	move_dir = DEFAULT_MOVE_DIR

	_was_touching_floor = is_on_floor()
	
	# ИНИЦИАЛИЗИРУЕМ ПОСЛЕДНЮЮ БЕЗОПАСНУЮ ПОЗИЦИЮ
	last_safe_y = global_position.y
	if DEBUG:
		_log("[PLAYER_READY] last_safe_y=%.1f move_dir=%.1f touching_floor=%s" % [last_safe_y, move_dir, _was_touching_floor])

	# ----------------------------------------------------------------------------
	# ИНИЦИАЛИЗАЦИЯ МАКСИМАЛЬНОЙ ВЫСОТЫ ДЛЯ CUBEVIEW / GameOver
	# ----------------------------------------------------------------------------
	# В CubeView и GameOver нужно знать, какую максимальную высоту (минимальное Y)
	# достигал игрок за забег. Инициализируем max_height_reached стартовой позицией.
	# Далее это значение уменьшается по мере «подъёма» игрока вверх (Y ↓ в Godot).
	var gs: Node = get_node_or_null("/root/GameState")
	if gs != null:
		GameState.max_height_reached = global_position.y
		if DEBUG:
			_log("[PLAYER_READY] initialized max_height_reached=%.1f" % global_position.y)

	if cam:
		cam.make_current()

	_apply_visual_mode()

func _apply_visual_mode() -> void:
	_using_custom_avatar = bool(GameState.get_use_custom_avatar())

	if _using_custom_avatar:
		var ok: bool = _load_custom_avatar_textures()
		if ok:
			if custom_sprite:
				custom_sprite.visible = true
			if anim:
				anim.visible = false
			if DEBUG:
				pass
			return
		else:
			_using_custom_avatar = false
			GameState.set_use_custom_avatar(false)
			if DEBUG:
				pass

	if custom_sprite:
		custom_sprite.visible = false
	if anim:
		anim.visible = true

	var hero_id: String = str(GameState.get_selected_hero_id()).strip_edges()
	if hero_id == "":
		hero_id = "default"

	var target_frames: SpriteFrames = null
	match hero_id:
		"monster": target_frames = frames_monster
		"red":     target_frames = frames_red
		"blue":    target_frames = frames_blue
		"orange":  target_frames = frames_orange
		_:         target_frames = frames_default

	if target_frames:
		anim.sprite_frames = target_frames

	if anim and anim.sprite_frames != null and anim.sprite_frames.has_animation("JUMP"):
		anim.stop()
		anim.animation = "JUMP"
		anim.frame = 0

func _load_custom_avatar_textures() -> bool:
	_custom_tex_up = null
	_custom_tex_down = null

	var up_path: String = str(GameState.get_custom_avatar_up_path()).strip_edges()
	var down_path: String = str(GameState.get_custom_avatar_down_path()).strip_edges()

	if up_path == "":
		up_path = "user://custom_jump_up.png"
	if down_path == "":
		down_path = "user://custom_jump_down.png"

	if not FileAccess.file_exists(up_path) or not FileAccess.file_exists(down_path):
		return false

	var img_up: Image = Image.new()
	if img_up.load(up_path) != OK:
		return false
	var img_down: Image = Image.new()
	if img_down.load(down_path) != OK:
		return false

	if img_up.get_format() != Image.FORMAT_RGBA8:
		img_up.convert(Image.FORMAT_RGBA8)
	if img_down.get_format() != Image.FORMAT_RGBA8:
		img_down.convert(Image.FORMAT_RGBA8)

	var fitted_up: Image = _fit_image_into_square(img_up, CUSTOM_AVATAR_TARGET_SIZE_PX)
	var fitted_down: Image = _fit_image_into_square(img_down, CUSTOM_AVATAR_TARGET_SIZE_PX)

	var up_tex: ImageTexture = ImageTexture.new()
	var down_tex: ImageTexture = ImageTexture.new()
	up_tex.set_image(fitted_up)
	down_tex.set_image(fitted_down)

	_custom_tex_up = up_tex
	_custom_tex_down = down_tex

	if custom_sprite:
		custom_sprite.texture = _custom_tex_up

	return true

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var center: float = get_viewport_rect().size.x * 0.5
			move_dir = -1.0 if event.position.x < center else 1.0
	elif event is InputEventScreenTouch and event.pressed:
		var center: float = get_viewport_rect().size.x * 0.5
		move_dir = -1.0 if event.position.x < center else 1.0

func _physics_process(delta: float) -> void:
	# ВАЖНО: сначала проверяем флаг конца игры, чтобы после смерти
	# не было бесконечного спама логов от игрока.
	var gs: Node = get_node_or_null("/root/GameState")
	if gs != null and GameState.is_game_over:
		return

	var old_velocity: Vector2 = velocity
	velocity.y += GRAVITY * delta

	var key_dir: float = 0.0
	if Input.is_action_pressed("move_left"):
		key_dir -= 1.0
	if Input.is_action_pressed("move_right"):
		key_dir += 1.0
	if key_dir != 0.0:
		move_dir = key_dir

	velocity.x = move_dir * MOVE_SPEED
	move_and_slide()
	
	if DEBUG and (old_velocity - velocity).length() > 10.0:
		_log("[PLAYER_PHYSICS] pos=%s velocity=%s move_dir=%.1f" % [global_position, velocity, move_dir])

	if USE_PIXEL_SNAP:
		global_position = global_position.round()

	# ----------------------------------------------------------------------------
	# ОБНОВЛЕНИЕ МАКСИМАЛЬНОЙ ВЫСОТЫ ДЛЯ CUBEVIEW / GameOver
	# ----------------------------------------------------------------------------
	# В Godot Y растёт вниз. МЕНЬШЕ Y = выше на экране.
	# Сохраняем минимальное Y за забег (максимальная достигнутая высота).
	# gs уже получен выше.
	if gs != null and not GameState.is_game_over:
		if GameState.max_height_reached == 0.0:
			GameState.max_height_reached = global_position.y
		elif global_position.y < GameState.max_height_reached:
			GameState.max_height_reached = global_position.y

	jump_timer = max(0.0, jump_timer - delta)

	var touching_floor_now: bool = _check_floor_collision()
	
	# ОБНОВЛЯЕМ ПОСЛЕДНЮЮ БЕЗОПАСНУЮ ПОЗИЦИЮ ПРИ КАСАНИИ ПЛАТФОРМЫ
	if touching_floor_now:
		var old_safe_y: float = last_safe_y
		last_safe_y = global_position.y
		if DEBUG and abs(old_safe_y - last_safe_y) > 1.0:
			_log("[PLAYER_LANDED] pos=%s last_safe_y=%.1f->%.1f" % [global_position, old_safe_y, last_safe_y])
	
	if touching_floor_now and not _was_touching_floor and jump_timer <= 0.0:
		velocity.y = JUMP_VELOCITY
		jump_timer = JUMP_COOLDOWN
		if DEBUG:
			_log("[PLAYER_JUMP] pos=%s jump_velocity=%.1f" % [global_position, JUMP_VELOCITY])

	_was_touching_floor = touching_floor_now

	_update_jump_visual()

	# Проверка смерти с удержанием порога (debounce)
	_process_fall_death(delta)

func _update_jump_visual() -> void:
	var going_up: bool = (velocity.y < 0.0)

	if anim:
		anim.flip_h = (move_dir < 0.0)
	if custom_sprite:
		custom_sprite.flip_h = (move_dir < 0.0)

	if _using_custom_avatar:
		if custom_sprite and _custom_tex_up != null and _custom_tex_down != null:
			custom_sprite.texture = _custom_tex_up if going_up else _custom_tex_down
		return

	if anim == null or anim.sprite_frames == null:
		return
	if not anim.sprite_frames.has_animation("JUMP"):
		return

	anim.stop()
	anim.animation = "JUMP"
	anim.frame = 0 if going_up else 1

# ----------------------------------------------------------------------------
# Обработка смерти с удержанием порога (debounce)
# ----------------------------------------------------------------------------
func _process_fall_death(delta: float) -> void:
	var gs_over: Node = get_node_or_null("/root/GameState")
	if gs_over != null and GameState.is_game_over:
		return

	if cam == null:
		# Если камеры нет — используем только абсолютный лимит
		if global_position.y > FALL_LIMIT_Y_ABSOLUTE:
			_fall_death_timer += delta
		else:
			_fall_death_timer = 0.0

		if _fall_death_timer >= FALL_DEATH_HOLD_SECONDS:
			_die()
		return

	# Вычисляем видимую высоту экрана с учётом зума
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var viewport_height: float = max(1.0, viewport_size.y)

	var zoom_y: float = float(cam.zoom.y)
	var visible_height: float = viewport_height * zoom_y

	# 🔴 ИЗМЕНЕНИЕ: Используем last_safe_y вместо позиции камеры
	# Смерть наступает, если игрок упал на 2 экрана ниже последней безопасной позиции
	var death_y: float = last_safe_y + visible_height * DEATH_SCREENS

	# Лог для отладки
	if DEBUG:
		pass

	# Условие: игрок ниже death_y (2 экрана от последней безопасной позиции)
	var fall_from_safe_condition: bool = (global_position.y > death_y)
	
	# Условие абсолютного лимита
	var absolute_condition: bool = (global_position.y > FALL_LIMIT_Y_ABSOLUTE)
	
	if DEBUG and (fall_from_safe_condition or absolute_condition):
		_log("[PLAYER_DEATH_CHECK] pos_y=%.1f death_y=%.1f last_safe_y=%.1f fall_from_safe=%s absolute=%s" % [global_position.y, death_y, last_safe_y, fall_from_safe_condition, absolute_condition])

	# ----------------------------------------------------------------------------
	# ВРЕМЕННЫЙ РЕЖИМ: МГНОВЕННАЯ СМЕРТЬ ДЛЯ ОТЛАДКИ GAME OVER → CUBEVIEW
	# ----------------------------------------------------------------------------
	# Сейчас нам нужно гарантированно и быстро попадать в Game Over,
	# чтобы отладить связку:
	#   смерть игрока -> GameState.is_game_over -> переход в меню/экран
	#   -> последующий вход в CubeView и проверка высотного гейта.
	#
	# Поэтому мы ВРЕМЕННО отключаем "debounce" (удержание условия в течение
	# FALL_DEATH_HOLD_SECONDS) и вызываем _die() сразу при выполнении
	# одного из условий смерти.
	#
	# Архитектурно:
	# - Вся логика смерти по‑прежнему сосредоточена в _process_fall_death().
	# - Поле FALL_DEATH_HOLD_SECONDS и таймер _fall_death_timer остаются
	#   и могут быть легко возвращены в игру — блок кода с debounce ниже
	#   оставлен как готовый шаблон.
	# - Остальной геймплей и стена не затронуты.
	#
	# Как вернуть debounce позже:
	# 1. Закомментировать этот "мгновенный" блок.
	# 2. Разкомментировать/включить блок ниже "DEBOUNCE‑ВЕРСИЯ".
	#
	# Это даёт:
	# - Сейчас: предельно предсказуемую, мгновенную смерть для отладки.
	# - В будущем: возможность мягко фильтровать ложные срабатывания
	#   (например, при дрожании камеры или резких ускорениях), просто
	#   вернув старую логику без переписывания функции.
	if fall_from_safe_condition or absolute_condition:
		_die()
		return

	# ----------------------------------------------------------------------------
	# DEBOUNCE‑ВЕРСИЯ (ИЗНАЧАЛЬНАЯ ЛОГИКА С УДЕРЖАНИЕМ УСЛОВИЯ)
	# ----------------------------------------------------------------------------
	# Оставлена как готовый шаблон на будущее — сейчас НЕ используется,
	# потому что выше стоит мгновенный возврат.
	# ----------------------------------------------------------------------------

	# Прежний вариант:
	# # Если хоть одно условие истинно — увеличиваем таймер удержания
	# if fall_from_safe_condition or absolute_condition:
	# 	_fall_death_timer += delta
	# else:
	# 	# Сбрасываем таймер при возврате в безопасную зону
	# 	_fall_death_timer = 0.0
	#
	# # Если условие держалось достаточно долго — умираем
	# if _fall_death_timer >= FALL_DEATH_HOLD_SECONDS:

# ----------------------------------------------------------------------------
# Смерть / смена сцены
# ----------------------------------------------------------------------------
func _die() -> void:
	var gs_root: Node = get_node_or_null("/root/GameState")
	if gs_root != null:
		if GameState.is_game_over:
			if DEBUG:
				_log("[PLAYER_DIE] already game_over, ignoring")
			return
		GameState.is_game_over = true
		if DEBUG:
			_log("[PLAYER_DIE] pos=%s last_safe_y=%.1f max_height=%.1f score=%d" % [global_position, last_safe_y, GameState.max_height_reached, GameState.score])

	# На всякий случай останавливаем физику до смены сцены.
	set_physics_process(false)

	# В редакторе — перезагрузим текущую сцену для удобства,
	# чтобы не прыгать по полноэкранному Game Over при тестах.
	if Engine.is_editor_hint():
		get_tree().reload_current_scene()
		return

	# ----------------------------------------------------------------------------
	# ФИКСАЦИЯ ДАННЫХ ПЕРЕД ПЕРЕХОДОМ НА GameOver
	# ----------------------------------------------------------------------------
	# Player НЕ обновляет UI. Player ТОЛЬКО фиксирует данные в GameState.
	# GameOver читает last_run_score и last_run_max_height — записываем ДО смены сцены.
	var gs_die: Node = get_node_or_null("/root/GameState")
	if gs_die != null:
		GameState.last_run_score = GameState.score
		GameState.last_run_max_height = GameState.max_height_reached
		GameState.has_finished_run = true
		if DEBUG:
			_log("[PLAYER_DIE] saved run data: score=%d height=%.1f" % [GameState.last_run_score, GameState.last_run_max_height])

	# Регистрируем результат забега ОДИН раз, до перехода на GameOver.
	GameState.register_run_finished()
	if DEBUG:
		_log("[PLAYER_DIE] registered run finished")
	
	# ----------------------------------------------------------------------------
	# Переход на экран Game Over
	# ----------------------------------------------------------------------------
	# ВАЖНО:
	# - Мы больше НЕ перезапускаем Level.tscn напрямую из Player.
	# - Мы НЕ уходим сразу в главное меню.
	# - Вместо этого используем отдельную UI-сцену GameOver.tscn, которая:
	#   * читает данные из GameState (очки, высоту и т.д.),
	#   * даёт кнопки: "View Cube", "Restart Run", "Main Menu".
	# - Логика стены и сегментов НЕ ЗАТРАГИВАЕТСЯ, т.к. они существуют
	#   только в Level / CubeView, а Game Over — чистый UI.
	# ----------------------------------------------------------------------------
	var target_scene: String = game_over_scene
	if target_scene == "" or target_scene == null:
		# Фоллбек: если по какой-то причине путь к GameOver не задан,
		# уходим в главное меню или перезагружаем текущую сцену.
		target_scene = main_menu_scene
	
	if target_scene != "" and target_scene != null:
		if DEBUG:
			_log("[PLAYER_DIE] changing scene to: %s" % target_scene)
		var err: int = get_tree().change_scene_to_file(target_scene)
		if err != OK:
			push_error("Player.gd: cannot load game over or main menu: " + target_scene)
			if DEBUG:
				_log("[PLAYER_DIE] scene change failed, reloading current scene")
			get_tree().reload_current_scene()
	else:
		if DEBUG:
			_log("[PLAYER_DIE] no target scene, reloading current")
		get_tree().reload_current_scene()

func _check_floor_collision() -> bool:
	var count: int = get_slide_collision_count()
	if count == 0:
		return is_on_floor()
	for i in range(count):
		var c = get_slide_collision(i)
		if c and c.get_normal().y < -0.7:
			return true
	return false

func _fit_image_into_square(src: Image, target_size: int) -> Image:
	var src_w: int = src.get_width()
	var src_h: int = src.get_height()

	if src_w <= 0 or src_h <= 0:
		var empty: Image = Image.create(target_size, target_size, false, Image.FORMAT_RGBA8)
		empty.fill(Color(0,0,0,0))
		return empty

	var dst: Image = Image.create(target_size, target_size, false, Image.FORMAT_RGBA8)
	dst.fill(Color(0, 0, 0, 0))

	var resized: Image = src.duplicate()
	if resized.get_format() != Image.FORMAT_RGBA8:
		resized.convert(Image.FORMAT_RGBA8)

	var scale: float = min(float(target_size) / float(src_w), float(target_size) / float(src_h))
	var new_w: int = max(1, int(round(float(src_w) * scale)))
	var new_h: int = max(1, int(round(float(src_h) * scale)))

	resized.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	var x: int = int((target_size - new_w) / 2)
	var y: int = int((target_size - new_h) / 2)

	dst.blit_rect(resized, Rect2i(0, 0, new_w, new_h), Vector2i(x, y))
	return dst
