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

func _enable_purchases_in_renderer() -> void:
	if wall_instance == null:
		return
	wall_instance.allow_purchases = true
	# Ищем рендерер среди всех детей (может быть создан позже)
	for child in wall_instance.get_children():
		if child is WallRenderer:
			child.allow_purchases = true


func _input(event: InputEvent) -> void:
	# Обработка кликов для покупки сегментов
	if not allow_purchases:
		return
	
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if wall_instance == null:
			return
		
		# Получаем данные сегмента по координатам клика
		var click_data: Dictionary = wall_instance.handle_click(event.global_position)
		if click_data.is_empty():
			return
		
		# Проверяем высотный гейт (в Godot Y меньше = выше)
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			return  # Сегмент выше достигнутой высоты
		
		# Покупаем сегмент
		_try_purchase_segment(click_data)
	
	elif event is InputEventScreenTouch and event.pressed:
		if wall_instance == null:
			return
		
		# Обработка тача на мобильных устройствах
		# Преобразуем экранные координаты в мировые
		var viewport: Viewport = get_viewport()
		var global_touch_pos: Vector2 = viewport.get_global_mouse_position()
		var click_data: Dictionary = wall_instance.handle_click(global_touch_pos)
		if click_data.is_empty():
			return
		
		var seg_height: float = float(click_data.get("height", 0.0))
		if seg_height < gate_y:
			return
		
		_try_purchase_segment(click_data)

func _try_purchase_segment(click_data: Dictionary) -> void:
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
		
		# Можно добавить визуальную обратную связь (анимация, звук и т.д.)
		# print("Purchased segment: ", segment_id, " side: ", side)


func _on_back_button_pressed() -> void:
	# Простая навигация: возвращаемся в главное меню.
	# Путь к сцене главного меню может быть прочитан из GameState
	# или захардкожен/экспортирован в CubeView; в данном прототипе
	# используем явный путь.
	var main_menu_path: String = "res://MainMenu.tscn"
	var err: int = get_tree().change_scene_to_file(main_menu_path)
	if err != OK:
		push_error("CubeView.gd: cannot load main menu: " + main_menu_path)
