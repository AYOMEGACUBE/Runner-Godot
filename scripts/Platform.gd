extends StaticBody2D
# Platform.gd — УЛУЧШЕННАЯ ГЕНЕРАЦИЯ МОНЕТ (как у тебя)

@export var size: Vector2 = Vector2(64, 64)
@export var coin_spawn_chance: float = 0.8
@export var coin_height_offset: float = 80.0
@export var is_crumbling: bool = false  # Обваливающаяся платформа
@export var crumble_delay: float = 0.75  # Задержка перед обвалом (0.5-1 сек)

@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var coin_scene: PackedScene
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _player_landed: bool = false
var _crumble_timer: float = 0.0
var _player_ref: CharacterBody2D = null  # Кэш ссылки на игрока

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

func _physics_process(delta: float) -> void:
	if is_crumbling and not _player_landed:
		# Находим игрока один раз и кэшируем
		if _player_ref == null:
			_player_ref = get_tree().get_first_node_in_group("player")
			if _player_ref == null:
				var level = get_parent().get_parent()
				if level:
					_player_ref = level.get_node_or_null("Player")
		
		if _player_ref:
			# Проверяем коллизии игрока через get_slide_collision_count()
			# Это самый надёжный способ обнаружения приземления
			var collision_count: int = _player_ref.get_slide_collision_count()
			for i in range(collision_count):
				var collision = _player_ref.get_slide_collision(i)
				if collision and collision.get_collider() == self:
					# Игрок столкнулся с этой платформой
					var normal: Vector2 = collision.get_normal()
					# Проверяем, что игрок приземлился сверху (нормаль направлена вверх)
					if normal.y < -0.7:  # Игрок сверху платформы
						_player_landed = true
						_crumble_timer = 0.0
						# СРАЗУ отключаем коллизию, чтобы игрок не мог второй раз опереться
						set_collision_layer_value(1, false)
						set_collision_mask_value(1, false)
						if collision_shape:
							collision_shape.disabled = true
						break  # Выходим из цикла, так как уже обнаружили приземление

func _process(delta: float) -> void:
	if is_crumbling and _player_landed:
		_crumble_timer += delta
		queue_redraw()
		
		if _crumble_timer >= crumble_delay:
			# Платформа обваливается
			# Удаляем платформу из массива platforms в Level перед освобождением
			var level = get_parent().get_parent()
			if level and level.has_method("_remove_platform"):
				level._remove_platform(self)
				level._remove_platform(self)
			queue_free()

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
	if is_crumbling:
		# Обваливающаяся платформа - красноватый оттенок
		var alpha: float = 1.0
		if _player_landed:
			# Плавное исчезновение перед обвалом
			alpha = 1.0 - (_crumble_timer / crumble_delay)
		draw_rect(rect, Color(0.9, 0.2, 0.1, alpha))
	else:
		# Обычная платформа - зелёный
		draw_rect(rect, Color(0.1, 0.9, 0.2, 1.0))
