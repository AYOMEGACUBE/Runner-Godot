extends SceneTree

const LEVEL_SCRIPT := preload("res://scripts/Level.gd")
const PLATFORM_SCENE := preload("res://Platform.tscn")

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run_all")

func _run_all() -> void:
	_test_reach_center_to_edge_rule()
	await _test_fake_and_crumble_do_not_conflict()
	_test_no_overlap_validator()
	await _test_decoy_does_not_block_player()
	_test_decoy_does_not_influence_main_path()
	_test_visual_only_validator_blocks_overlap_any_platform()

	if _failures.is_empty():
		print("[TEST] PASS platform_generation_tests")
		quit(0)
		return

	for f in _failures:
		push_error("[TEST] FAIL: %s" % f)
	quit(1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _test_reach_center_to_edge_rule() -> void:
	var level: Node2D = LEVEL_SCRIPT.new()
	level.last_main_pos = Vector2(0.0, 0.0)
	var jump_v: float = -960.0
	var grav: float = 2600.0
	var speed: float = 260.0
	var reach: float = level._max_horizontal_reach(-32.0, -32.0, jump_v, grav, speed)
	var next_half: float = 128.0

	var reachable_target: Vector2 = Vector2(reach + next_half - 1.0, 0.0)
	var unreachable_target: Vector2 = Vector2(reach + next_half + 20.0, 0.0)

	_expect(level._center_to_next_edge_is_reachable(reachable_target, next_half, jump_v, grav, speed), "reach rule should allow center->edge inside max jump")
	_expect(not level._center_to_next_edge_is_reachable(unreachable_target, next_half, jump_v, grav, speed), "reach rule should reject center->edge outside max jump")

func _test_fake_and_crumble_do_not_conflict() -> void:
	var p: StaticBody2D = PLATFORM_SCENE.instantiate()
	p.set("is_decoy", true)
	p.set("fake_visual_only", true)
	p.set("is_fake", false)
	p.set("is_crumbling", true)
	get_root().add_child(p)
	await process_frame

	_expect(not bool(p.get("is_crumbling")), "fake_visual_only/is_decoy should disable crumbling conflict")
	_expect(not p.get_collision_layer_value(1), "fake_visual_only/is_decoy should disable collision layer")

	p.queue_free()
	await process_frame

func _test_no_overlap_validator() -> void:
	var level: Node2D = LEVEL_SCRIPT.new()
	var existing := Node2D.new()
	existing.global_position = Vector2(500.0, 400.0)
	existing.scale.x = 4.0
	level.platforms = [existing]

	_expect(not level._is_position_valid_for_platform(Vector2(500.0, 400.0), 3), "validator should reject overlapping platforms")
	_expect(level._is_position_valid_for_platform(Vector2(1200.0, 400.0), 3), "validator should allow separated platforms")

func _test_decoy_does_not_influence_main_path() -> void:
	var level: Node2D = LEVEL_SCRIPT.new()
	var yellow: StaticBody2D = PLATFORM_SCENE.instantiate()
	yellow.set("is_decoy", true)
	yellow.set("fake_visual_only", true)
	yellow.set("is_fake", false)
	yellow.global_position = Vector2(900.0, 500.0)
	yellow.scale.x = 4.0
	level.platforms = [yellow]

	_expect(level._is_position_valid_for_platform(Vector2(900.0, 500.0), 3), "decoy must be ignored in main-path placement validation")
	_expect(not level._is_position_valid_for_platform(Vector2(900.0, 500.0), 3, null, 24.0, 8.0, true), "validator can include decoys when explicitly requested")
	_expect(level._is_position_valid_for_platform(Vector2(1500.0, 500.0), 3), "placement should pass when far from yellow platform")

func _test_decoy_does_not_block_player() -> void:
	var p: StaticBody2D = PLATFORM_SCENE.instantiate()
	p.set("is_decoy", true)
	p.set("fake_visual_only", true)
	p.set("is_fake", false)
	get_root().add_child(p)
	await process_frame

	_expect(not p.get_collision_layer_value(1), "decoy should not collide with player on platform layer")
	_expect(not p.get_collision_mask_value(1), "decoy should not use platform collision mask")

	p.queue_free()
	await process_frame

func _test_visual_only_validator_blocks_overlap_any_platform() -> void:
	var level: Node2D = LEVEL_SCRIPT.new()
	var main_like := Node2D.new()
	main_like.global_position = Vector2(1200.0, 600.0)
	main_like.scale.x = 4.0
	var visual_like := Node2D.new()
	visual_like.set("is_decoy", true)
	visual_like.set("fake_visual_only", true)
	visual_like.global_position = Vector2(1500.0, 600.0)
	visual_like.scale.x = 3.0
	level.platforms = [main_like, visual_like]

	_expect(not level._is_position_valid_for_visual_only(Vector2(1200.0, 600.0), 2), "visual-only validator should block overlap with main platform")
	_expect(not level._is_position_valid_for_visual_only(Vector2(1500.0, 600.0), 2), "visual-only validator should block overlap with visual platform")
	_expect(level._is_position_valid_for_visual_only(Vector2(2000.0, 600.0), 2), "visual-only validator should allow free space")
