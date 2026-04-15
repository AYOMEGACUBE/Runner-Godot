extends Control
# ============================================================================
# Champions.gd — отдельная сцена таблицы чемпионов
# ----------------------------------------------------------------------------
# Требования:
# - отдельный экран
# - корректная сортировка (GameState уже сортирует по score desc)
# - «Back to Menu» вверху слева → MainMenu
# ============================================================================

@export_file("*.tscn")
var main_menu_scene: String = "res://scenes/main_menu/MainMenu.tscn"

@onready var list_box: VBoxContainer = $CenterContainer/Panel/VBoxContainer/ScrollContainer/List
@onready var back_to_menu_button: Button = $BackToMenuButton
@onready var title_label: Label = $CenterContainer/Panel/VBoxContainer/TitleLabel

func _ready() -> void:
	if title_label:
		title_label.text = "Champions"

	if back_to_menu_button and not back_to_menu_button.pressed.is_connected(_on_back_to_menu_pressed):
		back_to_menu_button.pressed.connect(_on_back_to_menu_pressed)

	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_back_to_menu_pressed()


func _refresh() -> void:
	if list_box == null:
		return

	for c in list_box.get_children():
		c.queue_free()

	var champs: Array = GameState.get_champions()
	if champs.is_empty():
		var lbl := Label.new()
		lbl.text = "Пока пусто"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		list_box.add_child(lbl)
		return

	for i in range(champs.size()):
		var e = champs[i]
		var place := i + 1
		var n := "???"
		var s := 0
		if typeof(e) == TYPE_DICTIONARY:
			n = str(e.get("name", "???"))
			s = int(e.get("score", 0))

		var lbl2 := Label.new()
		lbl2.text = str(place) + ". " + n + " — " + str(s)
		lbl2.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		list_box.add_child(lbl2)

func _on_back_to_menu_pressed() -> void:
	var err := get_tree().change_scene_to_file(main_menu_scene)
	if err != OK:
		push_error("Champions.gd: не удалось вернуться в меню: " + main_menu_scene)
