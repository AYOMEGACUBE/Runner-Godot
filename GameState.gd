extends Node
# ============================================================================
# GameState.gd — Autoload Singleton

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/FileLogger")
	if logger != null and logger.has_method("write_log"):
		logger.call("write_log", message)
	else:
		print(message)
# ----------------------------------------------------------------------------
# Хранит:
# - рекорды/таблицу чемпионов
# - выбранного героя
# - настройки кастом-аватара (jump0/jump1)
# - НИКНЕЙМ (persisted) — теперь игра не стартует без него
#
# Firebase / облако:
# - player_uid — Firebase Auth localId
# - auth_token — Firebase idToken (обновляется через firebase_refresh_token в AuthService)
# ============================================================================

const SAVE_PATH: String = "user://blackout_run_scores.save"
const MAX_CHAMPIONS: int = 20

const DEFAULT_HERO_ID: String = "default"

# --- PERSISTED PROFILE ---
var nickname: String = ""              # <- ОБЯЗАТЕЛЕН для старта
var player_uid: String = ""            # Firebase uid
var auth_provider: String = ""         # например "google"
var auth_token: String = ""            # Firebase idToken (не путать с монетным score)
var firebase_refresh_token: String = ""
var auth_email: String = ""
## Имя из Google / Firebase (displayName), для UI; не путать с игровым nickname.
var auth_display_name: String = ""
var firebase_token_saved_at_unix: int = 0

## Постоянный кошелёк (покупки сегментов, главное меню). Не сбрасывается между забегами.
var wallet_coins: int = 0
## Unix-время последней принятой с сервера или успешно отправленной версии кошелька (RTDB merge).
var wallet_remote_mtime: int = 0

# --- HERO ---
var selected_hero_id: String = DEFAULT_HERO_ID

# --- CUSTOM AVATAR ---
var use_custom_avatar: bool = false
var custom_avatar_up_path: String = "user://avatars/custom_jump_up.png"
var custom_avatar_down_path: String = "user://avatars/custom_jump_down.png"

# --- WALL BREATHING (дыхание мира) ---
var wall_breathing_enabled: bool = true

# --- WALL SIDES PROGRESSION (открытие сторон мегакуба) ---
# Порядок сторон фиксируем по ТЗ
const WALL_SIDES: Array[String] = ["front", "back", "left", "right", "top", "bottom"]
# Открытые стороны (по умолчанию только front)
var unlocked_sides: Array[String] = ["front"]
# Текущая активная сторона для CubeView
var active_wall_side: String = "front"

# --- WALL SEGMENTS (user://wall_segments.json) ---
## Эмитится после успешной записи на диск — все инстансы стены перечитывают файл (оффлайн-покупка без RTDB push).
signal wall_segments_disk_updated
var _wall_disk_emit_queued: bool = false

func notify_wall_segments_saved_to_disk() -> void:
	if _wall_disk_emit_queued:
		return
	_wall_disk_emit_queued = true
	call_deferred("_flush_wall_segments_disk_notification")

func _flush_wall_segments_disk_notification() -> void:
	_wall_disk_emit_queued = false
	wall_segments_disk_updated.emit()

# --- DEBUG / DEV ---
var disable_wall: bool = false

# --- RUN STATE ---
var score: int = 0
## X игрока в момент старта забега (якорь наклона пути / горизонтальный прогресс).
var run_start_player_x: float = 0.0
## Y игрока в момент старта забега (для altitude-очков и crumble-прогресса).
var run_start_player_y: float = 0.0
## Монеты, собранные за текущий забег (score = altitude_points + run_coin_bonus).
var run_coin_bonus: int = 0
var player_name: String = ""           # имя текущего забега (берём из nickname)
var is_game_over: bool = false         # флаг завершения текущего забега

# --- LAST RUN (для GameOver) ---
# Значения, зафиксированные в момент смерти (Player._die()).
# GameOver читает ТОЛЬКО эти поля — не score и не max_height_reached.
# ДЕФОЛТЫ ОБЯЗАТЕЛЬНЫ: даже без единого забега UI не должен быть пустым.
var last_run_score: int = 0
var last_run_max_height: float = 0.0
var last_run_coin_bonus: int = 0
var has_finished_run: bool = false

## Один раз за забег: монеты из run_coin_bonus перенесены в wallet_coins.
var run_wallet_applied: bool = false

# Максимальная достигнутая высота игрока в world-space (ось Y Godot).
# Принято соглашение:
# - чем МЕНЬШЕ значение Y, тем ВЫШЕ находится игрок (стандартная 2D-координата).
# - max_height_reached хранит МИНИМАЛЬНОЕ значение global_position.y,
#   которого достиг игрок в текущем забеге.
# Это значение используется в CubeView как позиция высотного гейта.
var max_height_reached: float = 0.0

