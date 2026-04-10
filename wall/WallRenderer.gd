extends Node2D
class_name WallRenderer
# ============================================================================
# WallRenderer.gd
# Оптимизированный рендерер стены на основе MultiMeshInstance2D
# ============================================================================
# Вместо тысяч нод использует один MultiMesh для батч-отрисовки
# Данные берутся из WallData, клики обрабатываются по координатам
# ============================================================================

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")
const SEGMENT_SIZE: int = WorldSegmentGrid.SEGMENT_SIZE_PX
const SEGMENTS_PER_SIDE: int = WorldSegmentGrid.SEGMENTS_PER_FACE_AXIS

var multimesh_instance: MultiMeshInstance2D = null  # Создаётся в _ready()

var wall_data: WallData = null
var side_id: String = "front"
var allow_purchases: bool = false

# Видимая область (в сегментах)
var visible_min_x: int = 0
var visible_max_x: int = 0
var visible_min_y: int = 0
var visible_max_y: int = 0

# Пул трансформ для переиспользования
var _transforms: Array[Transform2D] = []
var _segment_ids: Array[String] = []
var _multimesh: MultiMesh = null

# Параметры дыхания для каждого сегмента (независимые)
var _breathing_params: Array[Dictionary] = []  # [{phase, speed_factor, amplitude_x, amplitude_y}, ...]
var _breathing_time: float = 0.0
const BASE_BREATHING_AMPLITUDE: float = 1.2
const BASE_BREATHING_SPEED: float = PI * 0.4

# Смена сторон сегментов (каждый сегмент меняет сторону независимо)
var _segment_sides: Array[String] = []  # Текущая сторона для каждого сегмента
var _side_change_timers: Array[float] = []  # Таймеры до следующей смены стороны
var _side_change_intervals: Array[float] = []  # Интервалы смены для каждого сегмента
const SIDES: Array[String] = ["front", "back", "left", "right", "top", "bottom"]
## [OPTIMIZATION] Потолок инстансов MultiMesh — защита от отдаления камеры (миллионы ячеек)
const MAX_VISIBLE_INSTANCES: int = 10000
const HEAVY_MESH_SKIP_PROCESS: int = 500000

## [OPTIMIZATION] Один RNG на весь кадр обновления видимой области / смены сторон
var _shared_rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Отображение изображений поверх MultiMesh
var _images_layer: Node2D = null                  # Отдельный слой для спрайтов
var _segment_sprites: Dictionary = {}             # segment_id -> Sprite2D
var _sprite_pool: Array[Sprite2D] = []            # пул переиспользуемых спрайтов
var _segment_index: Dictionary = {}               # segment_id -> индекс в массивах
## Последняя известная грань тайла по id (сохраняется при скролле вне видимого MultiMesh) — цена покупки / экономика.
var _last_known_tile_side: Dictionary = {}

# Подсветка выбранных сегментов
var _highlighted_segment_ids: Array[String] = []
## Остановить смену сторон во время покупки
var pause_side_switching: bool = false
## Затемнять чужие сегменты во время предпросмотра
var dim_other_segments: bool = false
## Временные пути изображений для предпросмотра (segment_id -> path). В режиме предпросмотра отображаются вместо данных из WallData.
var _preview_image_paths: Dictionary = {}
var _texture_cache: Dictionary = {}  # image_path -> Texture2D
@export var DEBUG_LOG: bool = false

func _ready() -> void:
	if multimesh_instance == null:
		multimesh_instance = MultiMeshInstance2D.new()
		multimesh_instance.name = "MultiMeshInstance2D"
		multimesh_instance.z_index = -10  # Стена на заднем плане
		add_child(multimesh_instance)
	
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.instance_count = 0
	
	# Создаём базовый квадрат для сегмента программно
	var array_mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	var half_size: float = SEGMENT_SIZE * 0.5
	var vertices = PackedVector3Array([
		Vector3(-half_size, -half_size, 0),
		Vector3(half_size, -half_size, 0),
		Vector3(half_size, half_size, 0),
		Vector3(-half_size, half_size, 0)
	])
	var indices = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var uvs = PackedVector2Array([
		Vector2(0, 0),
		Vector2(1, 0),
		Vector2(1, 1),
		Vector2(0, 1)
	])
	
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_multimesh.mesh = array_mesh
	
	multimesh_instance.multimesh = _multimesh

	# Слой для спрайтов с изображениями сегментов
	_images_layer = Node2D.new()
	_images_layer.name = "ImagesLayer"
	_images_layer.z_index = -9  # Чуть выше самой стены, но ниже платформ/монет
	add_child(_images_layer)

