extends Node
# ============================================================================
# GameState.gd — Autoload Singleton
# ----------------------------------------------------------------------------
# Хранит:
# - рекорды/таблицу чемпионов
# - выбранного героя
# - настройки кастом-аватара (jump0/jump1)
# - НИКНЕЙМ (persisted) — теперь игра не стартует без него
#
# Закладки под будущий мультиплеер:
# - player_uid (пока локально)
# - auth_provider / auth_token (пока пустые)
# ============================================================================

const SAVE_PATH: String = "user://blackout_run_scores.save"
const MAX_CHAMPIONS: int = 20

const DEFAULT_HERO_ID: String = "default"

# --- PERSISTED PROFILE ---
var nickname: String = ""              # <- ОБЯЗАТЕЛЕН для старта
var player_uid: String = ""            # <- заглушка (мультиплеер)
var auth_provider: String = ""         # <- заглушка (Google/Apple/etc)
var auth_token: String = ""            # <- заглушка

# --- HERO ---
var selected_hero_id: String = DEFAULT_HERO_ID

# --- CUSTOM AVATAR ---
var use_custom_avatar: bool = false
var custom_avatar_up_path: String = "user://avatars/custom_jump_up.png"
var custom_avatar_down_path: String = "user://avatars/custom_jump_down.png"

# --- WALL BREATHING (дыхание мира) ---
var wall_breathing_enabled: bool = true

# --- RUN STATE ---
var score: int = 0
var player_name: String = ""           # имя текущего забега (берём из nickname)
var is_game_over: bool = false         # флаг завершения текущего забега

# --- LAST RUN (для GameOver) ---
# Значения, зафиксированные в момент смерти (Player._die()).
# GameOver читает ТОЛЬКО эти поля — не score и не max_height_reached.
# ДЕФОЛТЫ ОБЯЗАТЕЛЬНЫ: даже без единого забега UI не должен быть пустым.
var last_run_score: int = 0
var last_run_max_height: float = 0.0
var has_finished_run: bool = false

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

# ---------------- PROFILE ----------------

func set_nickname(v: String) -> void:
	nickname = v.strip_edges()
	save_scores()

func get_nickname() -> String:
	return nickname

func has_valid_nickname() -> bool:
	return nickname.strip_edges() != ""

# ---------------- RUN ----------------

func start_new_run() -> void:
	# Имя забега всегда берём из persisted nickname
	score = 0
	player_name = nickname.strip_edges()
	is_game_over = false
	# Сбрасываем высоту; реальное начальное значение задаётся в Player._ready()
	max_height_reached = 0.0
	# last_run_* НЕ сбрасываем: GameOver показывает последний завершённый забег.
	# При первом запуске они уже 0. При следующей смерти Player._die() их перезапишет.

func add_coin(value: int = 1) -> void:
	score += value
	if score > best_score:
		best_score = score

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

# ---------------- CHAMPIONS ----------------

func register_run_finished() -> void:
	# Фиксируем данные последнего забега ДО добавления в таблицу чемпионов.
	# GameOver читает last_run_score и last_run_max_height — они уже должны быть записаны
	# в Player._die(), но на случай вызова register_run_finished откуда-то ещё — дублируем.
	last_run_score = score
	last_run_max_height = max_height_reached
	has_finished_run = true

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

	save_scores()

func get_champions() -> Array:
	return champions.duplicate()

func reset_scores() -> void:
	score = 0
	best_score = 0
	champions.clear()
	save_scores()

# ---------------- SAVE/LOAD ----------------

func save_scores() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("GameState: не удалось открыть файл для записи: " + SAVE_PATH)
		return

	var data := {
		# profile
		"nickname": nickname,
		"player_uid": player_uid,
		"auth_provider": auth_provider,
		"auth_token": auth_token,

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
		_reset_to_defaults()
		return

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("GameState: не удалось открыть файл для чтения: " + SAVE_PATH)
		_reset_to_defaults()
		return

	var data = file.get_var()
	if typeof(data) != TYPE_DICTIONARY:
		_reset_to_defaults()
		return

	# profile
	nickname = str(data.get("nickname", "")).strip_edges()
	player_uid = str(data.get("player_uid", "")).strip_edges()
	auth_provider = str(data.get("auth_provider", "")).strip_edges()
	auth_token = str(data.get("auth_token", "")).strip_edges()

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

	score = 0
	player_name = ""
	best_score = 0
	champions.clear()

	last_run_score = 0
	last_run_max_height = 0.0
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
