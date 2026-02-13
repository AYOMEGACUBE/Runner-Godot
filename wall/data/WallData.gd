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
		var price: int = BASE_PRICE_FREE if is_free else BASE_PRICE_PAID
		
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
	return int(seg.get("price", BASE_PRICE_PAID))

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
	
	return true

# ---------------------------------------------------------------------------

func get_face_data(segment_id: String, side: String) -> Dictionary:
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if faces.has(side):
		return faces[side].duplicate()
	return {}

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
	return true

# ---------------------------------------------------------------------------

func set_face_link(segment_id: String, side: String, link: String) -> bool:
	# Проверка живой ссылки (по ТЗ)
	if link.strip_edges() == "":
		return false
	
	# TODO: Проверка доступности ссылки (HTTP request)
	# Пока просто сохраняем
	
	var seg := get_segment(segment_id)
	var faces: Dictionary = seg.get("faces", {})
	if not faces.has(side):
		return false
	
	var face_data: Dictionary = faces[side]
	face_data["link"] = link.strip_edges()
	faces[side] = face_data
	seg["faces"] = faces
	segments[segment_id] = seg
	return true

# ---------------------------------------------------------------------------

func reset() -> void:
	segments.clear()
