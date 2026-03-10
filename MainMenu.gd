extends Control
# ============================================================================
# MainMenu.gd — ГЛАВНЫЙ ЭКРАН (без настроек аватара)

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/Logger")
	if logger != null and logger.has_method("log"):
		logger.call("log", message)
	else:
		print(message)
# ----------------------------------------------------------------------------
# Требования:
# - Play НЕ работает без nickname
# - Champions -> отдельная сцена
# - Profile -> отдельная сцена (там nickname + avatar + jump(0/1))
# - На главном экране показываем текущий аватар (по выбору игрока)
# ============================================================================

@export_file("*.tscn")
var game_scene: String = "res://level.tscn"

@export_file("*.tscn")
var champions_scene: String = "res://Champions.tscn"

@export_file("*.tscn")
var profile_scene: String = "res://Profile.tscn"

@export_file("*.tscn")
var cube_view_scene: String = "res://CubeView.tscn"

@onready var play_button: Button = $RootHBox/LeftPanel/VBoxButtons/PlayButton
@onready var champions_button: Button = $RootHBox/LeftPanel/VBoxButtons/ChampionsButton
@onready var profile_button: Button = $RootHBox/LeftPanel/VBoxButtons/ProfileButton
@onready var cubeview_button: Button = $RootHBox/LeftPanel/VBoxButtons/CubeViewButton

@onready var nickname_label: Label = $RootHBox/LeftPanel/NicknameLabel
@onready var avatar_preview: TextureRect = $RootHBox/RightPanel/AvatarPreview

@onready var warn_dialog: AcceptDialog = $WarnDialog

const HERO_PREVIEWS := {
	"default": "res://heroes/hero_default.png",
	"monster": "res://heroes/hero_monster.png",
	"red": "res://heroes/hero_red.png",
	"blue": "res://heroes/hero_blue.png",
	"orange": "res://heroes/hero_orange.png"
}

func _ready() -> void:
	_log("[MAINMENU] _ready")
	if play_button and not play_button.pressed.is_connected(_on_play_pressed):
		play_button.pressed.connect(_on_play_pressed)

	if champions_button and not champions_button.pressed.is_connected(_on_champions_pressed):
		champions_button.pressed.connect(_on_champions_pressed)

	if profile_button and not profile_button.pressed.is_connected(_on_profile_pressed):
		profile_button.pressed.connect(_on_profile_pressed)

	if cubeview_button and not cubeview_button.pressed.is_connected(_on_cubeview_pressed):
		cubeview_button.pressed.connect(_on_cubeview_pressed)

	_refresh_ui()

func _process(_delta: float) -> void:
	# лёгкий refresh (тут нет тяжёлых операций)
	_refresh_ui()

func _refresh_ui() -> void:
	var nick := GameState.get_nickname().strip_edges()
	if nickname_label:
		nickname_label.text = "Nickname: " + (nick if nick != "" else "— не задан —")

	# Показываем превью аватара:
	# - если кастом включён и есть файл jump0 -> показываем его
	# - иначе показываем preview выбранного героя
	if avatar_preview == null:
		return

	if GameState.get_use_custom_avatar():
		var up_path := GameState.get_custom_avatar_up_path()
		if FileAccess.file_exists(up_path):
			var img := Image.new()
			var err := img.load(up_path)
			if err == OK:
				var tex := ImageTexture.create_from_image(img)
				avatar_preview.texture = tex
				return

	var hero_id := str(GameState.get_selected_hero_id()).strip_edges()
	if hero_id == "":
		hero_id = "default"
	var p := str(HERO_PREVIEWS.get(hero_id, HERO_PREVIEWS["default"]))
	if p != "" and ResourceLoader.exists(p):
		var res := ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE)
		if res is Texture2D:
			avatar_preview.texture = res

func _on_profile_pressed() -> void:
	_log("[MAINMENU] profile pressed, scene=%s" % profile_scene)
	var err := get_tree().change_scene_to_file(profile_scene)
	if err != OK:
		push_error("MainMenu.gd: не удалось открыть Profile: " + profile_scene)
		_log("[MAINMENU] ERROR - scene change failed: %s" % profile_scene)

func _on_champions_pressed() -> void:
	_log("[MAINMENU] champions pressed, scene=%s" % champions_scene)
	var err := get_tree().change_scene_to_file(champions_scene)
	if err != OK:
		push_error("MainMenu.gd: не удалось открыть Champions: " + champions_scene)
		_log("[MAINMENU] ERROR - scene change failed: %s" % champions_scene)


func _on_cubeview_pressed() -> void:
	# ----------------------------------------------------------------------------
	# ПЕРЕХОД В СЦЕНУ ПРОСМОТРА СТЕНЫ (CubeView)
	# ----------------------------------------------------------------------------
	# Эта кнопка позволяет игроку открыть сцену CubeView,
	# где он может рассматривать мегакуб и взаимодействовать с сегментами
	# в спокойном режиме, вне игрового раннера.
	# Здесь мы просто меняем сцену на CubeView.tscn.
	# ВАЖНО: логика стены и сегментов внутри CubeView остаётся той же,
	# что и в Level — мы лишь меняем окружение.
	# ----------------------------------------------------------------------------
	_log("[MAINMENU] cubeview pressed, scene=%s" % cube_view_scene)
	var err := get_tree().change_scene_to_file(cube_view_scene)
	if err != OK:
		push_error("MainMenu.gd: не удалось открыть CubeView: " + cube_view_scene)
		_log("[MAINMENU] ERROR - scene change failed: %s" % cube_view_scene)

func _on_play_pressed() -> void:
	# Запрет старта без nickname
	if not GameState.has_valid_nickname():
		_log("[MAINMENU] play pressed - NO NICKNAME")
		_show_warn("Сначала нужно указать никнейм (Profile).")
		return

	# старт забега
	_log("[MAINMENU] play pressed, starting new run")
	GameState.start_new_run()

	var err := get_tree().change_scene_to_file(game_scene)
	if err != OK:
		push_error("MainMenu.gd: не удалось загрузить сцену игры: " + game_scene)
		_log("[MAINMENU] ERROR - scene change failed: %s" % game_scene)

func _show_warn(text: String) -> void:
	if warn_dialog:
		warn_dialog.dialog_text = text
		warn_dialog.popup_centered()
