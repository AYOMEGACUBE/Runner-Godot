extends RefCounted
class_name ChunkRegistry
## Авто-сканирование JSON-чанков в res://DATA/PulseRunnerData/chunks/ (без мутации файлов на диске).

const DEFAULT_CHUNKS_DIR: String = "res://DATA/PulseRunnerData/chunks/"

@export var chunks_directory: String = DEFAULT_CHUNKS_DIR
## Если true — после reload вывести число моделей и список model_id (для отладки).
var debug_load: bool = false

## model_id -> шаблон словаря модели (platforms, support_chain_indices, …)
var _models_by_id: Dictionary = {}
var _model_ids: Array[int] = []


func reload() -> void:
	_models_by_id.clear()
	_model_ids.clear()
	var base: String = chunks_directory.strip_edges().trim_suffix("/")
	var da: DirAccess = DirAccess.open(base)
	if da == null:
		push_warning("ChunkRegistry: cannot open directory: %s" % base)
		return
	da.list_dir_begin()
	var fname: String = da.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = da.get_next()
			continue
		if not da.current_is_dir() and fname.get_extension().to_lower() == "json":
			_load_file(base.path_join(fname))
		fname = da.get_next()
	da.list_dir_end()
	for k in _models_by_id.keys():
		_model_ids.append(int(k))
	_model_ids.sort()
	if _models_by_id.is_empty():
		push_warning("ChunkRegistry: no models loaded from %s — check .json in folder" % base)
	elif debug_load:
		print("[ChunkRegistry] Loaded %d models: %s" % [_models_by_id.size(), str(_model_ids)])


func _load_file(res_path: String) -> void:
	if not FileAccess.file_exists(res_path):
		return
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if data == null:
		push_warning("ChunkRegistry: invalid JSON: %s" % res_path)
		return
	var models: Array = []
	if typeof(data) == TYPE_ARRAY:
		for el in data:
			if typeof(el) == TYPE_DICTIONARY:
				models.append(el)
	elif typeof(data) == TYPE_DICTIONARY:
		models.append(data)
	for raw: Variant in models:
		var d: Dictionary = raw as Dictionary
		if not d.has("platforms"):
			continue
		var plist: Variant = d["platforms"]
		if typeof(plist) != TYPE_ARRAY or (plist as Array).is_empty():
			continue
		var mid: int = int(d.get("model_id", -1))
		if mid < 0:
			continue
		_models_by_id[mid] = d.duplicate(true)


func size() -> int:
	return _models_by_id.size()


func has_model(model_id: int) -> bool:
	return _models_by_id.has(model_id)


func get_model_by_id(model_id: int) -> Dictionary:
	if not _models_by_id.has(model_id):
		return {}
	return (_models_by_id[model_id] as Dictionary).duplicate(true)


func get_sorted_model_ids() -> Array:
	## Копия отсортированных id (для колоды на колено); не мутирует реестр.
	return _model_ids.duplicate()


func get_random_chunk(rng: RandomNumberGenerator) -> Dictionary:
	if _model_ids.is_empty():
		push_error("ChunkRegistry: cache empty — cannot pick random chunk")
		return {}
	var n: int = _model_ids.size()
	## randi() может быть отрицательным; индекс всегда в [0, n).
	var idx: int = (rng.randi() % n + n) % n
	var idv: int = _model_ids[idx]
	return get_model_by_id(idv)
