extends Control
# HUD.gd — отображает текущий счёт и имя игрока

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/FileLogger")
	if logger != null and logger.has_method("write_log"):
		logger.call("write_log", message)
	else:
		print(message)

@export_file("*.tscn")
var main_menu_scene: String = "res://scenes/main_menu/MainMenu.tscn"

@onready var score_label: Label = $VBoxContainer/ScoreLabel
@onready var name_label: Label = $VBoxContainer/NameLabel
@onready var back_button: Button = $BackButton
var _refresh_timer: Timer = null

func _ready() -> void:
	if back_button != null and not back_button.pressed.is_connected(_on_back_button_pressed):
		back_button.pressed.connect(_on_back_button_pressed)
	_refresh_labels()
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = false
	_refresh_timer.wait_time = 0.1
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_refresh_labels)
	_refresh_timer.start()

func _refresh_labels() -> void:
	var alt_pts: int = GameState.get_altitude_points()
	var coins: int = GameState.run_coin_bonus
	score_label.text = "Height pts: %d | Coins: %d" % [alt_pts, coins]
	name_label.text = "Player: " + GameState.get_hud_display_name()

func _on_back_button_pressed() -> void:
	if not Engine.is_editor_hint():
		_log("[HUD] back_button pressed, registering run")
		GameState.register_run_finished()
		if main_menu_scene == "":
			push_error("HUD: не задан путь к сцене главного меню (main_menu_scene).")
			_log("[HUD] ERROR - main_menu_scene not set")
			return
		_log("[HUD] changing scene to: %s" % main_menu_scene)
		var err := get_tree().change_scene_to_file(main_menu_scene)
		if err != OK:
			push_error("HUD: не удалось загрузить сцену главного меню: " + main_menu_scene)
			_log("[HUD] ERROR - scene change failed: %s" % main_menu_scene)
