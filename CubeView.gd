extends Node2D
# ============================================================================
# CubeView.gd
# ============================================================================
# СЦЕНА ПРОСМОТРА СТЕНЫ ВНЕ ИГРОВОГО ПРОЦЕССА

func _log(message: String) -> void:
	var logger: Node = get_node_or_null("/root/Logger")
	if logger != null and logger.has_method("log"):
		logger.call("log", message)
	else:
		print(message)
# ----------------------------------------------------------------------------
# ЗАДАЧА:
# - Показать ту же самую сцену стены, что используется в игровом уровне.
# - Не переписывать и не дублировать логику стены/сегментов.
# - Повторно использовать wall.tscn и WallSegment.gd «как есть».
# - Добавить высотный гейт (горизонтальная линия), ниже которого сегменты
#   кликабельны, а выше — клики игнорируются.
# - Обеспечить архитектуру для будущей покупки сегментов в CubeView.
# ----------------------------------------------------------------------------
# ВАЖНЫЙ КОНСТРАИНТ:
# - Рандомные повороты, дыхание и прочая «жизнь» сегментов реализованы
#   внутри WallSegment.gd и уже работают. Здесь мы НИЧЕГО в них не трогаем.
# - CubeView отвечает только за:
#   * инстанс стены
#   * установку высотного гейта
#   * ограничение кликов по сегментам выше гейта
#   * простейший UI-навигации
# ============================================================================

## Путь к сцене стены.
## ВАЖНО: это та же сцена, которая используется в игровом уровне.
@export_file("*.tscn")
var wall_scene_path: String = "res://wall/wall.tscn"

## Ссылка на инстанс сцены стены (создаётся в _ready).
var wall_instance: Node2D = null

## Нода визуальной линии-гейта (Line2D или любой другой Node2D).
## Типизировано как Node2D, потому что нас интересует только её position.y.
@onready var gate_line: Node2D = $GateLine

## UI-слой для кнопок навигации / подписей.
@onready var ui_layer: CanvasLayer = $UILayer
@onready var back_button: Button = $UILayer/Panel/VBoxContainer/BackButton
@onready var purchase_segment_button: Button = $UILayer/Panel/VBoxContainer/PurchaseSegmentButton
@onready var selection_overlay: Panel = $UILayer/SelectionOverlay
@onready var next_button: Button = $UILayer/SelectionOverlay/VBox/NextButton
@onready var cancel_selection_button: Button = $UILayer/SelectionOverlay/VBox/CancelSelectionButton
@onready var bulk_selection_overlay: Panel = $UILayer/BulkSelectionOverlay
@onready var bulk_ok_button: Button = $UILayer/BulkSelectionOverlay/VBox/OKButton
@onready var bulk_cancel_button: Button = $UILayer/BulkSelectionOverlay/VBox/CancelButton

## Выбранный сегмент (для обратной совместимости, если где-то используется)
var _selected_click_data: Dictionary = {}
## Диалог массовой покупки
var _bulk_purchase_dialog: AcceptDialog = null
## Диалог загрузки картинок для массовой покупки
var _bulk_image_upload_dialog: AcceptDialog = null
## Флаг: BulkPurchaseDialog ждёт выбор сегментов (drag)
var _bulk_selecting_location: bool = false
## Режим предпросмотра: "all" - все сразу, "one_by_one" - по очереди
var _bulk_preview_mode_type: String = "all"
## Индекс текущего сегмента в режиме "one_by_one"
var _bulk_preview_current_index: int = 0
## Drag: активен ли перетаскивание
var _bulk_drag_active: bool = false
## Выбранные ID при drag
var _bulk_selected_ids: Array[String] = []
## Режим предпросмотра bulk (OK = вернуться в диалог)
var _bulk_preview_mode: bool = false
## Режим предпросмотра single (больше не используется, оставлено для совместимости)
var _single_preview_mode: bool = false

## Высота-гейт по Y в мировых координатах CubeView.
## Сегменты с global_position.y > gate_y считаются НИЖЕ линии (доступны),
## а с y <= gate_y — ВЫШЕ линии (клики игнорируются).
var gate_y: float = 0.0

## Флаг разрешения покупок (включается в _ready)
var allow_purchases: bool = true

## Диалог покупки сегмента (больше не используется, оставлено для совместимости)
var purchase_dialog: AcceptDialog = null

## Текущая сторона для просмотра в CubeView (читается из GameState)
var current_side: String = "front"

## Переменные для перетаскивания камеры
var _dragging_camera: bool = false
var _last_drag_pos: Vector2 = Vector2.ZERO

## Мини-карта
var minimap_camera: Camera2D = null


func _ready() -> void:
	_log("[CUBEVIEW] _ready")
	# ------------------------------------------------------------
	# 1. Инстанс существующей сцены стены.
	# ------------------------------------------------------------
	# Загружаем wall.tscn и включаем покупки (allow_purchases = true)
	# ------------------------------------------------------------
	if wall_scene_path == "":
		push_error("CubeView.gd: wall_scene_path is empty")
		_log("[CUBEVIEW] ERROR - wall_scene_path is empty")
	else:
		_log("[CUBEVIEW] loading wall scene: %s" % wall_scene_path)
		# Тип res указываем явно как Resource, затем кастуем к PackedScene.
		# Это безопасно, т.к. мы знаем, что wall_scene_path указывает на .tscn.
		var res: Resource = load(wall_scene_path)
		var packed: PackedScene = res as PackedScene
		if packed != null:
			var inst: Node = packed.instantiate()
			# Дополнительно убеждаемся, что это именно Node2D.
			wall_instance = inst as Node2D
			if wall_instance != null:
				add_child(wall_instance)
				# Для наглядности центрируем стену около (0,0) CubeView.
				wall_instance.position = Vector2.ZERO
				_log("[CUBEVIEW] wall_instance added successfully")
				
				# ВКЛЮЧАЕМ покупки для CubeView
				wall_instance.allow_purchases = true
				# Также обновляем рендерер если он уже создан
				call_deferred("_enable_purchases_in_renderer")
			else:
				_log("[CUBEVIEW] ERROR - wall_instance is null after instantiate")
		else:
			push_error("CubeView.gd: cannot load wall scene as PackedScene: " + wall_scene_path)
			_log("[CUBEVIEW] ERROR - cannot load as PackedScene: %s" % wall_scene_path)

	# ------------------------------------------------------------
	# 2. Настройка UI-навигации.
	# ------------------------------------------------------------
	# UI здесь минимальный:
	# - BackButton возвращает игрока в главное меню.
	# - В будущем сюда можно добавить:
	#   * информацию о высоте
	#   * баланс монет
	#   * кнопки фильтров / сортировки сегментов
	# ------------------------------------------------------------
	if back_button != null and not back_button.pressed.is_connected(_on_back_button_pressed):
		back_button.pressed.connect(_on_back_button_pressed)
	if purchase_segment_button != null:
		purchase_segment_button.pressed.connect(_on_purchase_segment_pressed)
	if next_button != null:
		next_button.pressed.connect(_on_selection_next_pressed)
	if cancel_selection_button != null:
		cancel_selection_button.pressed.connect(_on_selection_cancel_pressed)
	if bulk_ok_button != null:
		bulk_ok_button.pressed.connect(_on_bulk_selection_ok_pressed)
	if bulk_cancel_button != null:
		bulk_cancel_button.pressed.connect(_on_bulk_selection_cancel_pressed)

	# ------------------------------------------------------------
	# 3. Вычисляем высоту-гейт на основе GameState.
	# ------------------------------------------------------------
	# Архитектурно здесь предполагается, что:
	# - GameState хранит максимальную достигнутую высоту игрока в world-space.
	# - Для упрощения считаем, что ось Y такая же, как в Level:
	#   * чем МЕНЬШЕ y, тем ВЫШЕ игрок находится.
	#   * max_height_reached / max_height_reached (у нас max_height_reached) —
	#     минимальное значение y, которого достигал игрок (самая верхняя точка).
	# В этом коде мы читаем поле GameState.max_height_reached через get().
	# Если оно пока не задано или не является числом, просто ставим гейт
	# немного выше центра (условное значение -200).
	# ------------------------------------------------------------
	var has_gs: bool = Engine.has_singleton("GameState")
	if has_gs and GameState.has_method("get"):
		# Тип v объявлен как Variant, т.к. метод get() может вернуть что угодно.
		var v: Variant = GameState.get("max_height_reached")
		if v is float or v is int:
			gate_y = float(v)
			_log("[CUBEVIEW] gate_y from GameState: %.1f" % gate_y)
		else:
			gate_y = -200.0
			_log("[CUBEVIEW] gate_y default (GameState value invalid): %.1f" % gate_y)
	else:
		gate_y = -200.0
		_log("[CUBEVIEW] gate_y default (no GameState): %.1f" % gate_y)

	# В этом прототипе мы НИКАК не модифицируем GameState;
	# предполагается, что игровая сцена уже обновляет max_height_reached.

	# ------------------------------------------------------------
	# 4. Размещаем визуальную линию-гейт.
	# ------------------------------------------------------------
	# Мы считаем, что GateLine — это Line2D под корнем CubeView
	# с точками, заданными относительно её локальной позиции:
	#   ( -10000, 0 ) .. ( 10000, 0 )
	# Тогда её global Y = position.y. Мы просто ставим её на gate_y.
	# ------------------------------------------------------------
	if gate_line != null:
		gate_line.position.y = gate_y

	# ------------------------------------------------------------
	# 5. Подключаем обработку кликов для покупки сегментов.
	# ------------------------------------------------------------
	# Теперь клики обрабатываются через handle_click() в wall.gd,
	# который использует координаты вместо Area2D на каждый сегмент.
	# Высотный гейт проверяется внутри handle_click()
	# ------------------------------------------------------------
	_enable_purchases_in_renderer()
	
	# ------------------------------------------------------------
	# 6. Создаём диалоги покупки.
	# ------------------------------------------------------------
		# PurchaseDialog больше не используется - покупка только через BulkPurchaseDialog

	# ------------------------------------------------------------
	# 7. Читаем активную сторону мегакуба из GameState.
	# ------------------------------------------------------------
	if Engine.has_singleton("GameState") and GameState.has_method("get_active_wall_side"):
		current_side = GameState.get_active_wall_side()
	
	# ------------------------------------------------------------
	# 8. Настраиваем мини-карту.
	# ------------------------------------------------------------
	_setup_minimap()


