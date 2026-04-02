extends Node

const DATA_ROOT_RES: String = "res://DATA/PulseRunnerData/"
const DATA_ROOT_USER: String = "user://DATA/PulseRunnerData/"
const TIMESTAMP_PATH_USER: String = "user://DATA/timestamp.txt"

const BASE_URL: String = "https://raw.githubusercontent.com/AYOMEGACUBE/PulseRunnerData/main/"

var paths_data: Dictionary = {}
var rules_data: Dictionary = {}
var balance_data: Dictionary = {}
var events_data: Dictionary = {}
var shop_data: Dictionary = {}
var localization_data: Dictionary = {}
var news_data: Dictionary = {}

signal load_completed

## True после загрузки локальных JSON (оффлайн). Сеть — отдельно, см. _deferred_network_refresh.
var is_data_ready: bool = false

func _ready() -> void:
	## [FIX] Локальные JSON сразу (совместимость с await load_completed); HTTP — не в этом кадре
	_load_all_local_jsons()
	is_data_ready = true
	load_completed.emit()
	if needs_update():
		call_deferred("_deferred_network_refresh")


func _deferred_network_refresh() -> void:
	await get_tree().process_frame
	await _update_all_remote()
	update_timestamp()
	_load_all_local_jsons()
	load_completed.emit()


func load_all_data() -> void:
	## Публичный перезагрузочный путь: только локальные файлы (без сети)
	_load_all_local_jsons()
	is_data_ready = true
	load_completed.emit()


func _load_all_local_jsons() -> void:
	paths_data = load_json(
		DATA_ROOT_RES + "paths/precomputed_paths.json",
		DATA_ROOT_USER + "paths/precomputed_paths.json"
	)
	rules_data = load_json(
		DATA_ROOT_RES + "rules/platform_rules.json",
		DATA_ROOT_USER + "rules/platform_rules.json"
	)
	balance_data = load_json(
		DATA_ROOT_RES + "balance/balance.json",
		DATA_ROOT_USER + "balance/balance.json"
	)
	events_data = load_json(
		DATA_ROOT_RES + "events/season_01.json",
		DATA_ROOT_USER + "events/season_01.json"
	)
	shop_data = load_json(
		DATA_ROOT_RES + "shop/items.json",
		DATA_ROOT_USER + "shop/items.json"
	)
	var en_loc := load_json(
		DATA_ROOT_RES + "localization/en.json",
		DATA_ROOT_USER + "localization/en.json"
	)
	var ru_loc := load_json(
		DATA_ROOT_RES + "localization/ru.json",
		DATA_ROOT_USER + "localization/ru.json"
	)
	localization_data = {
		"en": en_loc,
		"ru": ru_loc,
	}
	news_data = load_json(
		DATA_ROOT_RES + "news/today.json",
		DATA_ROOT_USER + "news/today.json"
	)

func load_json(path_res: String, path_user: String) -> Dictionary:
	var chosen_path: String = ""
	if FileAccess.file_exists(path_user):
		chosen_path = path_user
	elif FileAccess.file_exists(path_res):
		chosen_path = path_res
	else:
		return {}
	
	var file := FileAccess.open(chosen_path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	
	if text.strip_edges() == "":
		return {}
	
	var parsed = JSON.parse_string(text)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}

func needs_update() -> bool:
	# Если timestamp отсутствует — требуется обновление
	if not FileAccess.file_exists(TIMESTAMP_PATH_USER):
		return true
	var file := FileAccess.open(TIMESTAMP_PATH_USER, FileAccess.READ)
	if file == null:
		return true
	var stored: String = file.get_line().strip_edges()
	file.close()
	
	var today := Time.get_date_dict_from_system()
	var today_str := "%04d-%02d-%02d" % [today.year, today.month, today.day]
	return stored != today_str

func update_timestamp() -> void:
	_ensure_dir_for_file(TIMESTAMP_PATH_USER)
	var file := FileAccess.open(TIMESTAMP_PATH_USER, FileAccess.WRITE)
	if file == null:
		push_error("DataManager: cannot write timestamp to " + TIMESTAMP_PATH_USER)
		return
	var today := Time.get_date_dict_from_system()
	var today_str := "%04d-%02d-%02d" % [today.year, today.month, today.day]
	file.store_string(today_str + "\n")
	file.flush()
	file.close()

func _ensure_dir_for_file(path: String) -> void:
	var dir_path := path.get_base_dir()
	if dir_path == "":
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			push_error("DataManager: cannot create directory: " + dir_path)

func _update_all_remote() -> void:
	# Загружаем все JSON c GitHub в соответствующие user:// пути.
	var tasks := [
		{
			"url": BASE_URL + "paths/precomputed_paths.json",
			"path": DATA_ROOT_USER + "paths/precomputed_paths.json"
		},
		{
			"url": BASE_URL + "rules/platform_rules.json",
			"path": DATA_ROOT_USER + "rules/platform_rules.json"
		},
		{
			"url": BASE_URL + "balance/balance.json",
			"path": DATA_ROOT_USER + "balance/balance.json"
		},
		{
			"url": BASE_URL + "events/season_01.json",
			"path": DATA_ROOT_USER + "events/season_01.json"
		},
		{
			"url": BASE_URL + "shop/items.json",
			"path": DATA_ROOT_USER + "shop/items.json"
		},
		{
			"url": BASE_URL + "localization/en.json",
			"path": DATA_ROOT_USER + "localization/en.json"
		},
		{
			"url": BASE_URL + "localization/ru.json",
			"path": DATA_ROOT_USER + "localization/ru.json"
		},
		{
			"url": BASE_URL + "news/today.json",
			"path": DATA_ROOT_USER + "news/today.json"
		},
	]
	
	for task in tasks:
		var url: String = task.url
		var path: String = task.path
		await download_json(url, path)

func download_json(url: String, save_path: String) -> void:
	_ensure_dir_for_file(save_path)
	
	var http := HTTPRequest.new()
	add_child(http)
	
	var err := http.request(url)
	if err != OK:
		push_error("DataManager: HTTP request failed for " + url + " err=" + str(err))
		http.queue_free()
		return
	
	var result = await http.request_completed
	http.queue_free()
	
	if result.size() < 4:
		push_error("DataManager: invalid HTTP result for " + url)
		return
	
	var response_code: int = int(result[1])
	var body: PackedByteArray = result[3]
	
	if response_code != 200:
		push_error("DataManager: HTTP " + str(response_code) + " for " + url)
		return
	
	var text: String = body.get_string_from_utf8()
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("DataManager: cannot open file for write: " + save_path)
		return
	file.store_string(text)
	file.flush()
	file.close()
