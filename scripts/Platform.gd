extends StaticBody2D
# Platform.gd — УЛУЧШЕННАЯ ГЕНЕРАЦИЯ МОНЕТ (как у тебя)

@export var size: Vector2 = Vector2(64, 64)
@export var coin_spawn_chance: float = 0.8
@export var coin_height_offset: float = 80.0

@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var coin_scene: PackedScene
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()
	
	# Платформа на переднем плане (z_index > стены)
	z_index = 0

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

	if coin_scene != null and coin_spawn_chance > 0.0:
		if rng.randf() < coin_spawn_chance:
			await get_tree().create_timer(0.1).timeout
			_spawn_coin_above()

	queue_redraw()

func _spawn_coin_above() -> void:
	if coin_scene == null:
		return

	var coin := coin_scene.instantiate()

	var root = get_tree().current_scene
	if root:
		root.add_child(coin)

		var platform_center := global_position
		var coin_pos := platform_center + Vector2(0.0, -coin_height_offset)
		coin.global_position = coin_pos

func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	draw_rect(rect, Color(0.1, 0.9, 0.2, 1.0))
