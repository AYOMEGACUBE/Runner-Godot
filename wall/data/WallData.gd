extends Node
class_name WallData
# ============================================================================
# WallData.gd
# Хранилище данных стены (локально, без онлайна)
# ============================================================================
# - хранит сегменты с полными данными (faces, images, links, prices, height)
# - знает кто купил каждую сторону
# - позже легко подключается к JSON / серверу
# ============================================================================

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

# Флаг автоматического сохранения
var auto_save_enabled: bool = true

# ---------------------------------------------------------------------------

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
			"faces": {
				"front": { "owner": "", "image_id": "", "image_path": "", "link": "" },
				"back": { "owner": "", "image_id": "", "image_path": "", "link": "" },
				"left": { "owner": "", "image_id": "", "image_path": "", "link": "" },
				"right": { "owner": "", "image_id": "", "image_path": "", "link": "" },
				"top": { "owner": "", "image_id": "", "image_path": "", "link": "" },
				"bottom": { "owner": "", "image_id": "", "image_path": "", "link": "" }
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
	if Engine.has_singleton("GameState"):
		var max_height: float = float(GameState.max_height_reached)
		# segment_height должен быть >= max_height (сегмент ниже или на уровне достигнутой высоты)
		if seg_height < max_height:
			return false  # Сегмент выше достигнутой высоты
	
	# Проверка достаточности монет
	if Engine.has_singleton("GameState"):
		if GameState.score < coin_cost:
			return false
	
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var face_data: Dictionary = faces[side]
	
	# Уже куплено
	if str(face_data.get("owner", "")) != "":
		return false
	
	# Списываем монеты
	if Engine.has_singleton("GameState"):
		GameState.score -= coin_cost
		GameState.save_scores()
	
	# Покупаем
	face_data["owner"] = buyer_uid
	face_data["purchase_date"] = Time.get_unix_time_from_system()
	
	# Сохраняем первого владельца
	if seg.get("first_owner", "") == "":
		seg["first_owner"] = buyer_uid
		seg["purchase_date"] = Time.get_unix_time_from_system()
	
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	
	# Автоматическое сохранение после покупки
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
	return str(face_data.get("image_path", ""))

# ---------------------------------------------------------------------------

func set_face_image(segment_id: String, side: String, image_path: String) -> bool:
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var face_data: Dictionary = faces[side]
	face_data["image_path"] = image_path
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	
	# Автоматическое сохранение
	if auto_save_enabled:
		save_to_file()
	
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
	
	return true

func load_from_file() -> bool:
	"""
	Загружает данные сегментов из JSON файла.
	Возвращает true при успехе, false если файл не найден или произошла ошибка.
	"""
	if not FileAccess.file_exists(SAVE_PATH):
		# Файл не существует - это нормально для первого запуска
		return false
	
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		var error = FileAccess.get_open_error()
		push_error("WallData: не удалось открыть файл для чтения: " + SAVE_PATH + " (код ошибки: " + str(error) + ")")
		return false
	
	# Читаем содержимое файла
	var json_string = file.get_as_text()
	file.close()
	
	# Парсим JSON
	var json = JSON.new()
	var parse_error = json.parse(json_string)
	if parse_error != OK:
		push_error("WallData: ошибка парсинга JSON: " + json.get_error_message())
		return false
	
	var save_data = json.data
	if not save_data is Dictionary:
		push_error("WallData: неверный формат данных в файле")
		return false
	
	# Загружаем сегменты
	if save_data.has("segments") and save_data["segments"] is Dictionary:
		segments = save_data["segments"].duplicate(true)  # deep copy
		return true
	else:
		push_error("WallData: в файле отсутствует поле 'segments'")
		return false

func _ready() -> void:
	# Загружаем данные при инициализации
	load_from_file()
