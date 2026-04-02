extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var wall := WallData.new()
	wall.get_segment("1_1")
	wall.get_segment("2_1")
	var req_ts: int = Time.get_unix_time_from_system()
	var ok: Dictionary = wall.buy_sides_atomic(["1_1", "2_1"], "front", "owner_a", req_ts)
	_expect(bool(ok.get("success", false)), "atomic segment purchase should succeed")
	var conflict: Dictionary = wall.buy_sides_atomic(["1_1"], "front", "owner_b", req_ts)
	_expect(not bool(conflict.get("success", true)), "already bought segment should conflict")
	_expect(conflict.get("reason", "") == "conflict", "reason should be conflict")
	_finish("segment_purchase_tests")

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
