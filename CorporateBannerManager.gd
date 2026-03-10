extends Node
class_name CorporateBannerManager

# Простая локальная очередь корпоративных баннеров.
# Серверная синхронизация может быть добавлена позже.

signal active_group_changed(group_id: String)

@export var rotation_interval_seconds: float = 20.0

var _groups_queue: Array[Dictionary] = []
var _active_index: int = -1
var _timer: Timer = null

func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = max(rotation_interval_seconds, 1.0)
	add_child(_timer)
	_timer.timeout.connect(_rotate_next)
	_timer.start()

func register_group(group_id: String, segment_ids: Array, side_id: String) -> void:
	if group_id.strip_edges() == "":
		return
	for item in _groups_queue:
		if str(item.get("group_id", "")) == group_id:
			return
	_groups_queue.append({
		"group_id": group_id,
		"segment_ids": segment_ids.duplicate(),
		"side_id": side_id
	})
	if _active_index == -1:
		_active_index = 0
		active_group_changed.emit(group_id)

func unregister_group(group_id: String) -> void:
	for i in range(_groups_queue.size()):
		if str(_groups_queue[i].get("group_id", "")) == group_id:
			_groups_queue.remove_at(i)
			if _groups_queue.is_empty():
				_active_index = -1
				active_group_changed.emit("")
			else:
				_active_index = clamp(_active_index, 0, _groups_queue.size() - 1)
				active_group_changed.emit(get_active_group_id())
			return

func get_active_group_id() -> String:
	if _active_index < 0 or _active_index >= _groups_queue.size():
		return ""
	return str(_groups_queue[_active_index].get("group_id", ""))

func get_active_group_data() -> Dictionary:
	if _active_index < 0 or _active_index >= _groups_queue.size():
		return {}
	return _groups_queue[_active_index].duplicate(true)

func _rotate_next() -> void:
	if _groups_queue.is_empty():
		return
	_active_index = (_active_index + 1) % _groups_queue.size()
	active_group_changed.emit(get_active_group_id())