func setup(data: WallData, side: String, purchases_enabled: bool = false) -> void:
	wall_data = data
	side_id = side
	allow_purchases = purchases_enabled


func _remember_tile_side(segment_id: String, side_name: String) -> void:
	if segment_id.is_empty() or side_name.strip_edges().is_empty():
		return
	_last_known_tile_side[segment_id] = side_name


## Покупка записана на грань тайла (front/back/…), а визуально мы крутим `_segment_sides`.
## Без этого `get_face_data(visual_side)` часто пустой по owner — не видно ни заливки, ни картинки.
func _effective_face_data_for_ownership(segment_id: String, visual_side: String) -> Dictionary:
	if wall_data == null:
		return {}
	var fd: Dictionary = wall_data.get_face_data(segment_id, visual_side)
	if str(fd.get("owner", "")).strip_edges() != "":
		return fd
	for s in SIDES:
		var fd2: Dictionary = wall_data.get_face_data(segment_id, s)
		if str(fd2.get("owner", "")).strip_edges() != "":
			return fd2
	return fd


func _effective_image_side_for_texture(segment_id: String, visual_side: String) -> String:
	if wall_data == null:
		return visual_side
	var p0: String = wall_data.get_face_image_path(segment_id, visual_side).strip_edges()
	if p0 != "":
		return visual_side
	for s in SIDES:
		if wall_data.get_face_image_path(segment_id, s).strip_edges() != "":
			return s
	return visual_side