func _is_over_selection_ui(screen_pos: Vector2) -> bool:
	# Блокируем клики по стене, если курсор/тап находится над оверлеями выбора.
	for overlay in [selection_overlay, bulk_selection_overlay]:
		if overlay and overlay.visible and overlay is Control:
			var rect: Rect2 = (overlay as Control).get_global_rect()
			if rect.has_point(screen_pos):
				return true
	return false

func _setup_minimap() -> void:
	"""Настраивает мини-карту для отображения структуры стены."""
	var minimap_panel = get_node_or_null("UILayer/MinimapPanel")
	if minimap_panel:
		var minimap_viewport = minimap_panel.get_node_or_null("MinimapViewport")
		var minimap_label: Label = minimap_panel.get_node_or_null("MinimapLabel")
		if minimap_viewport:
			minimap_camera = minimap_viewport.get_node_or_null("MinimapCamera")
			if minimap_camera:
				# Устанавливаем зум мини-карты для обзора всей стены
				minimap_camera.zoom = Vector2(50.0, 50.0)  # Масштаб для обзора всей стены
			
			# Добавляем инстанс стены в мини-карту для визуализации
			# Используем RemoteTransform2D для синхронизации с основной стеной
			if wall_instance:
				# Создаём RemoteTransform2D для синхронизации позиции стены
				var remote_transform = RemoteTransform2D.new()
				remote_transform.name = "MinimapRemoteTransform"
				remote_transform.update_position = true
				remote_transform.update_rotation = false
				remote_transform.update_scale = false
				wall_instance.add_child(remote_transform)
				remote_transform.remote_path = minimap_camera.get_path()
				
				# Также добавляем простую визуализацию стены в мини-карту
				# Создаём упрощённую версию стены для мини-карты
				call_deferred("_add_minimap_wall_visualization", minimap_viewport)
		
		# Обновляем подпись мини-карты базовой информацией о стороне
		if minimap_label and Engine.has_singleton("GameState"):
			var side := GameState.get_active_wall_side()
			minimap_label.text = "Мини-карта\nСторона: %s" % side

func _add_minimap_wall_visualization(minimap_viewport: SubViewport) -> void:
	"""Добавляет упрощённую визуализацию стены в мини-карту."""
	if not minimap_viewport or not wall_instance:
		return
	
	# Создаём Node2D для рисования мини-карты
	var minimap_drawer = Node2D.new()
	minimap_drawer.name = "MinimapDrawer"
	minimap_drawer.set_script(preload("res://scripts/MinimapDrawer.gd"))
	minimap_viewport.add_child(minimap_drawer)
	
	# Передаём ссылку на wall_data для отрисовки
	if wall_instance.has_node("WallData"):
		var wall_data = wall_instance.get_node("WallData") as WallData
		if minimap_drawer.has_method("setup"):
			minimap_drawer.setup(wall_data)

func _process(_delta: float) -> void:
	# Обновляем позицию камеры мини-карты синхронно с основной камерой
	if minimap_camera:
		var main_camera: Camera2D = get_node_or_null("Camera2D")
		if main_camera:
			minimap_camera.position = main_camera.position
			
			# Обновляем позицию индикатора камеры в мини-карте (рисуем через _draw)
			var minimap_viewport = minimap_camera.get_parent()
			if minimap_viewport:
				var minimap_drawer = minimap_viewport.get_node_or_null("MinimapDrawer")
				if minimap_drawer and minimap_drawer.has_method("set_camera_position"):
					minimap_drawer.set_camera_position(main_camera.position)
	
	# Обновляем подпись мини-карты числом купленных сегментов (инфо вместо пустого квадрата)
	var minimap_panel = get_node_or_null("UILayer/MinimapPanel")
	if minimap_panel and wall_instance and wall_instance.has_node("WallData"):
		var minimap_label: Label = minimap_panel.get_node_or_null("MinimapLabel")
		if minimap_label:
			var wall_data: WallData = wall_instance.get_node("WallData") as WallData
			var side: String = current_side
			if Engine.has_singleton("GameState"):
				side = GameState.get_active_wall_side()
			var owned_count := 0
			var total_count := wall_data.segments.size()
			for seg_id in wall_data.segments.keys():
				var face_data: Dictionary = wall_data.get_face_data(seg_id, side)
				if str(face_data.get("owner", "")) != "":
					owned_count += 1
			minimap_label.text = "Мини-карта\nСторона: %s\nКуплено: %d\nВсего: %d" % [side, owned_count, total_count]

func _enable_purchases_in_renderer() -> void:
	if wall_instance == null:
		return
	wall_instance.allow_purchases = true
	# Ищем рендерер среди всех детей (может быть создан позже)
	for child in wall_instance.get_children():
		if child is WallRenderer:
			child.allow_purchases = true


