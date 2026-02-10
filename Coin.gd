extends Area2D
# Coin.gd - ИСПРАВЛЕННАЯ ВЕРСИЯ

@export var value: int = 1
@export var radius: float = 16.0

@onready var collision: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	print("✅ Coin spawned at: ", global_position)
	
	# ВАЖНО: Включаем мониторинг
	monitoring = true
	monitorable = true
	
	# КРИТИЧЕСКИ ВАЖНО: СЛОИ КОЛЛИЗИИ
	# Монета на слое 2, реагирует на маску 1 (игрок)
	set_collision_layer_value(2, true)
	set_collision_mask_value(1, true)
	
	# ВЫКЛЮЧАЕМ все остальные слои
	for i in range(1, 33):
		if i != 2:
			set_collision_layer_value(i, false)
		if i != 1:
			set_collision_mask_value(i, false)

	# СОЗДАЕМ КОЛЛАЙДЕР (круг)
	if collision != null:
		var shape = CircleShape2D.new()
		shape.radius = radius
		collision.shape = shape

	# ПОДКЛЮЧАЕМ СИГНАЛ
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
		
	print("✅ Coin setup complete - Layer: 2, Mask: 1")
	queue_redraw()

func _on_body_entered(body: Node) -> void:
	print("🎯 Coin: body entered - ", body.name)
	
	if body is CharacterBody2D and body.name == "Player":
		print("💰 Coin collected! Adding ", value, " points")
		
		# Добавляем очки
		GameState.add_coin(value)
		print("📊 New score: ", GameState.score)
		
		# Исчезаем
		queue_free()

func _draw() -> void:
	# РИСУЕМ КРАСИВУЮ МОНЕТУ
	var center = Vector2.ZERO
	
	# Жёлтая середина
	draw_circle(center, radius, Color(1.0, 0.84, 0.0, 1.0))
	
	# Тёмно-жёлтый ободок
	draw_arc(center, radius, 0, TAU, 32, Color(0.8, 0.6, 0.0, 1.0), 3.0)
	
	# Внутренний круг
	draw_circle(center, radius * 0.6, Color(1.0, 0.9, 0.3, 1.0))
	
	# Блик
	draw_circle(Vector2(-radius * 0.3, -radius * 0.3), radius * 0.2, Color(1.0, 1.0, 1.0, 0.8))