func update_visible_area(min_x: int, max_x: int, min_y: int, max_y: int) -> void:
	## [OPTIMIZATION] Сжимаем окно к центру, если ячеек слишком много
	var width: int = max_x - min_x + 1
	var height: int = max_y - min_y + 1
	var total_segments: int = width * height
	if total_segments > MAX_VISIBLE_INSTANCES:
		var scale: float = sqrt(float(MAX_VISIBLE_INSTANCES) / float(total_segments))
		var cx: float = (float(min_x) + float(max_x)) * 0.5
		var cy: float = (float(min_y) + float(max_y)) * 0.5
		var half_w: float = (float(width) * 0.5) * scale
		var half_h: float = (float(height) * 0.5) * scale
		min_x = int(floor(cx - half_w))
		max_x = int(ceil(cx + half_w))
		min_y = int(floor(cy - half_h))
		max_y = int(ceil(cy + half_h))
		if min_x > max_x:
			var swap_x: int = min_x
			min_x = max_x
			max_x = swap_x
		if min_y > max_y:
			var swap_y: int = min_y
			min_y = max_y
			max_y = swap_y
		width = max_x - min_x + 1
		height = max_y - min_y + 1
		total_segments = width * height

	visible_min_x = min_x
	visible_max_x = max_x
	visible_min_y = min_y
	visible_max_y = max_y
	
	# Сохраняем текущие стороны существующих сегментов (чтобы не терять состояние)
	var old_sides: Dictionary = {}  # segment_id -> side
	var old_timers: Dictionary = {}  # segment_id -> timer
	var old_intervals: Dictionary = {}  # segment_id -> interval
	
	for i in range(_segment_ids.size()):
		if i < _segment_sides.size():
			old_sides[_segment_ids[i]] = _segment_sides[i]
		if i < _side_change_timers.size():
			old_timers[_segment_ids[i]] = _side_change_timers[i]
		if i < _side_change_intervals.size():
			old_intervals[_segment_ids[i]] = _side_change_intervals[i]
	
	# Обновляем MultiMesh
	_multimesh.instance_count = total_segments
	
	# Очищаем массивы
	_transforms.clear()
	_segment_ids.clear()
	_breathing_params.clear()
	_segment_sides.clear()
	_side_change_timers.clear()
	_side_change_intervals.clear()
	_segment_index.clear()
	
	_transforms.resize(total_segments)
	_segment_ids.resize(total_segments)
	_breathing_params.resize(total_segments)
	_segment_sides.resize(total_segments)
	_side_change_timers.resize(total_segments)
	_side_change_intervals.resize(total_segments)
	
	# Заполняем трансформы и данные
	var idx: int = 0
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var segment_id: String = "%d_%d" % [x, y]
			var pos: Vector2 = Vector2(x * SEGMENT_SIZE, y * SEGMENT_SIZE)
			
			# Генерируем РАНДОМНЫЕ параметры на основе segment_id
			var sm: Node = get_node_or_null("/root/SeedManager")
			var gs_seed: int = int(sm.get("global_seed")) if sm != null else 0
			var seed_hash: int = int(hash(str(gs_seed) + "::" + segment_id)) & 0x7FFFFFFF
			_shared_rng.seed = seed_hash if seed_hash != 0 else 1
			
			# Восстанавливаем сторону из старого состояния или создаём новую
			var current_side: String
			if old_sides.has(segment_id):
				# Сохраняем текущую сторону сегмента
				current_side = old_sides[segment_id]
				_side_change_timers[idx] = old_timers.get(segment_id, 0.0)
				_side_change_intervals[idx] = old_intervals.get(segment_id, _shared_rng.randf_range(30.0, 90.0))
			else:
				# Новый в текущем окне: если сегмент уже был на экране раньше — та же грань, иначе случайная.
				if _last_known_tile_side.has(segment_id):
					current_side = str(_last_known_tile_side[segment_id])
					var change_interval_r: float = _shared_rng.randf_range(30.0, 90.0)
					_side_change_intervals[idx] = change_interval_r
					_side_change_timers[idx] = _shared_rng.randf_range(0.0, change_interval_r * 0.3)
				else:
					current_side = SIDES[_shared_rng.randi() % SIDES.size()]
					var change_interval: float = _shared_rng.randf_range(30.0, 90.0)
					_side_change_intervals[idx] = change_interval
					_side_change_timers[idx] = _shared_rng.randf_range(0.0, change_interval * 0.3)
			
			_segment_sides[idx] = current_side
			_remember_tile_side(segment_id, current_side)
			
			# Данные грани: визуальная сторона + владение с любой купленной грани тайла
			var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, current_side)
			
			# Цвет сегмента по текущей стороне (визуализация смены сторон)
			var color: Color = _get_segment_color_by_side(current_side, face_data, segment_id)
			
			# Базовый трансформ (без дыхания)
			var transform: Transform2D = Transform2D.IDENTITY
			transform.origin = pos
			
			_transforms[idx] = transform
			_segment_ids[idx] = segment_id
			_segment_index[segment_id] = idx
			
			# Генерируем РАНДОМНЫЕ параметры дыхания для каждого сегмента
			_breathing_params[idx] = {
				"phase": _shared_rng.randf() * TAU,
				"speed_factor": _shared_rng.randf_range(0.6, 1.4),
				"amplitude_x": _shared_rng.randf_range(0.3, 0.8) * BASE_BREATHING_AMPLITUDE,
				"amplitude_y": _shared_rng.randf_range(0.5, 1.2) * BASE_BREATHING_AMPLITUDE,
				"offset_x": _shared_rng.randf_range(-0.5, 0.5),
				"offset_y": _shared_rng.randf_range(-0.5, 0.5)
			}
			
			# Применяем к MultiMesh
			_multimesh.set_instance_transform_2d(idx, transform)
			_multimesh.set_instance_color(idx, color)
			
			idx += 1

	# Обновляем спрайты с изображениями для видимых сегментов
	_update_image_sprites()