func _input(event: InputEvent) -> void:
	# Обработка зума камеры (колесо мыши)
	if event is InputEventMouseButton:
		var camera: Camera2D = get_node_or_null("Camera2D")
		if camera:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				camera.zoom = camera.zoom * 0.9
				camera.zoom = clamp(camera.zoom, Vector2(0.1, 0.1), Vector2(5.0, 5.0))
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				camera.zoom = camera.zoom * 1.1
				camera.zoom = clamp(camera.zoom, Vector2(0.1, 0.1), Vector2(5.0, 5.0))
				get_viewport().set_input_as_handled()

	# Пинч-зум на мобильных / трекпадах (InputEventMagnifyGesture)
	if event is InputEventMagnifyGesture:
		var camera: Camera2D = get_node_or_null("Camera2D")
		if camera:
			# factor > 1.0 — «раздвигаем» пальцы (увеличиваем),
			# factor < 1.0 — «сводим» (уменьшаем масштаб).
			var factor: float = (event as InputEventMagnifyGesture).factor
			# Инвертируем фактор, чтобы раздвижение уменьшало zoom (приближение).
			if factor != 0.0:
				camera.zoom /= factor
				camera.zoom = clamp(camera.zoom, Vector2(0.1, 0.1), Vector2(5.0, 5.0))
				get_viewport().set_input_as_handled()
	
	# Обработка перетаскивания камеры (правая кнопка мыши или тач)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_dragging_camera = true
			_last_drag_pos = event.position
		else:
			_dragging_camera = false
		get_viewport().set_input_as_handled()
	
	if event is InputEventMouseMotion:
		if _dragging_camera:
			var camera: Camera2D = get_node_or_null("Camera2D")
			if camera:
				var delta: Vector2 = event.position - _last_drag_pos
				camera.position -= delta / camera.zoom
				_last_drag_pos = event.position
			get_viewport().set_input_as_handled()
		elif _bulk_drag_active and _bulk_selecting_location and wall_instance:
			var camera: Camera2D = get_node_or_null("Camera2D")
			var viewport: Viewport = get_viewport()
			var world_pos: Vector2 = camera.get_global_mouse_position() if camera else viewport.get_global_mouse_position()
			var click_data: Dictionary = wall_instance.handle_click(world_pos)
			if not click_data.is_empty():
				var seg_height: float = float(click_data.get("height", 0.0))
				if seg_height >= gate_y:
					var seg_id: String = str(click_data.get("segment_id", ""))
					if seg_id != "" and seg_id not in _bulk_selected_ids:
						_bulk_selected_ids.append(seg_id)
					wall_instance.set_highlighted_segments(_bulk_selected_ids)
					if bulk_ok_button:
						bulk_ok_button.disabled = _bulk_selected_ids.is_empty()
			get_viewport().set_input_as_handled()
	
	# Обработка кликов для покупки/выбора сегментов
	if not allow_purchases:
		return
	# Обрабатываем клики только в режиме bulk selection (single purchase mode удалён)
	if not _bulk_selecting_location:
		return
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Не пропускаем клики по интерактивным панелям (они не должны трогать стену)
		if _is_over_selection_ui(event.position):
			return
		if wall_instance == null:
			return
		
		var camera: Camera2D = get_node_or_null("Camera2D")
		var viewport: Viewport = get_viewport()
		var world_pos: Vector2 = camera.get_global_mouse_position() if camera else viewport.get_global_mouse_position()
		var click_data: Dictionary = wall_instance.handle_click(world_pos)
		
		if _bulk_selecting_location and _bulk_purchase_dialog:
			if event.pressed:
				_bulk_drag_active = true
			else:
				_bulk_drag_active = false
				if _bulk_selected_ids.size() > 0:
					_bulk_purchase_dialog.set_selected_segments(_bulk_selected_ids)
					if bulk_ok_button:
						bulk_ok_button.disabled = false
			if not click_data.is_empty():
				var seg_height: float = float(click_data.get("height", 0.0))
				if seg_height >= gate_y:
					var seg_id: String = str(click_data.get("segment_id", ""))
					if seg_id != "" and seg_id not in _bulk_selected_ids:
						_bulk_selected_ids.append(seg_id)
					if wall_instance:
						wall_instance.set_highlighted_segments(_bulk_selected_ids)
					if bulk_ok_button:
						bulk_ok_button.disabled = _bulk_selected_ids.is_empty()
			get_viewport().set_input_as_handled()
			return
		
		if not event.pressed:
			return
		if click_data.is_empty():
			return
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			return
		
		# Клики по стене обрабатываются только в режиме bulk selection
		# Если не в режиме выбора, игнорируем клики
	
	elif event is InputEventScreenDrag and _bulk_drag_active and _bulk_selecting_location and wall_instance:
		var camera: Camera2D = get_node_or_null("Camera2D")
		var viewport: Viewport = get_viewport()
		var world_pos: Vector2 = camera.get_global_mouse_position() if camera else viewport.get_global_mouse_position()
		var click_data: Dictionary = wall_instance.handle_click(world_pos)
		if not click_data.is_empty():
			var seg_height: float = float(click_data.get("height", 0.0))
			if seg_height >= gate_y:
				var seg_id: String = str(click_data.get("segment_id", ""))
				if seg_id != "" and seg_id not in _bulk_selected_ids:
					_bulk_selected_ids.append(seg_id)
				wall_instance.set_highlighted_segments(_bulk_selected_ids)
				if bulk_ok_button:
					bulk_ok_button.disabled = _bulk_selected_ids.is_empty()
		get_viewport().set_input_as_handled()
	
	elif event is InputEventScreenTouch:
		# Тапы по UI‑панелям не должны кликать по стене
		if _is_over_selection_ui(event.position):
			return
		if wall_instance == null:
			return
		var camera: Camera2D = get_node_or_null("Camera2D")
		var viewport: Viewport = get_viewport()
		var world_pos: Vector2 = camera.get_global_mouse_position() if camera else viewport.get_global_mouse_position()
		var click_data: Dictionary = wall_instance.handle_click(world_pos)
		
		if _bulk_selecting_location and _bulk_purchase_dialog:
			if event.pressed:
				_bulk_drag_active = true
			else:
				_bulk_drag_active = false
				if _bulk_selected_ids.size() > 0:
					_bulk_purchase_dialog.set_selected_segments(_bulk_selected_ids)
					if bulk_ok_button:
						bulk_ok_button.disabled = false
			if not click_data.is_empty():
				var seg_height: float = float(click_data.get("height", 0.0))
				if seg_height >= gate_y:
					var seg_id: String = str(click_data.get("segment_id", ""))
					if seg_id != "" and seg_id not in _bulk_selected_ids:
						_bulk_selected_ids.append(seg_id)
					wall_instance.set_highlighted_segments(_bulk_selected_ids)
					if bulk_ok_button:
						bulk_ok_button.disabled = _bulk_selected_ids.is_empty()
			get_viewport().set_input_as_handled()
			return
		
		if not event.pressed:
			return
		if click_data.is_empty():
			return
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			return
		# Клики по стене обрабатываются только в режиме bulk selection
		# Если не в режиме выбора, игнорируем клики