# --- RECORDS ---
var best_score: int = 0
var champions: Array = [] # { "name": String, "score": int, "time": int }

func _ready() -> void:
	load_scores()
	_apply_temp_pre_release_wallet_boost()


func _apply_temp_pre_release_wallet_boost() -> void:
	# Temporary pre-release helper for manual purchase QA only.
	# Disabled automatically in headless runs to keep tests deterministic.
	if DisplayServer.get_name() == "headless":
		return
	var enabled: bool = bool(ProjectSettings.get_setting("3301_temp_pre_release/wallet_boost_enabled", false))
	if not enabled:
		return
	var amount: int = int(ProjectSettings.get_setting("3301_temp_pre_release/wallet_boost_amount", 1000000))
	if amount <= 0:
		return
	if wallet_coins < amount:
		wallet_coins = amount
		_log("[GAMESTATE] TEMP pre-release wallet boost applied: wallet=%d" % wallet_coins)
		save_scores()

# ---------------- PROFILE ----------------

func set_nickname(v: String) -> void:
	nickname = v.strip_edges()
	save_scores()

func get_nickname() -> String:
	return nickname

func has_valid_nickname() -> bool:
	return nickname.strip_edges() != ""

## Баланс кошелька (главное меню, покупки). Не равен очкам забега (`score`).
func get_coins() -> int:
	return wallet_coins


## Имя в HUD за забег: Google display name, иначе никнейм забега.
func get_hud_display_name() -> String:
	var g: String = auth_display_name.strip_edges()
	if g != "":
		return g
	var n: String = player_name.strip_edges()
	if n != "":
		return n
	return "NoName"


## Перенос собранных за забег монет в кошелёк (один раз до следующего start_new_run).
func apply_run_coins_to_wallet_once() -> void:
	if run_wallet_applied:
		return
	run_wallet_applied = true
	if run_coin_bonus <= 0:
		return
	wallet_coins += run_coin_bonus
	_log("[GAMESTATE] wallet +%d run coins -> total wallet=%d" % [run_coin_bonus, wallet_coins])
	save_scores()
	_request_economy_cloud_push()


func spend_wallet_coins(amount: int) -> bool:
	if amount <= 0:
		return true
	if wallet_coins < amount:
		return false
	wallet_coins -= amount
	save_scores()
	_request_economy_cloud_push()
	return true


func _request_economy_cloud_push() -> void:
	var root: Window = get_tree().root if get_tree() != null else null
	if root == null:
		return
	var sync: Node = root.get_node_or_null("/root/EconomyRemoteSync")
	if sync != null and sync.has_method("request_push_wallet"):
		sync.call("request_push_wallet")

# ---------------- RUN ----------------

func start_new_run() -> void:
	# Имя забега всегда берём из persisted nickname
	score = 0
	run_coin_bonus = 0
	run_wallet_applied = false
	run_start_player_x = 0.0
	run_start_player_y = 0.0
	player_name = nickname.strip_edges()
	is_game_over = false
	# Сбрасываем высоту; реальное начальное значение задаётся в Player._ready()
	max_height_reached = 0.0
	_log("[GAMESTATE] start_new_run player_name=%s" % player_name)
	# last_run_* НЕ сбрасываем: GameOver показывает последний завершённый забег.
	# При первом запуске они уже 0. При следующей смерти Player._die() их перезапишет.


func get_wall_height_gate() -> float:
	## Один порог Y для CubeView (красная линия), WallRenderer.handle_click и WallData.buy_side.
	## Сегмент можно купить, если seg_height >= порога (меньший Y = выше на экране).
	## После start_new_run() max_height_reached = 0, иначе вся верхняя половина сетки (seg_height < 0)
	## ошибочно блокируется; тогда берём last_run_max_height последнего завершённого забега.
	var m: float = max_height_reached
	var l: float = last_run_max_height
	if absf(m) < 0.0001 and absf(l) < 0.0001:
		return -200.0
	if absf(m) < 0.0001 and absf(l) >= 0.0001:
		return l
	if absf(m) >= 0.0001:
		return m
	return l


func get_altitude_points() -> int:
	return int(absf(run_start_player_y - max_height_reached) * 0.1)


func recompute_run_score() -> void:
	if is_game_over:
		return
	var alt_pts: int = get_altitude_points()
	score = alt_pts + run_coin_bonus
	if score > best_score:
		best_score = score


