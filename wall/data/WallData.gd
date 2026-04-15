extends Node
class_name WallData
# ============================================================================
# WallData.gd — Хранилище данных стены
# ============================================================================
# ASYNC LOADING:
#   load_from_file()  — мгновенно, НЕ БЛОКИРУЕТ. Запускает async pipeline.
#   load_state        — публичный enum для отслеживания прогресса.
#   signal load_completed(ok: bool)
#   update_async()    — вызывать из _process() родителя (или само через SceneTree).
# ============================================================================

# ─── ASYNC LOAD STATE MACHINE ────────────────────────────────────────────────
enum LoadState { IDLE, READING_FILE, PARSING_JSON, LOADING_SEGMENTS, MATERIALIZING, DONE, FAILED }

signal load_completed(ok: bool)

var load_state: LoadState = LoadState.IDLE
var load_progress: float  = 0.0   # 0.0 → 1.0
var _async_raw_text: String       = ""
var _async_all_seg_keys: Array    = []
var _async_seg_cursor: int        = 0
var _async_parsed_data: Dictionary = {}
var _async_materialize_keys: Array = []
var _async_mat_cursor: int        = 0
const SEGMENTS_PER_FRAME_LOAD: int   = 150
const MATERIALIZE_PER_FRAME: int     = 30
var _load_start_time_ms: int      = 0

# ─── SEGMENT DATA ─────────────────────────────────────────────────────────────
# segment_id -> {
#   "height": float,           # Высота сегмента (Y координата)
#   "price": int,              # Цена покупки (coin)
#   "faces": {                 # Данные для каждой из 6 сторон
#     "front": { "owner": "", "image_id": "", "image_path": "", "link": "" },
#     "back": { ... },
#     "left": { ... },
#     "right": { ... },
#     "top": { ... },
#     "bottom": { ... }
#   },
#   "first_owner": "",         # Первый владелец (для истории)
#   "purchase_date": int       # Unix timestamp покупки
# }
var segments: Dictionary = {}

# Базовые цены (можно вынести в GameState позже)
const BASE_PRICE_FREE: int = 10    # Цена для free-сегментов (нижняя часть)
const BASE_PRICE_PAID: int = 50    # Цена для paid-сегментов

# Путь для сохранения данных стены
const SAVE_PATH: String = "user://wall_segments.json"
const WALL_IMAGES_DIR: String = "user://wall_images"

# Флаг автоматического сохранения
var auto_save_enabled: bool = true
var _prepared_image_cache: Dictionary = {} # source_path -> prepared payload dict


func _ensure_wall_images_dir() -> void:
	if DirAccess.dir_exists_absolute(WALL_IMAGES_DIR):
		return
	var user_dir: DirAccess = DirAccess.open("user://")
	if user_dir != null:
		user_dir.make_dir("wall_images")


func _sha256_hex(bytes: PackedByteArray) -> String:
	var hc: HashingContext = HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(bytes)
	return hc.finish().hex_encode()