func _create_purchase_dialog() -> void:
	"""Создаёт и настраивает диалог покупки сегмента."""
	var dialog_scene_path = "res://PurchaseDialog.tscn"
	
	# Проверяем, существует ли файл
	if not ResourceLoader.exists(dialog_scene_path):
		push_error("CubeView: файл сцены не существует: " + dialog_scene_path)
		return
	
	# Загружаем сцену
	var dialog_scene = load(dialog_scene_path) as PackedScene
	if dialog_scene == null:
		push_error("CubeView: не удалось загрузить сцену диалога как PackedScene: " + dialog_scene_path)
		var res = load(dialog_scene_path)
		if res:
			push_error("CubeView: загружен ресурс типа: " + str(res.get_class()) + ", но не PackedScene")
		else:
			push_error("CubeView: ресурс не загружен вообще")
		return
	
	# Пытаемся создать инстанс с обработкой ошибок
	# В Godot 4 instantiate() может вернуть null если есть ошибки в _ready() скрипта
	var instanced: Node = null
	
	# Используем call_deferred для безопасного создания
	# Но сначала попробуем обычный способ
	instanced = dialog_scene.instantiate()
	
	if instanced == null:
		push_error("CubeView: instantiate() вернул null для сцены: " + dialog_scene_path)
		print("CubeView: это может быть из-за ошибки в PurchaseDialog.gd при создании")
		print("CubeView: попробуем создать диалог программно без сцены...")
		
		# Создаём диалог программно как fallback
		purchase_dialog = AcceptDialog.new()
		purchase_dialog.dialog_text = "Покупка сегмента стены"
		purchase_dialog.name = "PurchaseDialog"
		
		# Загружаем скрипт и применяем его
		var script_path = "res://PurchaseDialog.gd"
		if ResourceLoader.exists(script_path):
			var script = load(script_path) as GDScript
			if script:
				purchase_dialog.set_script(script)
				print("CubeView: скрипт применён к программно созданному диалогу")
			else:
				push_error("CubeView: не удалось загрузить скрипт PurchaseDialog.gd")
				purchase_dialog.queue_free()
				purchase_dialog = null
				return
		else:
			push_error("CubeView: скрипт PurchaseDialog.gd не найден")
			purchase_dialog.queue_free()
			purchase_dialog = null
			return
		
		# Добавляем к корню сцены
		var scene_root = get_tree().root
		if scene_root:
			scene_root.add_child(purchase_dialog)
			print("CubeView: программно созданный диалог добавлен к корню")
		else:
			purchase_dialog.queue_free()
			purchase_dialog = null
			return
		
		# Подключаем сигналы
		if purchase_dialog.has_signal("purchase_confirmed"):
			purchase_dialog.purchase_confirmed.connect(_on_purchase_confirmed)
		if purchase_dialog.has_signal("preview_requested"):
			purchase_dialog.preview_requested.connect(_on_single_preview_requested)
		
		# Вызываем _ready() вручную после добавления в дерево
		call_deferred("_init_purchase_dialog_ui")
		return
	
	print("CubeView: создан инстанс диалога, тип: ", instanced.get_class())
	print("CubeView: является ли AcceptDialog? ", instanced is AcceptDialog)
	print("CubeView: является ли Window? ", instanced is Window)
	
	# В Godot 4 AcceptDialog наследуется от Window
	if instanced is AcceptDialog:
		purchase_dialog = instanced as AcceptDialog
	elif instanced is Window:
		# Попробуем привести Window к AcceptDialog
		purchase_dialog = instanced as AcceptDialog
		if purchase_dialog == null:
			push_error("CubeView: инстанс является Window, но не AcceptDialog")
			instanced.queue_free()
			return
	else:
		push_error("CubeView: инстанс диалога не является AcceptDialog или Window, тип: " + str(instanced.get_class()))
		instanced.queue_free()
		return
	
	# В Godot 4 AcceptDialog - это Window, добавляем его к корню сцены
	# Window должен быть добавлен к root Viewport, а не к обычному узлу
	var scene_root = get_tree().root
	if scene_root:
		scene_root.add_child(purchase_dialog)
		print("CubeView: диалог добавлен к корню сцены (root)")
		print("CubeView: диалог в дереве? ", purchase_dialog.is_inside_tree())
	else:
		push_error("CubeView: не удалось получить корень сцены!")
		purchase_dialog.queue_free()
		purchase_dialog = null
		return
	
	# Подключаем сигналы
	if purchase_dialog.has_signal("purchase_confirmed"):
		purchase_dialog.purchase_confirmed.connect(_on_purchase_confirmed)
	if purchase_dialog.has_signal("preview_requested"):
		purchase_dialog.preview_requested.connect(_on_single_preview_requested)
		print("CubeView: сигнал purchase_confirmed подключён")
	else:
		push_warning("CubeView: диалог не имеет сигнала purchase_confirmed")
		print("CubeView: доступные сигналы: ", purchase_dialog.get_signal_list())

func _on_purchase_segment_pressed() -> void:
	"""Кнопка «Купить сегмент» → сразу открывает диалог покупки нескольких сегментов."""
	_show_bulk_purchase_dialog()

func _on_selection_next_pressed() -> void:
	"""Кнопка «Далее» — возврат из предпросмотра."""
	if _single_preview_mode:
		_single_preview_mode = false
		if wall_instance:
			wall_instance.set_pause_side_switching(false)
			wall_instance.set_dim_other_segments(false)
			wall_instance.clear_highlight()
		selection_overlay.visible = false
		if next_button:
			next_button.disabled = true
			next_button.text = "Далее"
		# Single purchase mode удалён - эта функция теперь только для предпросмотра

func _on_selection_cancel_pressed() -> void:
	"""Отмена предпросмотра."""
	if _single_preview_mode:
		_single_preview_mode = false
		if wall_instance:
			wall_instance.set_pause_side_switching(false)
			wall_instance.set_dim_other_segments(false)
			wall_instance.clear_highlight()
		selection_overlay.visible = false
		if next_button:
			next_button.disabled = true
			next_button.text = "Далее"
		# Single purchase mode удалён - эта функция теперь только для предпросмотра

func _exit_purchase_mode() -> void:
	"""Выход из режима выбора, сброс UI."""
	_selected_click_data = {}
	if wall_instance:
		wall_instance.clear_highlight()
		wall_instance.set_pause_side_switching(false)
	if selection_overlay:
		selection_overlay.visible = false
	if next_button:
		next_button.disabled = true

func _show_bulk_purchase_dialog() -> void:
	"""Показывает диалог покупки нескольких сегментов."""
	if _bulk_purchase_dialog == null:
		if ResourceLoader.exists("res://BulkPurchaseDialog.tscn"):
			var scene = load("res://BulkPurchaseDialog.tscn") as PackedScene
			if scene:
				var inst = scene.instantiate()
				if inst is AcceptDialog:
					_bulk_purchase_dialog = inst as AcceptDialog
					get_tree().root.add_child(_bulk_purchase_dialog)
					if _bulk_purchase_dialog.has_signal("purchase_confirmed"):
						_bulk_purchase_dialog.purchase_confirmed.connect(_on_bulk_purchase_confirmed)
					if _bulk_purchase_dialog.has_signal("location_selection_started"):
						_bulk_purchase_dialog.location_selection_started.connect(_on_bulk_location_selection_started)
					if _bulk_purchase_dialog.has_signal("preview_requested"):
						_bulk_purchase_dialog.preview_requested.connect(_on_bulk_preview_requested)
					if _bulk_purchase_dialog.has_signal("images_upload_requested"):
						_bulk_purchase_dialog.images_upload_requested.connect(_on_bulk_images_upload_requested)
					_bulk_purchase_dialog.visibility_changed.connect(_on_bulk_dialog_visibility_changed)
	if _bulk_purchase_dialog:
		var wdata: WallData = null
		if wall_instance and wall_instance.has_node("WallData"):
			wdata = wall_instance.get_node("WallData") as WallData
		if _bulk_purchase_dialog.has_method("setup"):
			_bulk_purchase_dialog.setup(wdata, current_side)
		_bulk_purchase_dialog.popup_centered(Vector2(450, 500))

func _on_bulk_location_selection_started() -> void:
	"""Выбрать на карте: закрываем диалог, показываем карту, drag-выбор."""
	if _bulk_purchase_dialog:
		_bulk_purchase_dialog.hide()
	_bulk_selecting_location = true
	_bulk_drag_active = false
	_bulk_selected_ids.clear()
	if wall_instance:
		wall_instance.set_pause_side_switching(true)
	if bulk_selection_overlay:
		bulk_selection_overlay.visible = true
		var hint = bulk_selection_overlay.get_node_or_null("VBox/HintLabel")
		if hint is Label:
			(hint as Label).text = "Зажмите и ведите для выбора нескольких сегментов"
	if bulk_ok_button:
		bulk_ok_button.disabled = true