func add_coin(value: int = 1) -> void:
	var old_score: int = score
	run_coin_bonus += value
	recompute_run_score()
	if score > best_score:
		_log("[GAMESTATE] add_coin value=%d score=%d->%d NEW_BEST=%d" % [value, old_score, score, best_score])
	else:
		_log("[GAMESTATE] add_coin value=%d score=%d->%d best=%d" % [value, old_score, score, best_score])
	save_scores()

# ---------------- HERO ----------------

func set_selected_hero_id(id: String) -> void:
	var clean_id := id.strip_edges()
	if clean_id == "":
		clean_id = DEFAULT_HERO_ID
	selected_hero_id = clean_id
	save_scores()

func get_selected_hero_id() -> String:
	return selected_hero_id

# ---------------- CUSTOM AVATAR ----------------

func set_use_custom_avatar(v: bool) -> void:
	use_custom_avatar = v
	save_scores()

func get_use_custom_avatar() -> bool:
	return use_custom_avatar

func set_custom_avatar_paths(up_path: String, down_path: String) -> void:
	if up_path.strip_edges() != "":
		custom_avatar_up_path = up_path.strip_edges()
	if down_path.strip_edges() != "":
		custom_avatar_down_path = down_path.strip_edges()
	save_scores()

func get_custom_avatar_up_path() -> String:
	return custom_avatar_up_path

func get_custom_avatar_down_path() -> String:
	return custom_avatar_down_path

# ---------------- WALL BREATHING ----------------

func set_wall_breathing_enabled(v: bool) -> void:
	wall_breathing_enabled = v
	save_scores()

func get_wall_breathing_enabled() -> bool:
	return wall_breathing_enabled

# --- WALL SIDES (API) ---

func get_active_wall_side() -> String:
	if active_wall_side in WALL_SIDES:
		return active_wall_side
	return "front"

func set_active_wall_side(side: String) -> void:
	if not (side in WALL_SIDES):
		return
	active_wall_side = side
	if not (side in unlocked_sides):
		unlocked_sides.append(side)
	save_scores()

func get_unlocked_wall_sides() -> Array[String]:
	return unlocked_sides.duplicate()

func unlock_next_wall_side() -> void:
	# Находит следующую сторону в WALL_SIDES и добавляет её в unlocked_sides 
	var current := get_active_wall_side()
	var idx := WALL_SIDES.find(current)
	if idx == -1:
		idx = 0
	var next_idx := idx + 1
	if next_idx >= WALL_SIDES.size():
		return
	var next_side: String = WALL_SIDES[next_idx]
	if not (next_side in unlocked_sides):
		unlocked_sides.append(next_side)
	active_wall_side = next_side
	save_scores()

# ---------------- CHAMPIONS ----------------

func register_run_finished() -> void:
	apply_run_coins_to_wallet_once()
	# Фиксируем данные последнего забега ДО добавления в таблицу чемпионов.
	# GameOver читает last_run_* — при вызове не из Player._die() дублируем здесь.
	last_run_score = score
	last_run_max_height = max_height_reached
	last_run_coin_bonus = run_coin_bonus
	has_finished_run = true
	_log("[GAMESTATE] register_run_finished score=%d height=%.1f coins_run=%d wallet=%d" % [score, max_height_reached, last_run_coin_bonus, wallet_coins])

	var player_n := player_name.strip_edges()
	if player_n == "":
		player_n = "NoName"

	var entry := {
		"name": player_n,
		"score": score,
		"time": _get_now()
	}

	champions.append(entry)
	champions.sort_custom(Callable(self, "_sort_scores_desc"))

	if champions.size() > MAX_CHAMPIONS:
		champions.resize(MAX_CHAMPIONS)

	_log("[GAMESTATE] added to champions: name=%s score=%d total_champions=%d" % [player_n, score, champions.size()])
	save_scores()

func get_champions() -> Array:
	return champions.duplicate()

func reset_scores() -> void:
	score = 0
	wallet_coins = 0
	wallet_remote_mtime = 0
	best_score = 0
	champions.clear()
	save_scores()

# ---------------- SAVE/LOAD ----------------

