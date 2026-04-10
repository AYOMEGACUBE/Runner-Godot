extends Control
# ============================================================================
# MainMenu.gd — ГЛАВНЫЙ ЭКРАН (без настроек аватара)

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/FileLogger")
	if logger != null and logger.has_method("write_log"):
		logger.call("write_log", message)
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

## Проверка связи с Firebase Realtime Database (см. `3301_PROJECT_STATE.md`). В релизе можно выключить.
@export var firebase_rtdb_ping_on_ready: bool = true
## Базовый URL без завершающего `/` (как в консоли Firebase).
@export var firebase_rtdb_base_url: String = "https://endlessrunnerayo-default-rtdb.europe-west1.firebasedatabase.app"
## После успешного GET записать тестовый узел `debug/godot_rtdb_ping` (нужны открытые Rules на запись).
@export var firebase_rtdb_write_test_ping: bool = true

var _http_rtdb: HTTPRequest = null
var _rtdb_put_after_get: bool = false

@onready var title_label: Label = $RootHBox/LeftPanel/TitleLabel
@onready var nickname_label: Label = $RootHBox/LeftPanel/NicknameLabel
@onready var coins_label: Label = $RootHBox/LeftPanel/CoinsLabel

@onready var auth_status_label: Label = $RootHBox/LeftPanel/AuthStatusLabel
@onready var google_signin_button: Button = $RootHBox/LeftPanel/VBoxButtons/GoogleSignInButton
@onready var sign_out_button: Button = $RootHBox/LeftPanel/VBoxButtons/SignOutButton

@onready var play_button: Button = $RootHBox/LeftPanel/VBoxButtons/PlayButton
@onready var champions_button: Button = $RootHBox/LeftPanel/VBoxButtons/ChampionsButton
@onready var profile_button: Button = $RootHBox/LeftPanel/VBoxButtons/ProfileButton
@onready var cubeview_button: Button = $RootHBox/LeftPanel/VBoxButtons/CubeViewButton

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
	if title_label == null:
		FileLogger.error("MainMenu: TitleLabel node missing")
	if coins_label == null:
		FileLogger.error("MainMenu: CoinsLabel node missing")
	if google_signin_button and not google_signin_button.pressed.is_connected(_on_google_signin_pressed):
		google_signin_button.pressed.connect(_on_google_signin_pressed)
	if sign_out_button and not sign_out_button.pressed.is_connected(_on_sign_out_pressed):
		sign_out_button.pressed.connect(_on_sign_out_pressed)

	if not AuthService.login_failed.is_connected(_on_auth_login_failed):
		AuthService.login_failed.connect(_on_auth_login_failed)
	if not AuthService.login_succeeded.is_connected(_on_auth_login_succeeded):
		AuthService.login_succeeded.connect(_on_auth_login_succeeded)
	if not AuthService.logout_done.is_connected(_on_auth_logout_done):
		AuthService.logout_done.connect(_on_auth_logout_done)

	if play_button and not play_button.pressed.is_connected(_on_play_pressed):
		play_button.pressed.connect(_on_play_pressed)

	if champions_button and not champions_button.pressed.is_connected(_on_champions_pressed):
		champions_button.pressed.connect(_on_champions_pressed)

	if profile_button and not profile_button.pressed.is_connected(_on_profile_pressed):
		profile_button.pressed.connect(_on_profile_pressed)

	if cubeview_button and not cubeview_button.pressed.is_connected(_on_cubeview_pressed):
		cubeview_button.pressed.connect(_on_cubeview_pressed)

	_refresh_ui()

	if firebase_rtdb_ping_on_ready:
		call_deferred("_firebase_rtdb_start_ping")

func _process(_delta: float) -> void:
	# лёгкий refresh (тут нет тяжёлых операций)
	_refresh_ui()

func _refresh_ui() -> void:
	if title_label:
		title_label.text = "Pulse Runner"

	var nick: String = GameState.get_nickname().strip_edges()
	if nickname_label:
		nickname_label.text = "Nickname: %s" % (nick if nick != "" else "— не задан —")

	var coins: int = GameState.get_coins()
	if coins_label:
		coins_label.text = "Coins: %d 🪙" % coins

	if auth_status_label:
		auth_status_label.text = AuthService.get_auth_status_line()
	if sign_out_button:
		sign_out_button.disabled = not AuthService.is_signed_in()

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