func _on_bulk_selection_ok_pressed() -> void:
	"""OK — возвращаемся в диалог (после выбора или предпросмотра)."""
	_bulk_selecting_location = false
	_bulk_drag_active = false
	_bulk_preview_mode = false
	if wall_instance:
		wall_instance.set_pause_side_switching(false)
		wall_instance.clear_highlight()
		wall_instance.set_dim_other_segments(false)  # Выключаем затемнение
	if bulk_selection_overlay:
		bulk_selection_overlay.visible = false
	if bulk_ok_button:
		bulk_ok_button.disabled = true
	if _bulk_purchase_dialog:
		_bulk_purchase_dialog.popup_centered(Vector2(450, 500))

func _on_bulk_selection_cancel_pressed() -> void:
	"""Отмена — сбрасываем и возвращаемся в диалог."""
	_bulk_selecting_location = false
	_bulk_drag_active = false
	_bulk_preview_mode = false
	if wall_instance:
		wall_instance.set_pause_side_switching(false)
		wall_instance.set_dim_other_segments(false)  # Выключаем затемнение
	if bulk_selection_overlay:
		bulk_selection_overlay.visible = false
	if bulk_ok_button:
		bulk_ok_button.disabled = true
	if wall_instance:
		wall_instance.clear_highlight()
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("setup"):
		var wall_data: WallData = null
		if wall_instance and wall_instance.has_node("WallData"):
			wall_data = wall_instance.get_node("WallData") as WallData
		_bulk_purchase_dialog.setup(wall_data, current_side)
		_bulk_purchase_dialog.popup_centered(Vector2(450, 500))

func _on_bulk_dialog_visibility_changed() -> void:
	if _bulk_purchase_dialog and not _bulk_purchase_dialog.visible:
		_bulk_selecting_location = false
		_bulk_drag_active = false
		if wall_instance:
			wall_instance.set_pause_side_switching(false)
		if bulk_selection_overlay:
			bulk_selection_overlay.visible = false

func _on_bulk_preview_requested() -> void:
	"""Показать предпросмотр выбранных сегментов на карте."""
	if _bulk_purchase_dialog == null or not _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		return
	var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
	if ids.is_empty():
		return
	_bulk_purchase_dialog.hide()
	_bulk_preview_mode = true
	_bulk_preview_mode_type = "all"  # По умолчанию показываем все сразу
	_bulk_preview_current_index = 0
	
	if wall_instance:
		wall_instance.set_pause_side_switching(true)
		wall_instance.set_dim_other_segments(true)
		var arr: Array[String] = []
		for id_val in ids:
			arr.append(str(id_val))
		wall_instance.set_highlighted_segments(arr)
		# Передаём загруженные картинки для предпросмотра (одна для всех или по сегментам)
		if _bulk_purchase_dialog.has_method("get_preview_image_paths"):
			var paths: Dictionary = _bulk_purchase_dialog.get_preview_image_paths()
			if not paths.is_empty():
				wall_instance.set_preview_image_paths(paths)
	
	# Центрируем камеру на выбранных сегментах (segment_id = "x_y", размер 48)
	var cam: Camera2D = get_node_or_null("Camera2D")
	if cam and ids.size() > 0:
		var sum_x: float = 0.0
		var sum_y: float = 0.0
		for id_val in ids:
			var parts: PackedStringArray = str(id_val).split("_")
			if parts.size() >= 2:
				sum_x += float(parts[0]) * 48.0 + 24.0
				sum_y += float(parts[1]) * 48.0 + 24.0
		cam.position = Vector2(sum_x / ids.size(), sum_y / ids.size())
	if wall_instance and wall_instance.has_method("_update_visible_segments"):
		wall_instance.call_deferred("_update_visible_segments")
	
	bulk_selection_overlay.visible = true
	var hint = bulk_selection_overlay.get_node_or_null("VBox/HintLabel")
	if hint is Label:
		(hint as Label).text = "Предпросмотр: %d сегментов\n[Все сразу / По очереди]" % ids.size()
	
	# Добавляем кнопки переключения режима предпросмотра если их нет
	var mode_buttons = bulk_selection_overlay.get_node_or_null("VBox/ModeButtons")
	if not mode_buttons:
		mode_buttons = HBoxContainer.new()
		mode_buttons.name = "ModeButtons"
		var vbox = bulk_selection_overlay.get_node_or_null("VBox")
		if vbox:
			vbox.add_child(mode_buttons)
			var all_btn = Button.new()
			all_btn.text = "Все сразу"
			all_btn.pressed.connect(_on_preview_all_pressed)
			mode_buttons.add_child(all_btn)
			var one_by_one_btn = Button.new()
			one_by_one_btn.text = "По очереди"
			one_by_one_btn.pressed.connect(_on_preview_one_by_one_pressed)
			mode_buttons.add_child(one_by_one_btn)
			var next_seg_btn = Button.new()
			next_seg_btn.name = "NextSegmentButton"
			next_seg_btn.text = "Следующий"
			next_seg_btn.pressed.connect(_on_preview_next_segment_pressed)
			next_seg_btn.visible = false
			mode_buttons.add_child(next_seg_btn)
	
	bulk_ok_button.disabled = false
	_bulk_selecting_location = false
	_bulk_drag_active = false

func _on_preview_all_pressed() -> void:
	"""Режим предпросмотра: все сегменты сразу."""
	_bulk_preview_mode_type = "all"
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
		var arr: Array[String] = []
		for id_val in ids:
			arr.append(str(id_val))
		if wall_instance:
			wall_instance.set_highlighted_segments(arr)
			# Обновляем preview изображения для всех сегментов
			if _bulk_purchase_dialog.has_method("get_preview_image_paths"):
				var paths: Dictionary = _bulk_purchase_dialog.get_preview_image_paths()
				if not paths.is_empty():
					wall_instance.set_preview_image_paths(paths)
	var next_btn = bulk_selection_overlay.get_node_or_null("VBox/ModeButtons/NextSegmentButton")
	if next_btn:
		next_btn.visible = false

func _on_preview_one_by_one_pressed() -> void:
	"""Режим предпросмотра: по одному сегменту."""
	_bulk_preview_mode_type = "one_by_one"
	_bulk_preview_current_index = 0
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
		if ids.size() > 0:
			if wall_instance:
				var current_id: String = str(ids[_bulk_preview_current_index])
				wall_instance.set_highlighted_segments([current_id])
				# Обновляем preview изображение для текущего сегмента
				if _bulk_purchase_dialog.has_method("get_preview_image_paths"):
					var all_paths: Dictionary = _bulk_purchase_dialog.get_preview_image_paths()
					var current_paths: Dictionary = {}
					if all_paths.has(current_id):
						current_paths[current_id] = all_paths[current_id]
					wall_instance.set_preview_image_paths(current_paths)
	var next_btn = bulk_selection_overlay.get_node_or_null("VBox/ModeButtons/NextSegmentButton")
	if next_btn:
		next_btn.visible = true

func _on_preview_next_segment_pressed() -> void:
	"""Переход к следующему сегменту в режиме 'по очереди'."""
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
		_bulk_preview_current_index = (_bulk_preview_current_index + 1) % ids.size()
		if wall_instance:
			var current_id: String = str(ids[_bulk_preview_current_index])
			wall_instance.set_highlighted_segments([current_id])
			# Обновляем preview изображение для текущего сегмента
			if _bulk_purchase_dialog.has_method("get_preview_image_paths"):
				var all_paths: Dictionary = _bulk_purchase_dialog.get_preview_image_paths()
				var current_paths: Dictionary = {}
				if all_paths.has(current_id):
					current_paths[current_id] = all_paths[current_id]
				wall_instance.set_preview_image_paths(current_paths)

