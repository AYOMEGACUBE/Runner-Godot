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
	
	# Граница всей стены (контур)
	var wall_size: int = SEGMENTS_PER_SIDE * SEGMENT_SIZE
	var half_size: int = wall_size / 2
	draw_rect(Rect2(-half_size, -half_size, wall_size, wall_size), Color(0.2, 0.6, 0.8, 0.3), false, 2.0)
	
	# Рисуем ТОЛЬКО купленные сегменты (все стороны) — без ограничения 100
	var half_seg: float = SEGMENT_SIZE * 0.5
	for seg_id in wall_data.segments.keys():
		var seg: Dictionary = wall_data.segments[seg_id] as Dictionary
		var faces: Dictionary = seg.get("faces", {}) as Dictionary
		var has_owner: bool = false
		for face_key in faces.keys():
			if str((faces[face_key] as Dictionary).get("owner", "")).strip_edges() != "":
				has_owner = true
				break
		if not has_owner:
			continue
		var coords: PackedStringArray = str(seg_id).split("_")
		if coords.size() < 2:
			continue
		var seg_x: float = int(coords[0]) * SEGMENT_SIZE
		var seg_y: float = int(coords[1]) * SEGMENT_SIZE
		draw_rect(Rect2(seg_x - half_seg, seg_y - half_seg, SEGMENT_SIZE, SEGMENT_SIZE), Color(1.0, 0.85, 0.1, 0.85))
	
	# Индикатор камеры
	if camera_position != Vector2.ZERO:
		draw_rect(Rect2(camera_position - Vector2(100, 100), Vector2(200, 200)), Color(1.0, 0.0, 0.0, 0.8))
