extends Node2D
# ============================================================================
# CubeView.gd
# ============================================================================
# СЦЕНА ПРОСМОТРА СТЕНЫ ВНЕ ИГРОВОГО ПРОЦЕССА
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

## Высота-гейт по Y в мировых координатах CubeView.
## Сегменты с global_position.y > gate_y считаются НИЖЕ линии (доступны),
## а с y <= gate_y — ВЫШЕ линии (клики игнорируются).
var gate_y: float = 0.0

## Флаг разрешения покупок (включается в _ready)
var allow_purchases: bool = true

## Диалог покупки сегмента
var purchase_dialog: AcceptDialog = null

## Текущая сторона для просмотра в CubeView (читается из GameState)
var current_side: String = "front"

## Переменные для перетаскивания камеры
var _dragging_camera: bool = false
var _last_drag_pos: Vector2 = Vector2.ZERO

## Мини-карта
var minimap_camera: Camera2D = null


func _ready() -> void:
	# ------------------------------------------------------------
	# 1. Инстанс существующей сцены стены.
	# ------------------------------------------------------------
	# Загружаем wall.tscn и включаем покупки (allow_purchases = true)
	# ------------------------------------------------------------
	if wall_scene_path == "":
		push_error("CubeView.gd: wall_scene_path is empty")
	else:
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
				
				# ВКЛЮЧАЕМ покупки для CubeView
				wall_instance.allow_purchases = true
				# Также обновляем рендерер если он уже создан
				call_deferred("_enable_purchases_in_renderer")
		else:
			push_error("CubeView.gd: cannot load wall scene as PackedScene: " + wall_scene_path)

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
		else:
			gate_y = -200.0
	else:
		gate_y = -200.0

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
	# 6. Создаём диалог покупки сегмента.
	# ------------------------------------------------------------
	_create_purchase_dialog()

	# ------------------------------------------------------------
	# 7. Читаем активную сторону мегакуба из GameState.
	# ------------------------------------------------------------
	if Engine.has_singleton("GameState") and GameState.has_method("get_active_wall_side"):
		current_side = GameState.get_active_wall_side()
	
	# ------------------------------------------------------------
	# 8. Настраиваем мини-карту.
	# ------------------------------------------------------------
	_setup_minimap()

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
	
	# Обработка перетаскивания камеры (правая кнопка мыши или тач)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_dragging_camera = true
			_last_drag_pos = event.position
		else:
			_dragging_camera = false
		get_viewport().set_input_as_handled()
	
	if event is InputEventMouseMotion and _dragging_camera:
		var camera: Camera2D = get_node_or_null("Camera2D")
		if camera:
			var delta: Vector2 = event.position - _last_drag_pos
			camera.position -= delta / camera.zoom
			_last_drag_pos = event.position
		get_viewport().set_input_as_handled()
	
	# Обработка кликов для покупки сегментов
	if not allow_purchases:
		return
	
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if wall_instance == null:
			return
		
		# Преобразуем экранные координаты в мировые через камеру
		var camera: Camera2D = get_node_or_null("Camera2D")
		var viewport: Viewport = get_viewport()
		var mouse_pos: Vector2 = event.position
		var world_pos: Vector2
		if camera:
			world_pos = camera.get_global_mouse_position()
		else:
			world_pos = viewport.get_global_mouse_position()
		
		# Получаем данные сегмента по координатам клика
		var click_data: Dictionary = wall_instance.handle_click(world_pos)
		if click_data.is_empty():
			print("CubeView: клик не попал в сегмент, позиция: ", world_pos)
			return
		
		# Проверяем высотный гейт (в Godot Y меньше = выше)
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			print("CubeView: сегмент выше гейта, высота: ", seg_height, ", гейт: ", gate_y)
			return  # Сегмент выше достигнутой высоты
		
		print("CubeView: открываем диалог для сегмента: ", click_data.get("segment_id"))
		# Подсвечиваем выбранный сегмент
		var seg_id: String = str(click_data.get("segment_id", ""))
		if wall_instance:
			wall_instance.set_highlighted_segment(seg_id)
		# Показываем диалог покупки
		_show_purchase_dialog(click_data)
	
	elif event is InputEventScreenTouch and event.pressed:
		if wall_instance == null:
			return
		
		# Обработка тача на мобильных устройствах
		# Преобразуем экранные координаты в мировые
		var viewport: Viewport = get_viewport()
		var camera: Camera2D = get_node_or_null("Camera2D")
		var touch_pos: Vector2 = event.position
		var world_pos: Vector2
		if camera:
			world_pos = camera.get_global_mouse_position()
		else:
			world_pos = viewport.get_global_mouse_position()
		
		var click_data: Dictionary = wall_instance.handle_click(world_pos)
		if click_data.is_empty():
			return
		
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			return
		
		# Показываем диалог покупки
		_show_purchase_dialog(click_data)

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
		
		# Подключаем сигнал
		if purchase_dialog.has_signal("purchase_confirmed"):
			purchase_dialog.purchase_confirmed.connect(_on_purchase_confirmed)
		
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
	
	# Подключаем сигнал подтверждения покупки
	if purchase_dialog.has_signal("purchase_confirmed"):
		purchase_dialog.purchase_confirmed.connect(_on_purchase_confirmed)
		print("CubeView: сигнал purchase_confirmed подключён")
	else:
		push_warning("CubeView: диалог не имеет сигнала purchase_confirmed")
		print("CubeView: доступные сигналы: ", purchase_dialog.get_signal_list())

func _init_purchase_dialog_ui() -> void:
	"""Инициализирует UI программно созданного диалога."""
	if purchase_dialog == null:
		return
	
	# Создаём UI элементы программно
	var vbox = VBoxContainer.new()
	purchase_dialog.add_child(vbox)
	
	# Добавляем основные элементы (упрощённая версия)
	var price_label = Label.new()
	price_label.name = "PriceLabel"
	price_label.text = "Цена: 0 coin"
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(price_label)
	
	var purchase_btn = Button.new()
	purchase_btn.name = "PurchaseButton"
	purchase_btn.text = "Купить"
	purchase_btn.pressed.connect(_on_purchase_dialog_purchase_pressed)
	vbox.add_child(purchase_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.name = "CancelButton"
	cancel_btn.text = "Отмена"
	cancel_btn.pressed.connect(_on_purchase_dialog_cancel_pressed)
	vbox.add_child(cancel_btn)
	
	print("CubeView: UI диалога создан программно")

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
	"""Копирует изображение в user://wall_images/ и устанавливает его для сегмента."""
	# Создаём директорию для изображений если её нет
	var images_dir = "user://wall_images"
	if not DirAccess.dir_exists_absolute(images_dir):
		DirAccess.open("user://").make_dir("wall_images")
	
	# Генерируем уникальное имя файла
	var file_name = segment_id + "_" + side + "_" + str(Time.get_unix_time_from_system()) + source_path.get_extension()
	var dest_path = images_dir + "/" + file_name
	
	# Копируем файл
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if source_file == null:
		push_error("CubeView: не удалось открыть исходный файл изображения: " + source_path)
		return
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if dest_file == null:
		source_file.close()
		push_error("CubeView: не удалось создать файл изображения: " + dest_path)
		return
	
	# Копируем данные
	var buffer = source_file.get_buffer(source_file.get_length())
	dest_file.store_buffer(buffer)
	
	source_file.close()
	dest_file.close()
	
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
	var main_menu_path: String = "res://MainMenu.tscn"
	var err: int = get_tree().change_scene_to_file(main_menu_path)
	if err != OK:
		push_error("CubeView.gd: cannot load main menu: " + main_menu_path)
