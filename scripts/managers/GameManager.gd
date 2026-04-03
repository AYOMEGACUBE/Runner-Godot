extends Node
class_name GameManager
## Пример подключения PathManager к забегу.
##
## Установка в редакторе:
## 1) В `level.tscn` добавьте дочерний `Node`, скрипт — этот файл.
## 2) Укажите `path_manager_path` на узел с `PathManager.gd` (см. шаг 3).
## 3) Рядом добавьте `Node`, скрипт `res://scripts/managers/PathManager.gd`.
##    — `player_path` = `../Player` (или путь к вашему CharacterBody2D).
##    — `platforms_parent_path` = путь к **пустому** `Node2D`, куда только LegStream кладёт платформы
##      (не используйте тот же `Platforms`, что и у стандартного `Level.gd`, иначе будут двойные платформы).
## 4) В `PathManager` включите `auto_start` **или** оставьте `enable_path_streaming` здесь = true.
##    Сигналы `leg_completed` / `wall_top_reached` подключаются автоматически, если задан `path_manager_path`.
##
## Полноценная замена процедурного `PathModel` в `Level.gd` не сделана в одном шаге: отключите спавн уровня
## или вынесите раннер в отдельную сцену, где только PathManager управляет платформами.

@export var path_manager_path: NodePath = NodePath("")
@export var enable_path_streaming: bool = false
@export var debug_log: bool = false

var _path_manager: PathManager = null


func _ready() -> void:
	if path_manager_path == NodePath(""):
		return
	_path_manager = get_node_or_null(path_manager_path) as PathManager
	if _path_manager == null:
		push_warning("GameManager: path_manager_path does not resolve to a PathManager")
		return
	if not _path_manager.leg_completed.is_connected(_on_leg_completed):
		_path_manager.leg_completed.connect(_on_leg_completed)
	if not _path_manager.wall_top_reached.is_connected(_on_wall_top_reached):
		_path_manager.wall_top_reached.connect(_on_wall_top_reached)
	if enable_path_streaming:
		_path_manager.start_streaming()


func _on_leg_completed(leg_index: int, direction: int) -> void:
	if debug_log:
		print("[GameManager] leg_completed leg=%d dir=%d" % [leg_index, direction])


func _on_wall_top_reached() -> void:
	print("[GameManager] Wall top reached. Ready for face transition.")
