extends SceneTree
## Запуск: godot --headless --path . --script tests/test_economy.gd

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	test_face_id_uniqueness()
	test_price_calculation()
	test_config_priority_bundled_over_cache()
	test_performance_calculate_face_id()
	_finish("test_economy")


func test_face_id_uniqueness() -> void:
	var a: int = EconomyManager.calculate_face_id(0, 0, 0, 1)
	var b: int = EconomyManager.calculate_face_id(0, 0, 0, 2)
	var c: int = EconomyManager.calculate_face_id(0, 0, 1, 1)
	_expect(a != b, "face_id should differ by side_external")
	_expect(a != c, "face_id should differ by v")
	_expect(a >= 0, "face_id non-negative (64-bit int)")
	var max_seg: int = 5 * CubeMath.CELLS_PER_FACE + (CubeMath.SEGMENTS_PER_SIDE - 1) * CubeMath.SEGMENTS_PER_SIDE + (CubeMath.SEGMENTS_PER_SIDE - 1)
	var max_id: int = (max_seg << 3) | 5
	_expect(max_id > 0, "upper bound face_id fits in int")


func test_price_calculation() -> void:
	var wall := WallData.new()
	wall.auto_save_enabled = false
	# front = external 1 (free in economy.json), back = 2 (paid)
	var ext_free: int = EconomyManager.side_external_for_name("front")
	var ext_paid: int = EconomyManager.side_external_for_name("back")
	var p_free_first: int = EconomyManager.get_price(ext_free, false)
	var p_free_owned: int = EconomyManager.get_price(ext_free, true)
	var p_paid_first: int = EconomyManager.get_price(ext_paid, false)
	var p_paid_owned: int = EconomyManager.get_price(ext_paid, true)
	_expect(p_free_first == 0, "free side not owned -> 0")
	_expect(p_free_owned == 400, "free side has owner -> buyout 400")
	_expect(p_paid_first == 50, "paid side not owned -> 50")
	_expect(p_paid_owned == 0, "paid side has owner -> 0 listing")
	var seg: String = "0_0"
	var hit_price: int = EconomyManager.get_listing_price_for_hit("front", seg, "front", wall)
	_expect(hit_price == 0, "listing free front with empty wall")
	var ext_unknown: int = EconomyManager.side_external_for_name("not_a_real_side_xyz")
	_expect(ext_unknown == 2, "unknown side name should default to paid external 2, not free 1")
	_expect(EconomyManager.side_external_for_name("  ") == 2, "empty/whitespace side -> paid default")


func test_config_priority_bundled_over_cache() -> void:
	# Перезагрузка правил из economy.json не очищает журнал покупок в памяти
	var fid: int = EconomyManager.calculate_face_id(1, 10, 20, 3)
	EconomyManager.record_face_purchase(fid, 42)
	_expect(EconomyManager.is_face_owned(fid), "record_face_purchase should mark owned")
	EconomyManager.load_economy_config()
	_expect(EconomyManager.is_face_owned(fid), "load_economy_config must not clear _owned_faces")


func test_performance_calculate_face_id() -> void:
	var t: int = Time.get_ticks_msec()
	for i in range(1000):
		EconomyManager.calculate_face_id(i % 6, i % 3200, (i * 7) % 3200, (i % 6) + 1)
	var dt: int = Time.get_ticks_msec() - t
	_expect(dt < 50, "1000 face_id calcs should be < 50 ms (got %d ms)" % dt)


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
