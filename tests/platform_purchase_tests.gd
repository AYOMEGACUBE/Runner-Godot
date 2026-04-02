extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var store := PlatformDataStore.new()
	var result_ok: Dictionary = store.buy_platforms_atomic(["10_1", "11_1"], "owner_a", "normal", "", "", 0)
	_expect(bool(result_ok.get("success", false)), "first platform purchase should succeed")
	var result_conflict: Dictionary = store.buy_platforms_atomic(["10_1"], "owner_b", "special", "", "", 0)
	_expect(not bool(result_conflict.get("success", true)), "conflicting platform purchase should fail")
	_expect(result_conflict.get("reason", "") == "already_owned", "reason should be already_owned")
	_finish("platform_purchase_tests")

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