func _process(delta: float) -> void:
	## [OPTIMIZATION] При аномально большом числе инстансов — не дышим и не дергаем стороны (защита от фриза)
	if _multimesh != null and _multimesh.instance_count > HEAVY_MESH_SKIP_PROCESS:
		return
	_process_side_changes(delta)
	
	var gs: Node = get_node_or_null("/root/GameState")
	var breathing_enabled: bool = gs != null and bool(gs.get("wall_breathing_enabled"))
	if not breathing_enabled:
		# Если дыхание выключено, применяем базовые трансформы без смещения
		for i in range(_multimesh.instance_count):
			_multimesh.set_instance_transform_2d(i, _transforms[i])
		return
	
	# Глобальное время для дыхания
	_breathing_time += delta
	
	# Применяем НЕЗАВИСИМОЕ дыхание к каждому сегменту
	for i in range(_multimesh.instance_count):
		if i >= _breathing_params.size():
			continue
		
		var base_transform: Transform2D = _transforms[i]
		var params: Dictionary = _breathing_params[i]
		
		# Вычисляем независимое движение для каждого сегмента
		var phase_x: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_x
		var phase_y: float = _breathing_time * BASE_BREATHING_SPEED * params.speed_factor + params.phase + params.offset_y
		
		# Рандомное движение по осям X и Y независимо
		var offset_x: float = sin(phase_x) * params.amplitude_x
		var offset_y: float = cos(phase_y) * params.amplitude_y
		
		var random_offset: Vector2 = Vector2(offset_x, offset_y)
		
		var final_transform: Transform2D = base_transform
		final_transform.origin += random_offset
		
		_multimesh.set_instance_transform_2d(i, final_transform)

		# Обновляем позицию спрайта, если у сегмента есть изображение
		if i < _segment_ids.size():
			var seg_id := _segment_ids[i]
			if _segment_sprites.has(seg_id):
				var sprite: Sprite2D = _segment_sprites[seg_id]
				if sprite:
					sprite.position = final_transform.origin

func _process_side_changes(delta: float) -> void:
	if pause_side_switching:
		return
	# Обрабатываем смену сторон для каждого сегмента независимо
	for i in range(_multimesh.instance_count):
		if i >= _side_change_timers.size() or i >= _segment_sides.size():
			continue
		
		# Увеличиваем таймер
		_side_change_timers[i] += delta
		
		# Проверяем, пора ли менять сторону
		if _side_change_timers[i] >= _side_change_intervals[i]:
			# Меняем сторону на случайную другую
			var current_side: String = _segment_sides[i]
			var new_side: String = current_side
			
			# Выбираем случайную сторону, отличную от текущей
			var available_sides: Array[String] = []
			for side in SIDES:
				if side != current_side:
					available_sides.append(side)
			
			if available_sides.size() > 0:
				var sm2: Node = get_node_or_null("/root/SeedManager")
				var gs_seed2: int = int(sm2.get("global_seed")) if sm2 != null else 0
				var seed_hash: int = int(hash(str(gs_seed2) + "::" + _segment_ids[i] + "::sidepick")) & 0x7FFFFFFF
				_shared_rng.seed = seed_hash if seed_hash != 0 else 1
				new_side = available_sides[_shared_rng.randi() % available_sides.size()]
			
			_segment_sides[i] = new_side
			_remember_tile_side(_segment_ids[i], new_side)
			
			# Сбрасываем таймер и задаём новый интервал
			var segment_id2: String = _segment_ids[i]
			var sm3: Node = get_node_or_null("/root/SeedManager")
			var gs_seed3: int = int(sm3.get("global_seed")) if sm3 != null else 0
			var seed_iv: int = int(hash(str(gs_seed3) + "::" + segment_id2 + "::interval")) & 0x7FFFFFFF
			_shared_rng.seed = seed_iv if seed_iv != 0 else 1
			_side_change_intervals[i] = _shared_rng.randf_range(30.0, 90.0)
			_side_change_timers[i] = 0.0
			
			# Обновляем цвет сегмента по новой стороне (владение с любой грани тайла)
			var face_data: Dictionary = _effective_face_data_for_ownership(segment_id2, new_side)
			var color: Color = _get_segment_color_by_side(new_side, face_data, segment_id2)
			_multimesh.set_instance_color(i, color)

