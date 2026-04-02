extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var player := load("res://scripts/Player.gd").new()
	_expect(bool(player.get("USE_PIXEL_SNAP")) == false, "player pixel snap should be disabled by default")
	var level_scene: PackedScene = load("res://level.tscn")
	var level: Node = level_scene.instantiate()
	get_root().add_child(level)
	await process_frame
	var cam: Camera2D = level.get_node_or_null("Player/Camera2D")
	_expect(cam != null, "camera should exist in level")
	if cam:
		_expect(cam.position_smoothing_enabled, "camera smoothing should be enabled")
		_expect(cam.position_smoothing_speed >= 8.0, "camera smoothing speed should be >= 8")
	level.queue_free()
	await process_frame
	_finish("camera_jitter_tests")

func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)

func _finish(name: String) -> void:
	if _failures.is_empty():
		print("[TEST] PASS %s" % name)
		quit(0)
		return
	for f in _failures:
		push_error("[TEST] FAIL %s: %s" % [name, f])
	quit(1)