func save_scores() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("GameState: не удалось открыть файл для записи: " + SAVE_PATH)
		_log("[GAMESTATE] save_scores FAILED")
		return
	_log("[GAMESTATE] save_scores SUCCESS")

	var data := {
		# profile
		"nickname": nickname,
		"player_uid": player_uid,
		"auth_provider": auth_provider,
		"auth_token": auth_token,
		"firebase_refresh_token": firebase_refresh_token,
		"auth_email": auth_email,
		"auth_display_name": auth_display_name,
		"firebase_token_saved_at_unix": firebase_token_saved_at_unix,
		"wallet_coins": wallet_coins,
		"wallet_remote_mtime": wallet_remote_mtime,

		# records
		"best_score": best_score,
		"champions": champions,

		# hero
		"selected_hero_id": selected_hero_id,

		# custom avatar
		"use_custom_avatar": use_custom_avatar,
		"custom_avatar_up_path": custom_avatar_up_path,
		"custom_avatar_down_path": custom_avatar_down_path,

		# wall breathing
		"wall_breathing_enabled": wall_breathing_enabled
	}

	file.store_var(data)

func load_scores() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		_log("[GAMESTATE] load_scores - file not found, using defaults")
		_reset_to_defaults()
		return

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("GameState: не удалось открыть файл для чтения: " + SAVE_PATH)
		_log("[GAMESTATE] load_scores FAILED, using defaults")
		_reset_to_defaults()
		return
	_log("[GAMESTATE] load_scores SUCCESS")

	var data = file.get_var()
	if typeof(data) != TYPE_DICTIONARY:
		_reset_to_defaults()
		return

	# profile
	nickname = str(data.get("nickname", "")).strip_edges()
	player_uid = str(data.get("player_uid", "")).strip_edges()
	auth_provider = str(data.get("auth_provider", "")).strip_edges()
	auth_token = str(data.get("auth_token", "")).strip_edges()
	firebase_refresh_token = str(data.get("firebase_refresh_token", "")).strip_edges()
	auth_email = str(data.get("auth_email", "")).strip_edges()
	auth_display_name = str(data.get("auth_display_name", "")).strip_edges()
	firebase_token_saved_at_unix = int(data.get("firebase_token_saved_at_unix", 0))
	wallet_coins = int(data.get("wallet_coins", 0))
	wallet_remote_mtime = int(data.get("wallet_remote_mtime", 0))

	# records
	best_score = int(data.get("best_score", 0))

	var loaded_champs = data.get("champions", [])
	champions.clear()
	if typeof(loaded_champs) == TYPE_ARRAY:
		for e in loaded_champs:
			if typeof(e) == TYPE_DICTIONARY:
				champions.append(e)
	champions.sort_custom(Callable(self, "_sort_scores_desc"))
	if champions.size() > MAX_CHAMPIONS:
		champions.resize(MAX_CHAMPIONS)

	# hero
	selected_hero_id = str(data.get("selected_hero_id", DEFAULT_HERO_ID)).strip_edges()
	if selected_hero_id == "":
		selected_hero_id = DEFAULT_HERO_ID

	# custom avatar
	use_custom_avatar = bool(data.get("use_custom_avatar", false))
	custom_avatar_up_path = str(data.get("custom_avatar_up_path", "user://avatars/custom_jump_up.png")).strip_edges()
	custom_avatar_down_path = str(data.get("custom_avatar_down_path", "user://avatars/custom_jump_down.png")).strip_edges()

	if custom_avatar_up_path == "":
		custom_avatar_up_path = "user://avatars/custom_jump_up.png"
	if custom_avatar_down_path == "":
		custom_avatar_down_path = "user://avatars/custom_jump_down.png"

	# wall breathing
	wall_breathing_enabled = bool(data.get("wall_breathing_enabled", true))

func _reset_to_defaults() -> void:
	nickname = ""
	player_uid = ""
	auth_provider = ""
	auth_token = ""
	firebase_refresh_token = ""
	auth_email = ""
	auth_display_name = ""
	firebase_token_saved_at_unix = 0
	wallet_coins = 0
	wallet_remote_mtime = 0

	score = 0
	run_coin_bonus = 0
	run_wallet_applied = false
	run_start_player_x = 0.0
	run_start_player_y = 0.0
	player_name = ""
	best_score = 0
	champions.clear()

	last_run_score = 0
	last_run_max_height = 0.0
	last_run_coin_bonus = 0
	has_finished_run = false

	selected_hero_id = DEFAULT_HERO_ID

	use_custom_avatar = false
	custom_avatar_up_path = "user://avatars/custom_jump_up.png"
	custom_avatar_down_path = "user://avatars/custom_jump_down.png"

	wall_breathing_enabled = true

func _sort_scores_desc(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = int(a.get("score", 0))
	var sb: int = int(b.get("score", 0))
	if sa == sb:
		var ta: int = int(a.get("time", 0))
		var tb: int = int(b.get("time", 0))
		return ta > tb
	return sa > sb

func _get_now() -> int:
	return Time.get_unix_time_from_system()