# Обновление конкретного сегмента после покупки
func update_segment(segment_id: String) -> void:
	if wall_data == null or _multimesh == null:
		return
	
	# Находим индекс сегмента в массиве
	var idx: int = -1
	if _segment_index.has(segment_id):
		idx = int(_segment_index[segment_id])
	else:
		for i in range(_segment_ids.size()):
			if _segment_ids[i] == segment_id:
				idx = i
				_segment_index[segment_id] = i
				break
	
	if idx < 0 or idx >= _multimesh.instance_count:
		return
	
	# Обновляем цвет по текущей визуальной стороне; владение берём с купленной грани (если есть)
	var current_side: String = _segment_sides[idx] if idx < _segment_sides.size() else side_id
	var face_data: Dictionary = _effective_face_data_for_ownership(segment_id, current_side)
	var color: Color = _get_segment_color_by_side(current_side, face_data, segment_id)
	_multimesh.set_instance_color(idx, color)

	var img_side: String = _effective_image_side_for_texture(segment_id, current_side)
	_update_single_image_sprite(segment_id, idx, img_side)

func _get_segment_color_by_side(segment_side: String, face_data: Dictionary, segment_id: String = "") -> Color:
	# Базовый цвет по стороне сегмента (не по side_id стены!)
	var base_color: Color = _get_side_color(segment_side)
	var face_image_path: String = str(face_data.get("image_path", "")).strip_edges()
	
	# Если куплено (на текущей визуальной грани или на любой другой — см. _effective_face_data_for_ownership)
	var owner: String = str(face_data.get("owner", ""))
	var is_owned: bool = owner.strip_edges() != ""
	if is_owned:
		var owned_color: Color = Color(0.1, 0.8, 0.2)
		base_color = base_color.lerp(owned_color, 0.3)
	
	# Затемнение чужих сегментов во время предпросмотра
	if dim_other_segments and segment_id != "":
		var is_highlighted: bool = segment_id in _highlighted_segment_ids
		var gs: Node = get_node_or_null("/root/GameState")
		var buyer_uid: String = str(gs.get("player_uid")) if gs != null else ""
		var is_my_segment: bool = owner == buyer_uid
		if not is_my_segment and segment_id != "" and wall_data != null and buyer_uid != "":
			for s in SIDES:
				var ofd: Dictionary = wall_data.get_face_data(segment_id, s)
				if str(ofd.get("owner", "")) == buyer_uid:
					is_my_segment = true
					break
		
		# Если это не выделенный сегмент и не мой — затемняем
		if not is_highlighted and not is_my_segment:
			base_color = base_color.darkened(0.6)  # Затемняем на 60%
			base_color.a *= 0.4  # Уменьшаем прозрачность
	
	# Подсветка выбранных сегментов (яркий белый оттенок)
	if segment_id != "" and segment_id in _highlighted_segment_ids:
		var highlight_color: Color = Color(1.0, 1.0, 1.0, 0.8)
		base_color = base_color.lerp(highlight_color, 0.5)

	# Fail-safe: если у купленной грани есть изображение, убираем заливку,
	# чтобы даже при нестандартном порядке рендера цвет не перекрывал Sprite2D.
	if face_image_path != "":
		base_color.a = 0.0
	
	return base_color

func set_highlighted_segment(segment_id: String) -> void:
	"""Устанавливает подсветку для одного сегмента."""
	set_highlighted_segments([segment_id] if segment_id != "" else [])

func set_highlighted_segments(segment_ids: Array) -> void:
	"""Устанавливает подсветку для нескольких сегментов."""
	var new_ids: Array[String] = []
	for id_val in segment_ids:
		var s: String = str(id_val)
		if s != "" and s not in new_ids:
			new_ids.append(s)
	var old_ids: Array[String] = _highlighted_segment_ids.duplicate()
	_highlighted_segment_ids = new_ids
	for sid in old_ids:
		if sid not in new_ids:
			update_segment(sid)
	for sid in new_ids:
		update_segment(sid)

func clear_texture_cache() -> void:
	_texture_cache.clear()


func clear_highlight() -> void:
	"""Убирает подсветку со всех сегментов."""
	if _highlighted_segment_ids.is_empty() and _preview_image_paths.is_empty():
		return
	var old_ids: Array[String] = _highlighted_segment_ids.duplicate()
	_highlighted_segment_ids.clear()
	_preview_image_paths.clear()
	for sid in old_ids:
		update_segment(sid)
	_update_image_sprites()


func refresh_images_from_wall_data() -> void:
	## Вызывать после покупки / set_face_image — синхронизировать спрайты с WallData.
	clear_texture_cache()
	_update_image_sprites()
	print("[APPLY] wall image sprites refreshed from WallData (visible instances=", _multimesh.instance_count, ")")

