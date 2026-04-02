extends SceneTree

## 100 прогонов: один seed → одинаковый хеш выпеченных позиций; размер пула стабилен.

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	PhysicsConfig.calculate_jump_metrics()
	var rules: Dictionary = _minimal_rules()
	var bounds: Dictionary = {
		"min_x": 0.0, "max_x": 2000.0, "min_y": 0.0, "max_y": 1200.0
	}
	var start: Vector2 = Vector2(400.0, 600.0)
	var first_hash: int = 0
	for iteration in range(100):
		SeedManager.assign_run_seed(42)
		SeedManager.reset_streams()
		var lib := PathLibrary.new()
		lib.load_all()
		_expect(lib.size() == 50, "library should have 50 models")
		var sel := PathSelector.new()
		sel.library = lib
		sel.select_model_for_run()
		var m: PathModel = sel.active_model
		_expect(m != null, "model")
		m.bake_from_steps(rules, bounds, start, 2, 1, 64.0, 64.0)
		var h: int = _hash_platforms(m.platforms)
		if iteration == 0:
			first_hash = h
		else:
			_expect(h == first_hash, "hash mismatch iteration %d" % iteration)
	var pool_scene: PackedScene = load("res://Platform.tscn")
	var root := Node2D.new()
	var pool := PlatformPool.new(pool_scene, root, 8)
	var n0: int = pool.total_nodes()
	for _i in range(20):
		var p: Node2D = pool.get_platform()
		pool.release_platform(p)
	_expect(pool.total_nodes() == n0, "pool should not grow without overflow")
	root.queue_free()
	_finish("determinism_run_tests")

func _minimal_rules() -> Dictionary:
	return {
		"min_gap": 120.0,
		"max_gap": 320.0,
		"height_variation": 200.0,
		"vanish_chance": 0.1,
		"platform_sizes": {"small": [64, 64], "medium": [128, 64], "large": [256, 64]},
		"safe_margin_x": 32.0,
	}

func _hash_platforms(arr: Array) -> int:
	var s: String = ""
	for d in arr:
		if typeof(d) == TYPE_DICTIONARY:
			var dd: Dictionary = d
			s += "%.3f,%.3f,%d,%d|" % [float(dd["x"]), float(dd["y"]), int(dd["segments"]), int(dd.get("vanish", 0))]
	return int(hash(s))

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
