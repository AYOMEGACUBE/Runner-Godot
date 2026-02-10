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


func _ready() -> void:
	# ------------------------------------------------------------
	# 1. Инстанс существующей сцены стены.
	# ------------------------------------------------------------
	# Мы намеренно НЕ создаём новую реализацию стены.
	# Вместо этого:
	# - загружаем wall.tscn
	# - инстанцируем её один раз
	# - добавляем как ребёнка CubeView
	# Вся логика генерации сегментов, вращения и «дыхания» остаётся в wall.gd
	# и WallSegment.gd; CubeView лишь задаёт окружение.
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
	# 5. Ограничиваем клики по сегментам в зависимости от высоты.
	# ------------------------------------------------------------
	# ВАЖНО:
	# - Мы НЕ меняем WallSegment.gd и НЕ вмешиваемся в его логику.
	# - Вместо этого работаем только со свойствами Area2D:
	#   * для сегментов ВЫШЕ гейта выключаем input_pickable,
	#     так что их Area2D не будет получать события ввода.
	#   * для сегментов НИЖЕ гейта включаем input_pickable.
	# - Рандомные повороты, дыхание и т.п. по-прежнему работают, так как
	#   _process в WallSegment не зависит от input_pickable.
	# ------------------------------------------------------------
	_apply_height_gate_to_segments()


func _apply_height_gate_to_segments() -> void:
	# Если стена не загружена — нечего ограничивать.
	if wall_instance == null:
		return

	# Обходим всех потомков wall_instance в глубину (ручной стек).
	# Ищем ноды, которые выглядят как наши сегменты:
	# - называются "WallSegment"
	# - имеют ребёнка "Area2D" типа Area2D.
	var stack: Array[Node] = [wall_instance]

	while stack.size() > 0:
		var current: Node = stack.pop_back()

		# get_children() возвращает Array<Node> (в Godot 4 с типами),
		# но мы всё равно явно объявляем тип локальной переменной,
		# чтобы компилятор не выводил её как Variant.
		for child in current.get_children():
			var child_node: Node = child
			stack.push_back(child_node)

		# Проверяем только ноды-сегменты по имени.
		if current.name == "WallSegment" and current.has_node("Area2D"):
			# Забираем ребёнка "Area2D" и явно кастуем к Area2D.
			var area_node: Node = current.get_node("Area2D")
			var area: Area2D = area_node as Area2D
			if area == null:
				continue

			# Нам нужна глобальная позиция сегмента, поэтому кастуем к Node2D.
			var segment_2d: Node2D = current as Node2D
			if segment_2d == null:
				continue

			var seg_global_y: float = segment_2d.global_position.y

			# В системе координат Godot Y растёт вниз:
			# - МЕНЬШЕ y → ВЫШЕ на экране
			# - БОЛЬШЕ y → НИЖЕ на экране
			#
			# Условие задачи:
			# - сегменты НИЖЕ линии (y > gate_y) кликабельны
			# - сегменты ВЫШЕ линии (y <= gate_y) игнорируют клики
			var clickable: bool = seg_global_y > gate_y

			# Мы меняем только input_pickable и monitoring,
			# не трогая саму логику WallSegment.
			area.input_pickable = clickable
			area.monitoring = clickable

			# Для наглядности можно было бы логировать состояние,
			# но по условиям задания новый debug вывод не добавляем.


func _on_back_button_pressed() -> void:
	# Простая навигация: возвращаемся в главное меню.
	# Путь к сцене главного меню может быть прочитан из GameState
	# или захардкожен/экспортирован в CubeView; в данном прототипе
	# используем явный путь.
	var main_menu_path: String = "res://MainMenu.tscn"
	var err: int = get_tree().change_scene_to_file(main_menu_path)
	if err != OK:
		push_error("CubeView.gd: cannot load main menu: " + main_menu_path)