func set_dim_other_segments(enabled: bool) -> void:
	"""Включает/выключает затемнение чужих сегментов во время предпросмотра."""
	if dim_other_segments == enabled:
		return
	dim_other_segments = enabled
	# Обновляем все видимые сегменты
	for i in range(_multimesh.instance_count):
		if i < _segment_ids.size():
			update_segment(_segment_ids[i])

func set_preview_image_paths(paths: Dictionary) -> void:
	"""Устанавливает временные пути изображений для предпросмотра (segment_id -> path). В режиме предпросмотра эти изображения отображаются на выбранных сегментах."""
	if DEBUG_LOG:
		print("WallRenderer: set_preview_image_paths вызван с ", paths.size(), " путями")
	_preview_image_paths.clear()
	for k in paths:
		var v: String = str(paths[k])
		if v != "":
			_preview_image_paths[str(k)] = v
			if DEBUG_LOG:
				print("WallRenderer: Добавлен preview путь для сегмента ", k, ": ", v)
	# Обновляем спрайты для всех видимых сегментов (не только подсвеченных, чтобы показать preview на всех нужных)
	_update_image_sprites()
	# Также обновляем подсвеченные сегменты для гарантии
	for sid in _highlighted_segment_ids:
		update_segment(sid)

func _get_side_color(segment_side: String) -> Color:
	# ВРЕМЕННАЯ ВИЗУАЛИЗАЦИЯ: разные оттенки бирюзового для каждой стороны
	match segment_side:
		"front":
			return Color(0.0, 0.8, 0.7)  # Яркий бирюзовый
		"back":
			return Color(0.0, 0.5, 0.5)  # Тёмно-бирюзовый
		"left":
			return Color(0.2, 0.7, 0.6)  # Зелёно-бирюзовый
		"right":
			return Color(0.1, 0.6, 0.8)  # Голубовато-бирюзовый
		"top":
			return Color(0.3, 0.9, 0.8)  # Светло-бирюзовый
		"bottom":
			return Color(0.0, 0.4, 0.6)  # Холодный сине-бирюзовый
		_:
			return Color(0.0, 0.8, 0.7)  # По умолчанию яркий бирюзовый

# ---------------------------------------------------------------------------
# Обработка клика по координатам (для CubeView)
# ---------------------------------------------------------------------------

# Обработка клика по координатам (для CubeView)
func handle_click(global_pos: Vector2, for_price_preview: bool = false) -> Dictionary:
	if wall_data == null:
		return {}
	if not for_price_preview and not allow_purchases:
		return {}
	
	# Преобразуем глобальные координаты в локальные относительно WallRenderer
	var local_pos: Vector2 = to_local(global_pos)
	
	# Вычисляем координаты сегмента (сегменты центрированы относительно (0,0))
	var seg_x: int = int(floor((local_pos.x + SEGMENT_SIZE * 0.5) / SEGMENT_SIZE))
	var seg_y: int = int(floor((local_pos.y + SEGMENT_SIZE * 0.5) / SEGMENT_SIZE))
	var segment_id: String = "%d_%d" % [seg_x, seg_y]
	
	# Проверяем, существует ли сегмент в видимой области
	if not _segment_index.has(segment_id):
		return {}
	
	var seg_height: float = wall_data.get_segment_height(segment_id)
	## [FIX] Превью цены для тултипа — без высотного гейта; покупка по-прежнему режется в CubeView
	var gs2: Node = get_node_or_null("/root/GameState")
	if not for_price_preview and gs2 != null:
		var gate_y: float = float(gs2.get("max_height_reached"))
		if gs2.has_method("get_wall_height_gate"):
			gate_y = float(gs2.call("get_wall_height_gate"))
		if seg_height < gate_y:
			return {}
	
	var segment_side_name: String = side_id
	if _segment_index.has(segment_id):
		var ix: int = int(_segment_index[segment_id])
		if ix >= 0 and ix < _segment_sides.size():
			segment_side_name = str(_segment_sides[ix])
	# Economy (offline): цены из economy.json; face_id стабилен при обновлении конфига
	var em: Node = get_node_or_null("/root/EconomyManager")
	var listing_price: int = int(wall_data.get_segment_price(segment_id))
	var fid: int = 0
	if em != null and em.has_method("get_listing_price_for_hit"):
		listing_price = int(em.call("get_listing_price_for_hit", side_id, segment_id, segment_side_name, wall_data))
	if em != null and em.has_method("face_id_from_wall_segment"):
		fid = int(em.call("face_id_from_wall_segment", side_id, segment_id, segment_side_name))
	return {
		"segment_id": segment_id,
		"side": side_id,
		"segment_side": segment_side_name,
		"price": listing_price,
		"height": seg_height,
		"face_id": fid
	}


