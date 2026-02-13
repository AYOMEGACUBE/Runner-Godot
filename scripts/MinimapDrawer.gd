extends Node2D
# ============================================================================
# MinimapDrawer.gd
# Рисует упрощённую визуализацию стены в мини-карте
# ============================================================================

var wall_data: WallData = null
var camera_position: Vector2 = Vector2.ZERO
const SEGMENT_SIZE: int = 48
const SEGMENTS_PER_SIDE: int = 3200

func setup(data: WallData) -> void:
	wall_data = data
	queue_redraw()

func set_camera_position(pos: Vector2) -> void:
	camera_position = pos
	queue_redraw()

func _draw() -> void:
	if wall_data == null:
		return
	
	# Рисуем границы стены
	var wall_size = SEGMENTS_PER_SIDE * SEGMENT_SIZE
	var half_size = wall_size * 0.5
	var rect = Rect2(-half_size, -half_size, wall_size, wall_size)
	draw_rect(rect, Color(0.2, 0.6, 0.8, 0.3), false, 2.0)
	
	# Рисуем купленные сегменты (упрощённо - только первые несколько для производительности)
	if Engine.has_singleton("GameState"):
		var side = GameState.get_active_wall_side()
		var drawn_count = 0
		const MAX_DRAWN_SEGMENTS = 100  # Ограничиваем для производительности
		
		for seg_id in wall_data.segments.keys():
			if drawn_count >= MAX_DRAWN_SEGMENTS:
				break
			
			var face_data = wall_data.get_face_data(seg_id, side)
			var owner = str(face_data.get("owner", ""))
			if owner != "":
				# Вычисляем позицию сегмента
				var coords = seg_id.split("_")
				if coords.size() >= 2:
					var seg_x = int(coords[0]) * SEGMENT_SIZE
					var seg_y = int(coords[1]) * SEGMENT_SIZE
					var pos = Vector2(seg_x, seg_y)
					
					# Рисуем маленький квадратик для купленного сегмента
					var seg_rect = Rect2(pos - Vector2(SEGMENT_SIZE * 0.5, SEGMENT_SIZE * 0.5), Vector2(SEGMENT_SIZE, SEGMENT_SIZE))
					draw_rect(seg_rect, Color(0.1, 0.8, 0.2, 0.6))
					drawn_count += 1
	
	# Рисуем индикатор позиции камеры (красный квадрат)
	if camera_position != Vector2.ZERO:
		var cam_rect = Rect2(camera_position - Vector2(100, 100), Vector2(200, 200))
		draw_rect(cam_rect, Color(1.0, 0.0, 0.0, 0.8))
