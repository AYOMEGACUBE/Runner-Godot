extends StaticBody2D
# Platform.gd — архивная база + красные платформы (обвал после первого касания)

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/Logger")
	if logger != null and logger.has_method("log"):
		logger.call("log", message)
	else:
		print(message)

@export var size: Vector2 = Vector2(64, 64)
@export var coin_spawn_chance: float = 0.8
@export var coin_height_offset: float = 80.0
@export var is_crumbling: bool = false
@export var crumble_delay: float = 0.08

@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var coin_scene: PackedScene
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _player_landed: bool = false
var _crumble_timer: float = 0.0
var _player_ref: CharacterBody2D = null

func _ready() -> void:
	rng.randomize()
	coin_scene = preload("res://Coin.tscn")

	if collision_shape != null:
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = size
		collision_shape.shape = rect_shape
		collision_shape.one_way_collision = true
		collision_shape.one_way_collision_margin = 10.0

	# Платформа на слое 1
	set_collision_layer_value(1, true)
	for i in range(2, 33):
		set_collision_layer_value(i, false)
	if collision_shape:
		collision_shape.disabled = false

	if coin_scene != null and coin_spawn_chance > 0.0:
		if rng.randf() < coin_spawn_chance:
			await get_tree().create_timer(0.1).timeout
			_spawn_coin_above()

	queue_redraw()

func _physics_process(_delta: float) -> void:
	if not is_crumbling or _player_landed:
		return

	if _player_ref == null:
		_player_ref = get_tree().get_first_node_in_group("player")
		if _player_ref == null:
			var level := get_parent().get_parent()
			if level:
				_player_ref = level.get_node_or_null("Player")

	if _player_ref == null:
		return

	var collision_count: int = _player_ref.get_slide_collision_count()
	for i in range(collision_count):
		var collision = _player_ref.get_slide_collision(i)
		if collision and collision.get_collider() == self:
			var normal: Vector2 = collision.get_normal()
			# Исчезает после первого приземления сверху.
			if normal.y < -0.7:
				_player_landed = true
				_crumble_timer = 0.0
				set_collision_layer_value(1, false)
				set_collision_mask_value(1, false)
				if collision_shape:
					collision_shape.disabled = true
				_log("[PLATFORM_LANDED] pos=%s is_crumbling=%s normal=%s" % [global_position, is_crumbling, normal])
				break

func _process(delta: float) -> void:
	if not is_crumbling or not _player_landed:
		return

	_crumble_timer += delta
	queue_redraw()
	if _crumble_timer >= crumble_delay:
		_log("[PLATFORM_CRUMBLE] pos=%s timer=%.3f delay=%.3f" % [global_position, _crumble_timer, crumble_delay])
		var level := get_parent().get_parent()
		if level and level.has_method("_remove_platform"):
			level._remove_platform(self)
		queue_free()

func _spawn_coin_above() -> void:
	if coin_scene == null:
		_log("[PLATFORM_COIN] FAILED - coin_scene is null")
		return

	var coin := coin_scene.instantiate()
	var root = get_tree().current_scene
	if root:
		root.add_child(coin)
		var platform_center := global_position
		var coin_pos := platform_center + Vector2(0.0, -coin_height_offset)
		coin.global_position = coin_pos
		_log("[PLATFORM_COIN] spawned at pos=%s platform_pos=%s" % [coin_pos, platform_center])
	else:
		_log("[PLATFORM_COIN] FAILED - no current_scene")

## Сбрасывает состояние платформы для переиспользования из пула
func reset_for_reuse() -> void:
	_player_landed = false
	_crumble_timer = 0.0
	set_collision_layer_value(1, true)
	set_collision_mask_value(1, true)
	if collision_shape:
		collision_shape.disabled = false
	queue_redraw()

func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	if is_crumbling:
		var alpha: float = 1.0
		if _player_landed:
			alpha = max(0.0, 1.0 - (_crumble_timer / crumble_delay))
		draw_rect(rect, Color(0.9, 0.2, 0.1, alpha))
	else:
		draw_rect(rect, Color(0.1, 0.9, 0.2, 1.0))