func _on_google_signin_pressed() -> void:
	_log("[MAINMENU] google sign-in pressed")
	AuthService.start_google_sign_in_ui(self)


func _on_sign_out_pressed() -> void:
	_log("[MAINMENU] sign out pressed")
	AuthService.sign_out()


func _on_auth_login_failed(msg: String) -> void:
	_log("[MAINMENU] auth failed: %s" % msg)
	_show_warn(str(msg))


func _on_auth_login_succeeded() -> void:
	_log("[MAINMENU] auth ok")


func _on_auth_logout_done() -> void:
	_log("[MAINMENU] auth logout")


func _firebase_rtdb_start_ping() -> void:
	var base: String = firebase_rtdb_base_url.strip_edges().trim_suffix("/")
	if base.is_empty():
		_log("[FIREBASE_RTDB] skip ping: empty firebase_rtdb_base_url")
		return
	if _http_rtdb != null:
		return
	_http_rtdb = HTTPRequest.new()
	add_child(_http_rtdb)
	_http_rtdb.request_completed.connect(_on_firebase_rtdb_request_completed)
	var get_url: String = base + "/.json"
	var err: int = _http_rtdb.request(get_url)
	if err != OK:
		_log("[FIREBASE_RTDB] GET schedule failed err=%d url=%s" % [err, get_url])
		_firebase_rtdb_cleanup_http()


func _on_firebase_rtdb_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _http_rtdb == null:
		return
	var body_text: String = body.get_string_from_utf8()
	if not _rtdb_put_after_get:
		if result != HTTPRequest.RESULT_SUCCESS:
			_log("[FIREBASE_RTDB] GET failed result=%d http=%d body=%s" % [result, response_code, body_text])
			_firebase_rtdb_cleanup_http()
			return
		if response_code < 200 or response_code >= 300:
			_log("[FIREBASE_RTDB] GET bad http=%d body=%s" % [response_code, body_text])
			_firebase_rtdb_cleanup_http()
			return
		var preview: String = body_text
		if preview.length() > 160:
			preview = preview.substr(0, 160) + "…"
		_log("[FIREBASE_RTDB] GET ok http=%d len=%d preview=%s" % [response_code, body.size(), preview])
		if not firebase_rtdb_write_test_ping:
			_firebase_rtdb_cleanup_http()
			return
		var base: String = firebase_rtdb_base_url.strip_edges().trim_suffix("/")
		var put_url: String = base + "/debug/godot_rtdb_ping.json"
		var payload_dict: Dictionary = {
			"t": Time.get_unix_time_from_system(),
			"v": 1,
			"godot": str(Engine.get_version_info())
		}
		var payload: String = JSON.stringify(payload_dict)
		var hdrs: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
		_rtdb_put_after_get = true
		var err2: int = _http_rtdb.request(put_url, hdrs, HTTPClient.METHOD_PUT, payload)
		if err2 != OK:
			_log("[FIREBASE_RTDB] PUT schedule failed err=%d" % err2)
			_rtdb_put_after_get = false
			_firebase_rtdb_cleanup_http()
		return

	_rtdb_put_after_get = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_log("[FIREBASE_RTDB] PUT failed result=%d http=%d body=%s" % [result, response_code, body_text])
	else:
		_log("[FIREBASE_RTDB] PUT ok http=%d (debug/godot_rtdb_ping)" % response_code)
	_firebase_rtdb_cleanup_http()


func _firebase_rtdb_cleanup_http() -> void:
	if _http_rtdb != null and is_instance_valid(_http_rtdb):
		if _http_rtdb.request_completed.is_connected(_on_firebase_rtdb_request_completed):
			_http_rtdb.request_completed.disconnect(_on_firebase_rtdb_request_completed)
		_http_rtdb.queue_free()
	_http_rtdb = null
