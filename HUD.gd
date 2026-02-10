extends Control
# HUD.gd — отображает текущий счёт и имя игрока

@export_file("*.tscn")
var main_menu_scene: String = "res://MainMenu.tscn"

@onready var score_label: Label = $VBoxContainer/ScoreLabel
@onready var name_label: Label = $VBoxContainer/NameLabel
@onready var back_button: Button = $BackButton

func _ready() -> void:
	if back_button != null and not back_button.pressed.is_connected(_on_back_button_pressed):
		back_button.pressed.connect(_on_back_button_pressed)
	_refresh_labels()

func _process(_delta: float) -> void:
	_refresh_labels()

func _refresh_labels() -> void:
	var pn := GameState.player_name
	if pn == "" or pn == "NoName":
		pn = "NoName"
	score_label.text = "Score: " + str(GameState.score)
	name_label.text = "Player: " + pn

func _on_back_button_pressed() -> void:
	if not Engine.is_editor_hint():
		GameState.register_run_finished()
		if main_menu_scene == "":
			push_error("HUD: не задан путь к сцене главного меню (main_menu_scene).")
			return
		var err := get_tree().change_scene_to_file(main_menu_scene)
		if err != OK:
			push_error("HUD: не удалось загрузить сцену главного меню: " + main_menu_scene)
