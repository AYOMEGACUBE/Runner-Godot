extends CanvasLayer

# ============================================================================
# GameOver.gd — UI‑экран завершения забега
# ----------------------------------------------------------------------------
# ОБЯЗАННОСТИ:
# - Показать результаты прошедшего забега:
#   * максимальная достигнутая высота (GameState.max_height_reached)
#   * набранные очки (GameState.score)
# - Дать игроку три варианта:
#   * View Cube    → перейти в CubeView.tscn для просмотра мегакуба
#   * Restart Run  → начать новый забег (Level.tscn)
#   * Main Menu    → вернуться в главное меню (MainMenu.tscn)
#
# ВАЖНО:
# - На этом экране НЕТ игрока, физики и стены. Это чистый UI.
# - GameState.is_game_over на момент входа сюда уже должен быть true и
#   НЕ должен сбрасываться до момента Restart Run.
# - Стена и сегменты продолжают жить в своих сценах (Level / CubeView) и
#   не зависят от этого экрана.
# ============================================================================

@export_file("*.tscn")
var level_scene: String = "res://level.tscn"

@export_file("*.tscn")
var main_menu_scene: String = "res://MainMenu.tscn"

@export_file("*.tscn")
var cube_view_scene: String = "res://CubeView.tscn"

@onready var label_height: Label = $Panel/VBox/HeightLabel
@onready var label_score: Label = $Panel/VBox/ScoreLabel

@onready var button_view_cube: Button = $Panel/VBox/Buttons/ViewCubeButton
@onready var button_restart: Button = $Panel/VBox/Buttons/RestartButton
@onready var button_main_menu: Button = $Panel/VBox/Buttons/MainMenuButton


func _ready() -> void:
	# Подключаем сигналы кнопок один раз при входе на экран.
	if button_view_cube != null and not button_view_cube.pressed.is_connected(_on_view_cube_pressed):
		button_view_cube.pressed.connect(_on_view_cube_pressed)

	if button_restart != null and not button_restart.pressed.is_connected(_on_restart_pressed):
		button_restart.pressed.connect(_on_restart_pressed)

	if button_main_menu != null and not button_main_menu.pressed.is_connected(_on_main_menu_pressed):
		button_main_menu.pressed.connect(_on_main_menu_pressed)

	# ВАЖНО: значения берём ТОЛЬКО из GameState, и только после того,
	# как сцена уже в дереве. Используем отложенный вызов, чтобы не зависеть
	# от порядка _ready у разных нод.
	call_deferred("_update_stats_labels")


func _update_stats_labels() -> void:
	# Если AutoLoad GameState по какой‑то причине не добавлен в дерево
	# (маловероятно в реальной игре, но возможно при F6), просто выходим.
	var gs_node: Node = get_node_or_null("/root/GameState")
	if gs_node == null:
		# Безопасный фоллбек: показываем нули, НО НЕ ТРОГАЕМ GameState.
		if label_height != null and label_height.text == "":
			label_height.text = "Height: 0"
		if label_score != null and label_score.text == "":
			label_score.text = "Score: 0"
		return

	# Основные значения читаем ТОЛЬКО из GameState.
	# Логику подсчёта/сброса не трогаем, только отображаем.

	# 1) SCORE (монеты за забег)
	var score_val: int = 0
	if "last_run_score" in GameState:
		score_val = int(GameState.last_run_score)
	else:
		score_val = int(GameState.score)

	if label_score != null:
		label_score.text = "Score: " + str(score_val)

	# 2) HEIGHT (максимальная достигнутая высота)
	# Предпочитаем last_run_max_height, если есть; иначе max_height_reached.
	var height_val: float = 0.0
	if "last_run_max_height" in GameState:
		height_val = float(GameState.last_run_max_height)
	else:
		height_val = float(GameState.max_height_reached)

	# Если значение никогда не инициализировалось (первый запуск / F6),
	# height_val останется 0. Это честный fallback.
	if label_height != null:
		label_height.text = "Height: " + str(int(abs(height_val)))


func _on_view_cube_pressed() -> void:
	# Переходим в CubeView.tscn для просмотра мегакуба и возможной покупки сегментов.
	# ВАЖНО:
	# - GameState.max_height_reached уже содержит высоту‑гейт для CubeView.
	# - GameState.is_game_over остаётся true; CubeView сам решит, как это использовать
	#   (обычно ему всё равно, он просто читает max_height_reached).
	var target: String = cube_view_scene
	if target == "" or target == null:
		# Если по какой‑то причине путь не задан, логируем ошибку и остаёмся на экране.
		push_error("GameOver.gd: cube_view_scene is not set")
		return

	var err: int = get_tree().change_scene_to_file(target)
	if err != OK:
		push_error("GameOver.gd: cannot load CubeView scene: " + target)


func _on_restart_pressed() -> void:
	# Начинаем НОВЫЙ забег:
	# - сбрасываем GameState (start_new_run)
	# - is_game_over внутри start_new_run устанавливается в false
	# - загружаем Level.tscn
	var gs_node: Node = get_node_or_null("/root/GameState")
	if gs_node == null:
		push_error("GameOver.gd: GameState node not found in scene tree, cannot restart run")
	else:
		# В Godot 4 автозагрузки находятся как /root/GameState, а не через Engine.has_singleton.
		# Поэтому безопасно обращаемся к глобальному GameState и сбрасываем состояние забега.
		GameState.start_new_run()

	var target: String = level_scene
	if target == "" or target == null:
		push_error("GameOver.gd: level_scene is not set")
		return

	var err: int = get_tree().change_scene_to_file(target)
	if err != OK:
		push_error("GameOver.gd: cannot load level scene: " + target)


func _on_main_menu_pressed() -> void:
	# Возврат в главное меню:
	# - ТЕКУЩИЙ забег остаётся завершённым (is_game_over = true).
	# - На следующем старте Play кнопка сама вызовет start_new_run().
	var target: String = main_menu_scene
	if target == "" or target == null:
		push_error("GameOver.gd: main_menu_scene is not set")
		return

	var err: int = get_tree().change_scene_to_file(target)
	if err != OK:
		push_error("GameOver.gd: cannot load main menu: " + target)