func _on_bulk_images_upload_requested() -> void:
	"""Открывает диалог загрузки изображений для массовой покупки."""
	if _bulk_purchase_dialog == null or not _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		return
	var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
	if ids.is_empty():
		return
	
	# Закрываем BulkPurchaseDialog перед открытием BulkImageUploadDialog, чтобы избежать конфликта эксклюзивных окон
	if _bulk_purchase_dialog:
		_bulk_purchase_dialog.hide()
	
	if _bulk_image_upload_dialog == null:
		if ResourceLoader.exists("res://BulkImageUploadDialog.tscn"):
			var scene = load("res://BulkImageUploadDialog.tscn") as PackedScene
			if scene:
				var inst = scene.instantiate()
				if inst is AcceptDialog:
					_bulk_image_upload_dialog = inst as AcceptDialog
					get_tree().root.add_child(_bulk_image_upload_dialog)
					if _bulk_image_upload_dialog.has_signal("images_selected"):
						_bulk_image_upload_dialog.images_selected.connect(_on_bulk_images_selected)
					if _bulk_image_upload_dialog.has_signal("single_image_selected"):
						_bulk_image_upload_dialog.single_image_selected.connect(_on_bulk_single_image_selected)
					# Подключаем сигнал закрытия для возврата к BulkPurchaseDialog
					if _bulk_image_upload_dialog.has_signal("visibility_changed"):
						_bulk_image_upload_dialog.visibility_changed.connect(_on_bulk_image_upload_dialog_visibility_changed)
	
	if _bulk_image_upload_dialog and _bulk_image_upload_dialog.has_method("setup"):
		var side_id: String = current_side
		if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("get_selected_side"):
			side_id = str(_bulk_purchase_dialog.get_selected_side())
		_bulk_image_upload_dialog.setup(ids, side_id)
		# Используем call_deferred чтобы убедиться, что BulkPurchaseDialog закрыт
		call_deferred("_show_bulk_image_upload_dialog")

func _show_bulk_image_upload_dialog() -> void:
	"""Показывает диалог загрузки изображений."""
	if _bulk_image_upload_dialog:
		# Размер диалога устанавливается внутри самого диалога через _update_dialog_size()
		# Используем фиксированную ширину 700px и высоту из диалога
		_bulk_image_upload_dialog.popup_centered(Vector2(700, 600))

func _on_bulk_image_upload_dialog_visibility_changed() -> void:
	"""Обрабатывает изменение видимости диалога загрузки изображений."""
	if _bulk_image_upload_dialog and not _bulk_image_upload_dialog.visible:
		# Когда диалог закрывается, возвращаемся к BulkPurchaseDialog
		if _bulk_purchase_dialog:
			call_deferred("_reopen_bulk_purchase_dialog_after_image_upload")

func _reopen_bulk_purchase_dialog_after_image_upload() -> void:
	"""Открывает BulkPurchaseDialog после закрытия диалога загрузки изображений."""
	if _bulk_purchase_dialog:
		_bulk_purchase_dialog.popup_centered(Vector2(450, 500))

func _on_bulk_images_selected(image_paths: Dictionary, corporate_mode: bool, group_id: String) -> void:
	"""Обрабатывает выбранные изображения для каждого сегмента."""
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("set_selected_images"):
		_bulk_purchase_dialog.set_selected_images(image_paths)
	if _bulk_purchase_dialog and _bulk_purchase_dialog.has_method("set_image_selection_metadata"):
		_bulk_purchase_dialog.set_image_selection_metadata(corporate_mode, group_id)

func _on_bulk_single_image_selected(image_path: String) -> void:
	"""Обрабатывает выбор одной картинки для всех сегментов."""
	if _bulk_purchase_dialog == null or not _bulk_purchase_dialog.has_method("get_preview_segment_ids"):
		return
	var ids: Array = _bulk_purchase_dialog.get_preview_segment_ids()
	var image_paths: Dictionary = {}
	for sid in ids:
		image_paths[str(sid)] = image_path
	if _bulk_purchase_dialog.has_method("set_selected_images"):
		_bulk_purchase_dialog.set_selected_images(image_paths)
	if _bulk_purchase_dialog.has_method("set_image_selection_metadata"):
		_bulk_purchase_dialog.set_image_selection_metadata(false, "")

func _on_bulk_purchase_confirmed(segment_ids: Array, side: String, image_paths: Dictionary, links: Dictionary, corporate_mode: bool = false, group_id: String = "") -> void:
	"""Обработка подтверждения массовой покупки."""
	_log("[CUBEVIEW] bulk_purchase_confirmed segments=%d side=%s corporate=%s" % [segment_ids.size(), side, corporate_mode])
	if wall_instance == null:
		_log("[CUBEVIEW] ERROR - wall_instance is null")
		return
	var wall_data: WallData = null
	if wall_instance.has_node("WallData"):
		wall_data = wall_instance.get_node("WallData") as WallData
	if wall_data == null:
		_log("[CUBEVIEW] ERROR - wall_data is null")
		return
	
	# Проверяем баланс (монеты списывает WallData.buy_side)
	if not Engine.has_singleton("GameState"):
		push_error("CubeView: GameState недоступен для покупки!")
		_log("[CUBEVIEW] ERROR - GameState недоступен")
		return
	
	var balance = GameState.score
	var total_price: int = 0
	for seg_id in segment_ids:
		var sid: String = str(seg_id)
		if sid.is_empty():
			continue
		total_price += wall_data.get_segment_price(sid)
	_log("[CUBEVIEW] purchase check: balance=%d total_price=%d" % [balance, total_price])
	if balance < total_price:
		push_error("CubeView: Недостаточно монет для покупки! Баланс: %d, требуется: %d" % [balance, total_price])
		_log("[CUBEVIEW] ERROR - insufficient balance")
		return
	
	# Выполняем покупку каждого сегмента
	var buyer_uid: String = GameState.player_uid
	var purchased_count: int = 0
	for seg_id in segment_ids:
		var sid: String = str(seg_id)
		if sid.is_empty():
			continue
		var price: int = wall_data.get_segment_price(sid)
		if wall_data.buy_side(sid, side, buyer_uid, price):
			purchased_count += 1
			_log("[CUBEVIEW] purchased segment=%s side=%s price=%d" % [sid, side, price])
			if corporate_mode and wall_data.has_method("set_segment_corporate_info"):
				wall_data.set_segment_corporate_info(sid, group_id, true)
			# Загружаем изображение если оно выбрано
			if image_paths.has(sid) and image_paths[sid] != "":
				_copy_and_set_image(sid, side, image_paths[sid], wall_data)
			# Устанавливаем ссылку если она указана
			if links.has(sid) and links[sid] != "":
				wall_data.set_face_link(sid, side, links[sid])
			wall_instance.update_segment_visual(sid)
	
	_log("[CUBEVIEW] purchase complete: %d/%d segments purchased" % [purchased_count, segment_ids.size()])
	
	# Проверяем, не пора ли открыть следующую сторону
	_check_and_unlock_next_side(wall_data)
	
	# Убираем подсветку после покупки
	if wall_instance:
		wall_instance.clear_highlight()