func _materialize_face_image_payload(face_data: Dictionary) -> Dictionary:
	var payload_b64: String = str(face_data.get("image_payload_b64", "")).strip_edges()
	if payload_b64 == "":
		return face_data
	var ext: String = str(face_data.get("image_ext", "png")).strip_edges().to_lower()
	if ext == "":
		ext = "png"
	var sha: String = str(face_data.get("image_sha256", "")).strip_edges().to_lower()
	var payload: PackedByteArray = Marshalls.base64_to_raw(payload_b64)
	if payload.is_empty():
		return face_data
	if sha == "":
		sha = _sha256_hex(payload)
		face_data["image_sha256"] = sha
	var local_path: String = "%s/%s.%s" % [WALL_IMAGES_DIR, sha, ext]
	if not FileAccess.file_exists(local_path):
		_ensure_wall_images_dir()
		var f: FileAccess = FileAccess.open(local_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(payload)
			f.close()
	face_data["image_path"] = local_path
	return face_data


func _prepare_image_for_face(source_path: String) -> Dictionary:
	var src_path: String = source_path.strip_edges()
	if src_path == "":
		return {}
	if _prepared_image_cache.has(src_path):
		return (_prepared_image_cache[src_path] as Dictionary).duplicate(true)
	var img: Image = Image.new()
	var load_err: Error = img.load(src_path)
	if load_err != OK or img.is_empty():
		return {}
	img.resize(48, 48, Image.INTERPOLATE_LANCZOS)
	var png_bytes: PackedByteArray = img.save_png_to_buffer()
	if png_bytes.is_empty():
		return {}
	var sha: String = _sha256_hex(png_bytes)
	var local_path: String = "%s/%s.png" % [WALL_IMAGES_DIR, sha]
	if not FileAccess.file_exists(local_path):
		_ensure_wall_images_dir()
		var f: FileAccess = FileAccess.open(local_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(png_bytes)
			f.close()
	var prepared: Dictionary = {
		"image_path": local_path,
		"image_payload_b64": Marshalls.raw_to_base64(png_bytes),
		"image_ext": "png",
		"image_sha256": sha,
	}
	_prepared_image_cache[src_path] = prepared.duplicate(true)
	return prepared

# ---------------------------------------------------------------------------

func _is_height_accessible(seg_height: float) -> bool:
	var gs: Node = _gs()
	if gs == null:
		return true
	var gate: float = float(gs.get("max_height_reached"))
	if gs.has_method("get_wall_height_gate"):
		gate = float(gs.call("get_wall_height_gate"))
	return seg_height >= gate


func _current_uid() -> String:
	var gs: Node = _gs()
	if gs == null:
		return ""
	return str(gs.get("player_uid")).strip_edges()

func _gs() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).root.get_node_or_null("/root/GameState")
	return null


func _log_store(message: String) -> void:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		var fl: Node = (ml as SceneTree).root.get_node_or_null("/root/FileLogger")
		if fl != null and fl.has_method("write_log"):
			fl.call("write_log", "[STORE] " + message)
			return
	print("[STORE] ", message)

func has_segment(id: String) -> bool:
	return segments.has(id)

# ---------------------------------------------------------------------------

func get_segment(id: String) -> Dictionary:
	if not segments.has(id):
		# Вычисляем высоту из segment_id (формат: "x_y")
		var coords: Array = id.split("_")
		var seg_y: float = 0.0
		if coords.size() >= 2:
			seg_y = float(coords[1]) * 48.0  # SEGMENT_SIZE = 48
		
		# Определяем тип сегмента (free или paid) по высоте
		var is_free: bool = seg_y >= 0  # Free-сегменты в нижней части (y >= 0)
		var base_price: int = BASE_PRICE_FREE if is_free else BASE_PRICE_PAID
		
		# Формула роста цены по высоте применяется в get_segment_price()
		# Здесь сохраняем базовую цену
		var price: int = base_price
		
		segments[id] = {
			"height": seg_y,
			"price": price,
			"group_id": "",
			"corporate_mode": false,
			"faces": {
				"front": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" },
				"back": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" },
				"left": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" },
				"right": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" },
				"top": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" },
				"bottom": { "owner": "", "image_id": "", "image_path": "", "image_payload_b64": "", "image_ext": "", "image_sha256": "", "link": "", "purchase_date": 0, "sync_status": "synced" }
			},
			"first_owner": "",
			"purchase_date": 0
		}
	return segments[id]

# ---------------------------------------------------------------------------

func get_segment_height(segment_id: String) -> float:
	var seg := get_segment(segment_id)
	return float(seg.get("height", 0.0))

# ---------------------------------------------------------------------------

func get_segment_price(segment_id: String) -> int:
	var seg := get_segment(segment_id)
	var base_price: int = int(seg.get("price", BASE_PRICE_PAID))
	
	# Формула роста цены по высоте: цена увеличивается каждые 1000 пикселей высоты
	var seg_height: float = float(seg.get("height", 0.0))
	var abs_height: float = abs(seg_height)
	
	# Каждые 1000 пикселей высоты добавляем 10% к базовой цене
	# Максимальный множитель: 3x (на высоте 20000+ пикселей)
	var height_multiplier: float = 1.0 + (abs_height / 1000.0) * 0.1
	height_multiplier = clamp(height_multiplier, 1.0, 3.0)
	
	return int(base_price * height_multiplier)

# ---------------------------------------------------------------------------

func buy_side(segment_id: String, side: String, buyer_uid: String, coin_cost: int) -> bool:
	# Проверка высоты (обязательно по ТЗ)
	var seg := get_segment(segment_id)
	var seg_height: float = float(seg.get("height", 0.0))
	
	# Проверяем max_height игрока (в Godot Y меньше = выше)
	if not _is_height_accessible(seg_height):
		return false  # Сегмент выше достигнутой высоты
	
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var face_data: Dictionary = faces[side]
	var buyer_uid_norm: String = buyer_uid.strip_edges()
	if buyer_uid_norm.is_empty():
		return false
	
	# Уже куплено другим владельцем -> отказ.
	# Текущему владельцу разрешаем повторную покупку (перепокупку) той же стороны.
	var owner_now: String = str(face_data.get("owner", "")).strip_edges()
	if owner_now != "" and owner_now != buyer_uid_norm:
		return false
	
	# Списываем с кошелька (не с очков забега)
	var gs: Node = _gs()
	if gs != null:
		if not bool(gs.call("spend_wallet_coins", coin_cost)):
			return false
	
	# Покупаем
	face_data["owner"] = buyer_uid_norm
	face_data["purchase_date"] = Time.get_unix_time_from_system()
	face_data["sync_status"] = "pending"
	
	# Сохраняем первого владельца
	if seg.get("first_owner", "") == "":
		seg["first_owner"] = buyer_uid_norm
		seg["purchase_date"] = Time.get_unix_time_from_system()
	
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	
	# Автоматическое сохранение после покупки
	if auto_save_enabled:
		save_to_file()
	
	return true

func buy_sides_atomic(
	segment_ids: Array,
	default_side: String,
	buyer_uid: String,
	request_ts: int = 0,
	tile_side_by_segment_id: Dictionary = {},
	segment_prices: Dictionary = {},
	spend_wallet: bool = true
) -> Dictionary:
	var result: Dictionary = {
		"success": false,
		"reason": "",
		"purchased_ids": [],
		"conflicts": [],
		"total_spent": 0,
	}
	var ids: Array[String] = []
	for raw_id in segment_ids:
		var sid: String = str(raw_id).strip_edges()
		if sid.is_empty() or sid in ids:
			continue
		ids.append(sid)
	if ids.is_empty():
		result["reason"] = "empty_selection"
		return result
	var buyer_uid_norm: String = buyer_uid.strip_edges()
	if buyer_uid_norm.is_empty():
		result["reason"] = "buyer_uid_empty"
		_log_store("buy_sides_atomic rejected: buyer_uid empty")
		return result

	var now_ts: int = request_ts if request_ts > 0 else int(Time.get_unix_time_from_system())
	var total_price: int = 0
	var conflicts: Array = []
	var planned: Array = []

	for sid2 in ids:
		var seg: Dictionary = get_segment(sid2)
		var side: String = str(tile_side_by_segment_id.get(sid2, default_side)).strip_edges()
		if side.is_empty():
			side = default_side
		var faces: Dictionary = seg.get("faces", {})
		if not faces.has(side):
			conflicts.append(sid2)
			continue
		var fd: Dictionary = faces[side]
		var owner_now2: String = str(fd.get("owner", "")).strip_edges()
		# Разрешаем перепокупку своей стороны, блокируем только чужую.
		if owner_now2 != "" and owner_now2 != buyer_uid_norm:
			conflicts.append(sid2)
			continue
		var seg_h: float = float(seg.get("height", 0.0))
		if not _is_height_accessible(seg_h):
			conflicts.append(sid2)
			continue
		var price: int = int(segment_prices.get(sid2, get_segment_price(sid2)))
		if price < 0:
			price = 0
		total_price += price
		planned.append({"segment_id": sid2, "side": side, "price": price})

	if not conflicts.is_empty():
		result["reason"] = "conflict"
		result["conflicts"] = conflicts
		return result

	if spend_wallet:
		var gs2: Node = _gs()
		if gs2 == null:
			result["reason"] = "gamestate_missing"
			return result
		if int(gs2.call("get_coins")) < total_price:
			result["reason"] = "insufficient_funds"
			return result
		if total_price > 0 and not bool(gs2.call("spend_wallet_coins", total_price)):
			result["reason"] = "insufficient_funds"
			return result

	var purchased_ids: Array[String] = []
	for step in planned:
		var sid3: String = str(step["segment_id"])
		var side3: String = str(step["side"])
		var seg3: Dictionary = get_segment(sid3)
		var faces3: Dictionary = seg3.get("faces", {})
		var fd3: Dictionary = faces3[side3]
		fd3["owner"] = buyer_uid_norm
		fd3["purchase_date"] = now_ts
		fd3["sync_status"] = "pending"
		faces3[side3] = fd3
		if str(seg3.get("first_owner", "")).strip_edges().is_empty():
			seg3["first_owner"] = buyer_uid_norm
			seg3["purchase_date"] = now_ts
		seg3["faces"] = faces3
		segments[sid3] = seg3
		purchased_ids.append(sid3)

	if auto_save_enabled:
		save_to_file()

	result["success"] = true
	result["reason"] = "ok"
	result["purchased_ids"] = purchased_ids
	result["total_spent"] = total_price
	_log_store(
		"Purchased: ids=%s owner=%s total=%d"
		% [str(purchased_ids), buyer_uid_norm, total_price]
	)
	return result

func set_segment_corporate_info(segment_id: String, group_id: String, corporate_mode: bool) -> bool:
	var seg := get_segment(segment_id)
	seg["group_id"] = group_id
	seg["corporate_mode"] = corporate_mode
	segments[segment_id] = seg
	if auto_save_enabled:
		save_to_file()
	return true

# ---------------------------------------------------------------------------

func get_face_data(segment_id: String, side: String) -> Dictionary:
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if faces.has(side):
		return faces[side].duplicate()
	return {}

# ---------------------------------------------------------------------------

func get_face_image_path(segment_id: String, side: String) -> String:
	"""
	Возвращает путь к изображению для указанного сегмента и стороны.
	Если изображение не задано, возвращает пустую строку.
	"""
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return ""
	var face_data: Dictionary = faces[side]
	var path_now: String = str(face_data.get("image_path", "")).strip_edges()
	if path_now != "" and (path_now.begins_with("res://") or path_now.begins_with("user://") or FileAccess.file_exists(path_now)):
		return path_now
	face_data = _materialize_face_image_payload(face_data)
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	return str(face_data.get("image_path", ""))

# ---------------------------------------------------------------------------

func set_face_image(segment_id: String, side: String, image_path: String) -> bool:
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var src_path: String = image_path.strip_edges()
	var face_data: Dictionary = faces[side]
	face_data["image_path"] = src_path
	if src_path != "":
		var prepared: Dictionary = _prepare_image_for_face(src_path)
		if not prepared.is_empty():
			face_data["image_path"] = str(prepared.get("image_path", src_path))
			face_data["image_payload_b64"] = str(prepared.get("image_payload_b64", ""))
			face_data["image_ext"] = str(prepared.get("image_ext", "png"))
			face_data["image_sha256"] = str(prepared.get("image_sha256", ""))
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	
	# Автоматическое сохранение
	if auto_save_enabled:
		save_to_file()
	var out_path: String = str(face_data.get("image_path", "")).strip_edges()
	print("[STORE] Purchased face image: segment=", segment_id, " side=", side, " path=", out_path)
	return true

# ---------------------------------------------------------------------------

func set_face_link(segment_id: String, side: String, link: String) -> bool:
	# Проверка живой ссылки (по ТЗ)
	if link.strip_edges() == "":
		return false
	
	# Валидация формата URL
	if not _validate_link_format(link):
		return false
	
	# TODO: Проверка доступности ссылки (HTTP request) - для будущего
	# Пока сохраняем только валидные по формату ссылки
	
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var face_data: Dictionary = faces[side]
	face_data["link"] = link.strip_edges()
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	
	# Автоматическое сохранение
	if auto_save_enabled:
		save_to_file()
	
	return true

func _validate_link_format(url: String) -> bool:
	"""
	Проверяет формат URL.
	Возвращает true если URL имеет правильный формат (http:// или https://).
	"""
	var trimmed_url = url.strip_edges()
	if trimmed_url.is_empty():
		return false
	
	# Проверяем наличие протокола
	if trimmed_url.begins_with("http://") or trimmed_url.begins_with("https://"):
		# Базовая проверка формата (есть хотя бы домен)
		var without_protocol = trimmed_url.substr(trimmed_url.find("://") + 3)
		if not without_protocol.is_empty() and without_protocol.find(" ") == -1:
			return true
	
	return false

# ---------------------------------------------------------------------------

func reset() -> void:
	segments.clear()


func to_dict() -> Dictionary:
	return {
		"version": 1,
		"saved_at": int(Time.get_unix_time_from_system()),
		"segments": segments.duplicate(true),
	}


func from_dict(data: Dictionary) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var raw_segments: Variant = data.get("segments", {})
	if typeof(raw_segments) != TYPE_DICTIONARY:
		return false
	segments = (raw_segments as Dictionary).duplicate(true)
	var changed: bool = false
	for seg_id_any in segments.keys():
		var seg_id: String = str(seg_id_any)
		var seg_v: Variant = segments[seg_id_any]
		if typeof(seg_v) != TYPE_DICTIONARY:
			continue
		var seg: Dictionary = seg_v as Dictionary
		var faces: Dictionary = seg.get("faces", {})
		var faces_changed: bool = false
		for side_any in faces.keys():
			var side: String = str(side_any)
			var fd_v: Variant = faces[side_any]
			if typeof(fd_v) != TYPE_DICTIONARY:
				continue
			var fd: Dictionary = fd_v as Dictionary
			var before_path: String = str(fd.get("image_path", "")).strip_edges()
			fd = _materialize_face_image_payload(fd)
			var after_path: String = str(fd.get("image_path", "")).strip_edges()
			if before_path != after_path:
				faces_changed = true
			faces[side] = fd
		if faces_changed:
			seg["faces"] = faces
			segments[seg_id] = seg
			changed = true
	if changed and auto_save_enabled:
		save_to_file()
	return true


func merge_from_dict(remote_data: Dictionary) -> Dictionary:
	var result: Dictionary = {"changed": false, "conflicts": []}
	if typeof(remote_data) != TYPE_DICTIONARY:
		return result
	var remote_segments: Variant = remote_data.get("segments", {})
	if typeof(remote_segments) != TYPE_DICTIONARY:
		return result
	var remote_seg_dict: Dictionary = remote_segments as Dictionary
	for seg_id_any in remote_seg_dict.keys():
		var sid: String = str(seg_id_any)
		var remote_seg_v: Variant = remote_seg_dict[seg_id_any]
		if typeof(remote_seg_v) != TYPE_DICTIONARY:
			continue
		var remote_seg: Dictionary = remote_seg_v as Dictionary
		var local_seg: Dictionary = get_segment(sid)
		var local_faces: Dictionary = local_seg.get("faces", {})
		var remote_faces: Dictionary = remote_seg.get("faces", {})
		var faces_changed: bool = false
		for side_any in remote_faces.keys():
			var side: String = str(side_any)
			if not local_faces.has(side):
				local_faces[side] = (remote_faces[side_any] as Dictionary).duplicate(true)
				faces_changed = true
				result["changed"] = true
				continue
			var lf: Dictionary = local_faces[side]
			var rf_v: Variant = remote_faces[side_any]
			if typeof(rf_v) != TYPE_DICTIONARY:
				continue
			var rf: Dictionary = rf_v as Dictionary
			var lo: String = str(lf.get("owner", "")).strip_edges()
			var ro: String = str(rf.get("owner", "")).strip_edges()
			var lt: int = int(lf.get("purchase_date", 0))
			var rt: int = int(rf.get("purchase_date", 0))
			if lo.is_empty() and not ro.is_empty():
				local_faces[side] = _materialize_face_image_payload(rf.duplicate(true))
				faces_changed = true
				result["changed"] = true
				continue
			if not lo.is_empty() and not ro.is_empty():
				if rt > 0 and (lt <= 0 or rt < lt):
					local_faces[side] = _materialize_face_image_payload(rf.duplicate(true))
					faces_changed = true
					result["changed"] = true
					result["conflicts"].append("%s:%s" % [sid, side])
				elif rt > lt:
					lf["sync_status"] = "conflict"
					local_faces[side] = lf
					faces_changed = true
					result["conflicts"].append("%s:%s" % [sid, side])
				elif rt == lt and rt > 0 and ro != lo:
					# Одинаковый timestamp, но разные владельцы: фиксируем конфликт без перезаписи.
					lf["sync_status"] = "conflict"
					local_faces[side] = lf
					faces_changed = true
					result["conflicts"].append("%s:%s" % [sid, side])
		if faces_changed:
			local_seg["faces"] = local_faces
			segments[sid] = local_seg
	if bool(result.get("changed", false)) and auto_save_enabled:
		save_to_file()
	return result


func set_sync_status_for_ids(segment_ids: Array, side: String, status: String, tile_side_by_segment_id: Dictionary = {}) -> void:
	for seg_raw in segment_ids:
		var sid: String = str(seg_raw).strip_edges()
		if sid.is_empty():
			continue
		var seg: Dictionary = get_segment(sid)
		var face_side: String = str(tile_side_by_segment_id.get(sid, side)).strip_edges()
		if face_side.is_empty():
			face_side = side
		var faces: Dictionary = seg.get("faces", {})
		if not faces.has(face_side):
			continue
		var fd: Dictionary = faces[face_side]
		fd["sync_status"] = status
		faces[face_side] = fd
		seg["faces"] = faces
		segments[sid] = seg
	if auto_save_enabled:
		save_to_file()

# ---------------------------------------------------------------------------
# СОХРАНЕНИЕ И ЗАГРУЗКА ДАННЫХ
# ---------------------------------------------------------------------------

func save_to_file() -> bool:
	"""
	Сохраняет данные сегментов в JSON файл.
	Возвращает true при успехе, false при ошибке.
	"""
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var error = FileAccess.get_open_error()
		push_error("WallData: не удалось открыть файл для записи: " + SAVE_PATH + " (код ошибки: " + str(error) + ")")
		return false
	
	# Создаём словарь для сохранения
	var save_data: Dictionary = {
		"version": 1,
		"segments": segments,
		"save_date": Time.get_unix_time_from_system()
	}
	
	# Конвертируем в JSON
	var json_string = JSON.stringify(save_data, "\t")
	file.store_string(json_string)
	file.close()
	var nseg: int = segments.size()
	print("[SAVE] Writing purchased items: ", SAVE_PATH, " segments=", nseg)
	var gs: Node = _gs()
	if gs != null and gs.has_method("notify_wall_segments_saved_to_disk"):
		gs.call("notify_wall_segments_saved_to_disk")
	return true

func load_from_file() -> bool:
	## НЕ БЛОКИРУЕТ main thread. Запускает асинхронный pipeline.
	## Слушай сигнал load_completed(ok) или проверяй load_state == DONE.
	if load_state == LoadState.LOADING_SEGMENTS or load_state == LoadState.MATERIALIZING or load_state == LoadState.READING_FILE or load_state == LoadState.PARSING_JSON:
		return true  # уже загружается

	if not FileAccess.file_exists(SAVE_PATH):
		load_state = LoadState.DONE
		emit_signal("load_completed", false)
		return false

	_load_start_time_ms = Time.get_ticks_msec()
	load_state = LoadState.READING_FILE
	load_progress = 0.0
	_async_raw_text = ""
	_async_parsed_data = {}
	_async_all_seg_keys = []
	_async_seg_cursor = 0
	_async_materialize_keys = []
	_async_mat_cursor = 0

	# Чтение файла — единственный sync вызов, но get_as_text быстрее parse на 13k сегментах.
	# Занимает ~2–5 ms (только I/O), не вызывает freeze.
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		load_state = LoadState.FAILED
		emit_signal("load_completed", false)
		return false
	_async_raw_text = file.get_as_text()
	file.close()
	load_state = LoadState.PARSING_JSON
	return true


func update_async() -> void:
	## Вызывать каждый кадр из родительского _process() пока load_state != DONE/FAILED.
	## Обрабатывает ровно один chunk за вызов — не блокирует кадр.
	match load_state:
		LoadState.PARSING_JSON:
			_async_step_parse()
		LoadState.LOADING_SEGMENTS:
			_async_step_load_segments()
		LoadState.MATERIALIZING:
			_async_step_materialize()
		_:
			pass


func _async_step_parse() -> void:
	var t0: int = Time.get_ticks_msec()
	var json: JSON = JSON.new()
	var err: Error = json.parse(_async_raw_text)
	_async_raw_text = ""  # освобождаем память
	var parse_ms: int = Time.get_ticks_msec() - t0
	if err != OK:
		push_error("WallData async: JSON parse error: " + json.get_error_message())
		load_state = LoadState.FAILED
		emit_signal("load_completed", false)
		return
	var data: Variant = json.data
	if not data is Dictionary:
		load_state = LoadState.FAILED
		emit_signal("load_completed", false)
		return
	_async_parsed_data = data as Dictionary
	if not _async_parsed_data.has("segments") or not (_async_parsed_data["segments"] is Dictionary):
		load_state = LoadState.FAILED
		emit_signal("load_completed", false)
		return
	_async_all_seg_keys = (_async_parsed_data["segments"] as Dictionary).keys()
	_async_seg_cursor = 0
	load_state = LoadState.LOADING_SEGMENTS
	print("[PERF] json_parse_ms=%d  segments_total=%d" % [parse_ms, _async_all_seg_keys.size()])


func _async_step_load_segments() -> void:
	var raw_segs: Dictionary = _async_parsed_data.get("segments", {}) as Dictionary
	var total: int  = _async_all_seg_keys.size()
	var end_idx: int = mini(_async_seg_cursor + SEGMENTS_PER_FRAME_LOAD, total)
	for i in range(_async_seg_cursor, end_idx):
		var key: String = str(_async_all_seg_keys[i])
		var val: Variant = raw_segs.get(key)
		if val is Dictionary:
			segments[key] = (val as Dictionary).duplicate(true)
	_async_seg_cursor = end_idx
	load_progress = float(_async_seg_cursor) / float(maxi(total, 1)) * 0.9
	if _async_seg_cursor >= total:
		# Переходим к материализации (Base64 → файл)
		_async_parsed_data = {}  # освобождаем
		_async_materialize_keys = segments.keys()
		_async_mat_cursor = 0
		load_state = LoadState.MATERIALIZING


func _async_step_materialize() -> void:
	var total: int   = _async_materialize_keys.size()
	var end_idx: int = mini(_async_mat_cursor + MATERIALIZE_PER_FRAME, total)
	var changed: bool = false
	for i in range(_async_mat_cursor, end_idx):
		var seg_id: String = str(_async_materialize_keys[i])
		var seg_v: Variant = segments.get(seg_id)
		if not (seg_v is Dictionary):
			continue
		var seg: Dictionary = seg_v as Dictionary
		var faces: Dictionary = seg.get("faces", {}) as Dictionary
		var fc: bool = false
		for side_any in faces.keys():
			var fd_v: Variant = faces[side_any]
			if not (fd_v is Dictionary):
				continue
			var fd: Dictionary = fd_v as Dictionary
			var before: String = str(fd.get("image_path", "")).strip_edges()
			fd = _materialize_face_image_payload(fd)
			if str(fd.get("image_path", "")) != before:
				faces[str(side_any)] = fd
				fc = true
		if fc:
			seg["faces"] = faces
			segments[seg_id] = seg
			changed = true
	_async_mat_cursor = end_idx
	load_progress = 0.9 + float(_async_mat_cursor) / float(maxi(total, 1)) * 0.1
	if _async_mat_cursor >= total:
		load_state = LoadState.DONE
		load_progress = 1.0
		var total_ms: int = Time.get_ticks_msec() - _load_start_time_ms
		print("[LOAD] Loaded items: ", SAVE_PATH, " segments=", segments.size(), " total_ms=", total_ms)
		if changed and auto_save_enabled:
			save_to_file()
		emit_signal("load_completed", true)


func _ready() -> void:
	# Запускаем async загрузку. update_async() вызывается из _process() ниже.
	load_from_file()


func _process(_delta: float) -> void:
	if load_state != LoadState.DONE and load_state != LoadState.FAILED and load_state != LoadState.IDLE:
		update_async()