## Текущая грань тайла для экономики: сначала живой инстанс, иначе последняя известная (сегмент вне видимого mesh).
func get_visible_segment_side(segment_id: String) -> String:
	if _segment_index.has(segment_id):
		var ix: int = int(_segment_index[segment_id])
		if ix >= 0 and ix < _segment_sides.size():
			return str(_segment_sides[ix])
	if _last_known_tile_side.has(segment_id):
		return str(_last_known_tile_side[segment_id])
	return ""

# ---------------------------------------------------------------------------
# Изображения сегментов (Sprite2D поверх MultiMesh)
# ---------------------------------------------------------------------------

func _get_or_create_sprite(segment_id: String) -> Sprite2D:
	if _segment_sprites.has(segment_id):
		var existing: Sprite2D = _segment_sprites[segment_id]
		if existing:
			existing.visible = true
			return existing

	var sprite: Sprite2D = null
	if _sprite_pool.size() > 0:
		sprite = _sprite_pool.pop_back()
	else:
		sprite = Sprite2D.new()
		sprite.centered = true
		sprite.name = "SegSprite_" + segment_id
		_images_layer.add_child(sprite)
	
	_segment_sprites[segment_id] = sprite
	sprite.visible = true
	return sprite

func _release_sprite(segment_id: String) -> void:
	if not _segment_sprites.has(segment_id):
		return
	var sprite: Sprite2D = _segment_sprites[segment_id]
	_segment_sprites.erase(segment_id)
	if sprite:
		sprite.visible = false
		_sprite_pool.append(sprite)

func _update_image_sprites() -> void:
	# Обновляем спрайты даже без wall_data, если есть preview-изображения
	if wall_data == null and _preview_image_paths.is_empty():
		return

	# Множество видимых сегментов
	var visible_ids: Dictionary = {}
	for seg_id in _segment_ids:
		visible_ids[seg_id] = true

	# Убираем спрайты, которые вышли из видимости
	for seg_id in _segment_sprites.keys():
		if not visible_ids.has(seg_id):
			_release_sprite(seg_id)

	# Обновляем / создаём спрайты для видимых сегментов с изображениями (из WallData или из предпросмотра)
	for i in range(_segment_ids.size()):
		var seg_id: String = _segment_ids[i]
		if i >= _segment_sides.size():
			continue
		var current_side: String = _segment_sides[i]
		var img_side: String = _effective_image_side_for_texture(seg_id, current_side)
		var img_path: String = ""
		if _preview_image_paths.has(seg_id) and _preview_image_paths[seg_id] != "":
			img_path = _preview_image_paths[seg_id]
		elif wall_data != null:
			img_path = wall_data.get_face_image_path(seg_id, img_side)
		if img_path == "":
			# Если изображение было, но больше не нужно
			if _segment_sprites.has(seg_id):
				_release_sprite(seg_id)
			continue

		_update_single_image_sprite(seg_id, i, img_side)

