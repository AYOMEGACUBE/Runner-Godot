extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var root := Node2D.new()
	get_root().add_child(root)
	var renderer := WallRenderer.new()
	root.add_child(renderer)
	await process_frame
	var wall := WallData.new()
	renderer.setup(wall, "front", false)
	renderer.update_visible_area(-1, 1, -1, 1)
	_expect(renderer._multimesh.instance_count == 9, "visible area 3x3 should produce 9 instances")
	renderer.update_visible_area(-1, 1, -1, 1)
	_expect(renderer._multimesh.instance_count == 9, "same rect should keep instance count stable")
	root.queue_free()
	await process_frame
	_finish("wall_visible_area_tests")

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