func _init_purchase_dialog_ui() -> void:
	"""Инициализирует UI программно созданного диалога."""
	if purchase_dialog == null:
		return
	
	# Создаём UI элементы программно (полная версия с загрузкой изображений)
	var vbox = VBoxContainer.new()
	purchase_dialog.add_child(vbox)
	
	# Цена
	var price_label = Label.new()
	price_label.name = "PriceLabel"
	price_label.text = "Цена: 0 coin"
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(price_label)
	
	# Статус
	var status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Статус: Свободен"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status_label)
	
	# Сторона
	var side_container = HBoxContainer.new()
	var side_label = Label.new()
	side_label.text = "Сторона:"
	side_container.add_child(side_label)
	var side_option = OptionButton.new()
	side_option.name = "SideOptionButton"
	for side in ["front", "back", "left", "right", "top", "bottom"]:
		side_option.add_item(side.capitalize())
	side_container.add_child(side_option)
	vbox.add_child(side_container)
	
	# Блок изображений
	var image_container = VBoxContainer.new()
	image_container.name = "ImageContainer"
	var image_label = Label.new()
	image_label.text = "Изображение (опционально):"
	image_container.add_child(image_label)
	
	var image_path_label = Label.new()
	image_path_label.name = "ImagePathLabel"
	image_path_label.text = "Изображение не выбрано"
	image_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	image_container.add_child(image_path_label)
	
	var load_image_btn = Button.new()
	load_image_btn.name = "LoadImageButton"
	load_image_btn.text = "Загрузить"
	# Подключаем обработчик для программно созданной кнопки
	load_image_btn.pressed.connect(_on_programmatic_load_image_pressed)
	image_container.add_child(load_image_btn)
	
	var preview_hint = Label.new()
	preview_hint.name = "PreviewHintLabel"
	preview_hint.text = "Сначала загрузите изображение (при необходимости), затем нажмите Предпросмотр — посмотреть сегмент на карте."
	preview_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	image_container.add_child(preview_hint)
	
	var preview_btn = Button.new()
	preview_btn.name = "PreviewButton"
	preview_btn.text = "Предпросмотр"
	image_container.add_child(preview_btn)
	
	vbox.add_child(image_container)
	
	# Ссылка
	var link_container = VBoxContainer.new()
	var link_label = Label.new()
	link_label.text = "Ссылка (опционально, формат: http:// или https://):"
	link_container.add_child(link_label)
	var link_edit = LineEdit.new()
	link_edit.name = "LinkLineEdit"
	link_edit.placeholder_text = "https://example.com"
	link_container.add_child(link_edit)
	vbox.add_child(link_container)
	
	# Кнопки
	var buttons_container = HBoxContainer.new()
	buttons_container.name = "ButtonsContainer"
	var cancel_btn = Button.new()
	cancel_btn.name = "CancelButton"
	cancel_btn.text = "Отмена"
	cancel_btn.pressed.connect(_on_purchase_dialog_cancel_pressed)
	buttons_container.add_child(cancel_btn)
	
	var purchase_btn = Button.new()
	purchase_btn.name = "PurchaseButton"
	purchase_btn.text = "Купить"
	purchase_btn.pressed.connect(_on_purchase_dialog_purchase_pressed)
	buttons_container.add_child(purchase_btn)
	
	vbox.add_child(buttons_container)
	
	print("CubeView: UI диалога создан программно (полная версия с изображениями)")

func _on_purchase_dialog_purchase_pressed() -> void:
	"""Обработчик кнопки покупки в программно созданном диалоге."""
	if purchase_dialog and purchase_dialog.has_method("get_meta"):
		var click_data = purchase_dialog.get_meta("click_data", {})
		var segment_id = str(click_data.get("segment_id", ""))
		if segment_id != "":
			purchase_dialog.purchase_confirmed.emit(segment_id, "front", "", "")
	purchase_dialog.hide()

func _on_purchase_dialog_cancel_pressed() -> void:
	"""Обработчик кнопки отмены в программно созданном диалоге."""
	if purchase_dialog:
		purchase_dialog.hide()

func _on_programmatic_load_image_pressed() -> void:
	"""Обработчик кнопки загрузки изображения в программно созданном диалоге."""
	if purchase_dialog == null:
		return
	# Вызываем метод загрузки изображения из PurchaseDialog
	if purchase_dialog.has_method("_on_load_image_pressed"):
		purchase_dialog._on_load_image_pressed()
	else:
		# Если метод недоступен, используем прямой вызов DisplayServer
		var filters: PackedStringArray = PackedStringArray(["*.png", "*.jpg", "*.jpeg", "*.webp"])
		DisplayServer.file_dialog_show(
			"Выберите изображение",
			"",
			"",
			false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			filters,
			_on_programmatic_file_dialog_result
		)

func _on_programmatic_file_dialog_result(status: bool, selected_paths: PackedStringArray, selected_filter_index: int) -> void:
	"""Обрабатывает результат нативного диалога для программно созданного диалога."""
	if status and selected_paths.size() > 0 and purchase_dialog != null:
		var path: String = selected_paths[0]
		print("CubeView: Файл выбран для программного диалога: ", path)
		# Обновляем PurchaseDialog через его метод если доступен
		if purchase_dialog.has_method("_on_file_selected"):
			purchase_dialog._on_file_selected(path)
		else:
			# Обновляем UI напрямую
			var image_path_label = purchase_dialog.get_node_or_null("VBoxContainer/ImageContainer/ImagePathLabel")
			if image_path_label:
				var file_name = path.get_file()
				image_path_label.text = "Изображение: " + file_name
				print("CubeView: Label обновлён напрямую: ", image_path_label.text)
			else:
				print("CubeView: WARNING - ImagePathLabel не найден в программном диалоге!")
			# Сохраняем путь в метаданных диалога
			purchase_dialog.set_meta("selected_image_path", path)

func _show_purchase_dialog(click_data: Dictionary) -> void:
	"""Показывает диалог покупки сегмента."""
	# Проверяем, не освобождён ли диалог
	if purchase_dialog != null and not is_instance_valid(purchase_dialog):
		purchase_dialog = null
	
	if purchase_dialog == null:
		print("CubeView: создаём диалог покупки...")
		_create_purchase_dialog()
	
	# Проверяем ещё раз после создания
	if purchase_dialog == null:
		# Fallback на старую покупку без диалога
		print("CubeView: ERROR - purchase_dialog is null after creation!")
		print("CubeView: проверьте консоль на наличие ошибок загрузки сцены")
		_try_purchase_segment(click_data)
		return
	
	# Проверяем, что диалог в дереве сцены
	if not purchase_dialog.is_inside_tree():
		print("CubeView: WARNING - диалог не в дереве сцены, добавляем...")
		var scene_root = get_tree().root
		if scene_root:
			scene_root.add_child(purchase_dialog)
	
	var segment_id: String = str(click_data.get("segment_id", ""))
	var price: int = int(click_data.get("price", 0))
	
	# Получаем данные сегмента для отображения статуса
	var wall_data: WallData = null
	if wall_instance and wall_instance.has_node("WallData"):
		wall_data = wall_instance.get_node("WallData") as WallData
	
	if purchase_dialog.has_method("setup"):
		purchase_dialog.setup(segment_id, price, wall_data)
	
	# Сохраняем данные клика для использования в подтверждении
	purchase_dialog.set_meta("click_data", click_data)
	
	# В Godot 4 AcceptDialog нужно показывать через popup()
	# Убеждаемся, что диалог видим и находится в правильном месте
	if purchase_dialog is Window:
		purchase_dialog.visible = true
		purchase_dialog.popup_centered(Vector2(500, 500))
	else:
		# Fallback для старых версий
		purchase_dialog.visible = true
		purchase_dialog.popup_centered(Vector2(500, 500))
	
	# Отладочный вывод
	print("CubeView: диалог покупки должен быть виден. visible=", purchase_dialog.visible, ", parent=", purchase_dialog.get_parent(), ", is_inside_tree=", purchase_dialog.is_inside_tree())