func _load_texture_from_path(img_path: String) -> Texture2D:
	"""Загружает текстуру из пути. Поддерживает res://, user:// и абсолютные пути (из нативного диалога). Все изображения автоматически сжимаются до 48x48 пикселей."""
	if img_path.is_empty():
		return null
	var exists_user: bool = img_path.begins_with("user://") and FileAccess.file_exists(img_path)
	if img_path.begins_with("user://"):
		print("[TEXTURE] Loading: ", img_path, " exists=", exists_user)
	
	# Избегаем повторной загрузки/ресайза одного и того же пути каждый кадр.
	if _texture_cache.has(img_path):
		var cached: Texture2D = _texture_cache[img_path]
		if cached != null:
			return cached
	
	const TARGET_SIZE: int = 48
	var img: Image = Image.new()
	var err: Error
	
	# Загружаем изображение в зависимости от типа пути
	if img_path.begins_with("res://") or img_path.begins_with("user://"):
		# Ресурсные пути Godot - пробуем загрузить как Image напрямую
		err = img.load(img_path)
		# Если не получилось, пробуем через load() как ресурс
		if err != OK:
			var resource = load(img_path)
			if resource is Texture2D:
				var tex: Texture2D = resource as Texture2D
				# Пытаемся получить Image из текстуры
				if tex is ImageTexture:
					img = (tex as ImageTexture).get_image()
				else:
					# Для других типов текстур используем загруженный ресурс как есть
					if img_path.begins_with("user://"):
						print("[TEXTURE] SUCCESS (resource Texture2D): ", img_path)
					return tex
			elif resource is Image:
				img = resource as Image
			else:
				push_warning("WallRenderer: не удалось загрузить изображение: " + img_path)
				if img_path.begins_with("user://"):
					print("[TEXTURE] FAIL: ", img_path)
				return null
	else:
		# Абсолютный путь (Windows: C:\... или Unix: /...)
		err = img.load(img_path)
		if err != OK:
			push_warning("WallRenderer: не удалось загрузить изображение: " + img_path + " (ошибка: " + str(err) + ")")
			print("[TEXTURE] FAIL: ", img_path, " err=", err)
			return null
	
	if img.is_empty():
		push_warning("WallRenderer: изображение пустое: " + img_path)
		if img_path.begins_with("user://"):
			print("[TEXTURE] FAIL empty: ", img_path)
		return null
	
	# Сжимаем до 48x48 пикселей (если размер отличается)
	var src_w: int = img.get_width()
	var src_h: int = img.get_height()
	if src_w != TARGET_SIZE or src_h != TARGET_SIZE:
		img.resize(TARGET_SIZE, TARGET_SIZE, Image.INTERPOLATE_LANCZOS)
		if DEBUG_LOG:
			print("WallRenderer: Изображение сжато до 48x48: ", img_path, " (было: ", src_w, "x", src_h, ")")
	
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_texture_cache[img_path] = tex
	if img_path.begins_with("user://"):
		print("[TEXTURE] SUCCESS: ", img_path)
	return tex

func _update_single_image_sprite(segment_id: String, idx: int, segment_side: String) -> void:
	if idx < 0 or idx >= _segment_ids.size():
		return

	# В режиме предпросмотра для подсвеченных сегментов используем загруженные картинки (одна для всех или по сегментам)
	var img_path: String = ""
	if _preview_image_paths.has(segment_id) and _preview_image_paths[segment_id] != "":
		img_path = _preview_image_paths[segment_id]
	elif wall_data != null:
		img_path = wall_data.get_face_image_path(segment_id, segment_side)

	if img_path == "":
		# Нет изображения для этой стороны
		if _segment_sprites.has(segment_id):
			_release_sprite(segment_id)
		return

	# Загружаем текстуру: load() работает только с res:// и user://;
	# нативный диалог возвращает абсолютный путь — используем Image.load_from_file()
	var tex: Texture2D = _load_texture_from_path(img_path)
	if tex == null:
		push_warning("WallRenderer: не удалось загрузить текстуру: " + img_path)
		print("[APPLY] FAIL texture segment=", segment_id, " path=", img_path)
		if _segment_sprites.has(segment_id):
			_release_sprite(segment_id)
		return
	if DEBUG_LOG:
		print("[APPLY] Applying texture to segment: ", segment_id, " path=", img_path)

	var sprite: Sprite2D = _get_or_create_sprite(segment_id)
	sprite.texture = tex

	# Устанавливаем позицию по текущему трансформу (с учётом дыхания)
	var current_transform: Transform2D
	var gs3: Node = get_node_or_null("/root/GameState")
	var breathing_enabled2: bool = gs3 != null and bool(gs3.get("wall_breathing_enabled"))
	if breathing_enabled2 and idx < _multimesh.instance_count:
		current_transform = _multimesh.get_instance_transform_2d(idx)
	else:
		current_transform = _transforms[idx]

	sprite.position = current_transform.origin
