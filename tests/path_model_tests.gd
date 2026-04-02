extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	SeedManager.assign_run_seed(3301)
	SeedManager.reset_streams()
	var selector := PathSelector.new()
	selector.initialize()
	_expect(selector.active_model != null, "active model should be selected")
	_expect(selector.active_model.steps.size() > 0, "path model should contain steps")
	for _i in range(30):
		var step: Dictionary = selector.next_step()
		_expect(not step.is_empty(), "next_step should not be empty")
		_expect(float(step.get("x_gap", 0.0)) > 0.0, "x_gap should be positive")
		_expect(abs(float(step.get("y_delta", 0.0))) <= 120.0, "y_delta should be bounded")
	_finish("path_model_tests")

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