func _on_single_preview_requested() -> void:
	"""Предпросмотр одного сегмента на карте."""
	print("CubeView: _on_single_preview_requested вызван")
	if purchase_dialog == null:
		print("CubeView: purchase_dialog == null")
		return
	var seg_id: Variant = purchase_dialog.get("segment_id")
	if seg_id == null or str(seg_id).is_empty():
		print("CubeView: segment_id пуст или не найден")
		return
	print("CubeView: Предпросмотр сегмента ", seg_id)
	purchase_dialog.hide()
	_single_preview_mode = true
	if wall_instance:
		wall_instance.set_pause_side_switching(true)
		wall_instance.set_dim_other_segments(true)  # Затемняем чужие сегменты
		wall_instance.set_highlighted_segment(str(seg_id))
		# Если для сегмента загружена картинка — показываем её в предпросмотре
		var img_path: String = ""
		if purchase_dialog.get("selected_image_path") != null:
			img_path = str(purchase_dialog.selected_image_path)
		print("CubeView: Путь к изображению для предпросмотра: ", img_path if img_path != "" else "не задан")
		if img_path != "":
			wall_instance.set_preview_image_paths({str(seg_id): img_path})
			print("CubeView: Preview изображение установлено для сегмента ", seg_id)
	# Центрируем камеру на сегменте (segment_id = "x_y", размер сегмента 48)
	var cam: Camera2D = get_node_or_null("Camera2D")
	if cam:
		var parts: PackedStringArray = str(seg_id).split("_")
		if parts.size() >= 2:
			var seg_x: int = int(parts[0])
			var seg_y: int = int(parts[1])
			cam.position = Vector2(seg_x * 48.0 + 24.0, seg_y * 48.0 + 24.0)
	if wall_instance and wall_instance.has_method("_update_visible_segments"):
		wall_instance.call_deferred("_update_visible_segments")
	selection_overlay.visible = true
	var hint = selection_overlay.get_node_or_null("VBox/HintLabel")
	if hint is Label:
		(hint as Label).text = "Предпросмотр сегмента. Нажмите Далее для возврата в диалог."
	if next_button:
		next_button.disabled = false
		next_button.text = "Далее"

func _on_purchase_confirmed(segment_id: String, side: String, image_path: String, link: String) -> void:
	"""Обрабатывает подтверждение покупки из диалога."""
	if wall_instance == null:
		return
	
	# Убираем подсветку
	wall_instance.clear_highlight()
	
	# Получаем wall_data из wall_instance
	var wall_data: WallData = null
	if wall_instance.has_node("WallData"):
		wall_data = wall_instance.get_node("WallData") as WallData
	
	if wall_data == null:
		return
	
	# Получаем данные клика для цены
	var click_data: Dictionary = {}
	if purchase_dialog and purchase_dialog.has_meta("click_data"):
		click_data = purchase_dialog.get_meta("click_data")
	
	var price: int = int(click_data.get("price", 0))
	if price == 0:
		price = wall_data.get_segment_price(segment_id)
	
	# Покупаем сторону сегмента
	var buyer_uid: String = GameState.player_uid if Engine.has_singleton("GameState") else ""
	var success: bool = wall_data.buy_side(segment_id, side, buyer_uid, price)
	
	if success:
		# Обрабатываем изображение
		if not image_path.is_empty():
			_copy_and_set_image(segment_id, side, image_path, wall_data)
		
		# Обрабатываем ссылку
		if not link.is_empty():
			wall_data.set_face_link(segment_id, side, link)
		
		# Обновляем визуал через wall_instance
		wall_instance.update_segment_visual(segment_id)
		
		# Визуальная обратная связь
		print("Purchased segment: ", segment_id, " side: ", side)

		# Проверяем, не пора ли открыть следующую сторону
		_check_and_unlock_next_side(wall_data)

func _copy_and_set_image(segment_id: String, side: String, source_path: String, wall_data: WallData) -> void:
	"""Копирует изображение в user://wall_images/, сжимает до 48x48 пикселей и устанавливает его для сегмента."""
	# Создаём директорию для изображений если её нет
	var images_dir = "user://wall_images"
	if not DirAccess.dir_exists_absolute(images_dir):
		DirAccess.open("user://").make_dir("wall_images")
	
	# Загружаем исходное изображение
	var source_image = Image.new()
	var load_error = source_image.load(source_path)
	if load_error != OK:
		push_error("CubeView: не удалось загрузить изображение: " + source_path + " (ошибка: " + str(load_error) + ")")
		return
	
	# Сжимаем изображение до 48x48 пикселей
	const TARGET_SIZE: int = 48
	source_image.resize(TARGET_SIZE, TARGET_SIZE, Image.INTERPOLATE_LANCZOS)
	
	# Генерируем уникальное имя файла
	var ext: String = source_path.get_extension()
	if ext.is_empty():
		ext = "png"
	var file_name = segment_id + "_" + side + "_" + str(Time.get_unix_time_from_system()) + "." + ext
	var dest_path = images_dir + "/" + file_name
	
	# Сохраняем сжатое изображение
	var save_error: Error
	if ext.to_lower() == "png":
		save_error = source_image.save_png(dest_path)
	elif ext.to_lower() in ["jpg", "jpeg"]:
		save_error = source_image.save_jpg(dest_path, 0.9)
	elif ext.to_lower() == "webp":
		save_error = source_image.save_webp(dest_path)
	else:
		# По умолчанию сохраняем как PNG
		save_error = source_image.save_png(dest_path)
	
	if save_error != OK:
		push_error("CubeView: не удалось сохранить сжатое изображение: " + dest_path + " (ошибка: " + str(save_error) + ")")
		return
	
	print("CubeView: Изображение сжато до 48x48 и сохранено: ", dest_path)
	
	# Устанавливаем путь к изображению в WallData
	wall_data.set_face_image(segment_id, side, dest_path)


func _check_and_unlock_next_side(wall_data: WallData) -> void:
	"""
	Простая оффлайн-логика открытия новой стороны:
	- считаем количество купленных сегментов на текущей стороне;
	- если превышен порог, открываем следующую сторону через GameState.unlock_next_wall_side().
	"""
	if wall_data == null:
		return

	if not Engine.has_singleton("GameState"):
		return

	# Считаем количество купленных лиц на активной стороне
	var side: String = GameState.get_active_wall_side()
	var owned_count: int = 0
	for seg_id in wall_data.segments.keys():
		var face_data: Dictionary = wall_data.get_face_data(seg_id, side)
		if str(face_data.get("owner", "")) != "":
			owned_count += 1

	# Порог можно потом вынести в настройки / ТЗ
	var THRESHOLD := 50  # пример: 50 купленных сегментов на стороне
	if owned_count >= THRESHOLD:
		GameState.unlock_next_wall_side()

func _try_purchase_segment(click_data: Dictionary) -> void:
	"""Старый метод покупки без диалога (fallback)."""
	var segment_id: String = str(click_data.get("segment_id", ""))
	var side: String = str(click_data.get("side", "front"))
	var price: int = int(click_data.get("price", 0))
	
	if segment_id == "" or wall_instance == null:
		return
	
	# Получаем wall_data из wall_instance
	var wall_data: WallData = null
	if wall_instance.has_node("WallData"):
		wall_data = wall_instance.get_node("WallData") as WallData
	
	if wall_data == null:
		return
	
	# Покупаем сторону сегмента
	var buyer_uid: String = GameState.player_uid if Engine.has_singleton("GameState") else ""
	var success: bool = wall_data.buy_side(segment_id, side, buyer_uid, price)
	
	if success:
		# Обновляем визуал через wall_instance
		wall_instance.update_segment_visual(segment_id)


func _on_back_button_pressed() -> void:
	# Простая навигация: возвращаемся в главное меню.
	# Путь к сцене главного меню может быть прочитан из GameState
	# или захардкожен/экспортирован в CubeView; в данном прототипе
	# используем явный путь.
	_log("[CUBEVIEW] back_button pressed")
	var main_menu_path: String = "res://MainMenu.tscn"
	var err: int = get_tree().change_scene_to_file(main_menu_path)
	if err != OK:
		push_error("CubeView.gd: cannot load main menu: " + main_menu_path)
		_log("[CUBEVIEW] ERROR - scene change failed: %s" % main_menu_path)
