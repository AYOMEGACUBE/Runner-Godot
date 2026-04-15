extends Control

@export_file("*.tscn")
var next_scene_path: String = ""

@onready var _label: Label = $CenterContainer/Label


func _ready() -> void:
	if next_scene_path.strip_edges() != "":
		call_deferred("_go_next")


func set_message(text: String) -> void:
	if _label != null:
		_label.text = text


func _go_next() -> void:
	var target: String = next_scene_path.strip_edges()
	if target == "":
		return
	var err: int = get_tree().change_scene_to_file(target)
	if err != OK:
		push_error("LoadingLevel: cannot change scene to %s (err=%d)" % [target, err])
