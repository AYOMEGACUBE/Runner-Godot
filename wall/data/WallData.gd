extends Node
class_name WallData
# ============================================================================
# WallData.gd
# Хранилище данных стены (локально, без онлайна)
# ============================================================================
# - хранит сегменты
# - знает кто купил
# - позже легко подключается к JSON / серверу
# ============================================================================

# segment_id -> { owner: String }
var segments: Dictionary = {}

# ---------------------------------------------------------------------------

func has_segment(id: String) -> bool:
	return segments.has(id)

# ---------------------------------------------------------------------------

func get_segment(id: String) -> Dictionary:
	if not segments.has(id):
		segments[id] = {
			"owner": ""
		}
	return segments[id]

# ---------------------------------------------------------------------------

func buy_side(segment_id: String, buyer_uid: String) -> bool:
	var seg := get_segment(segment_id)

	# уже куплено
	if str(seg.get("owner", "")) != "":
		return false

	# покупаем
	seg["owner"] = buyer_uid
	segments[segment_id] = seg
	return true

# ---------------------------------------------------------------------------

func reset() -> void:
	segments.clear()
