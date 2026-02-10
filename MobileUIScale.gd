extends Node
# ============================================================================
# MobileUIScale.gd
# ----------------------------------------------------------------------------
# Простой вспомогательный узел, который масштабирует целевой UI‑элемент
# (обычно `Panel` / `Control`) под размер экрана мобильных устройств.
#
# ВАЖНО:
# - Скрипт НИЧЕГО не меняет в геймплее.
# - Работает только с размером и масштабом UI.
# - Если целевой узел не найден, просто пишет предупреждение и ничего не делает.
# ============================================================================

@export var target_node_path: NodePath = NodePath(".")

# Базовое разрешение, под которое верстался UI в эталоне.
const BASE_WIDTH := 1080.0
const BASE_HEIGHT := 1920.0


func _ready() -> void:
	var target := get_node_or_null(target_node_path)
	if target == null:
		push_warning("MobileUIScale: target node not found: " + str(target_node_path))
		return

	if not (target is Control):
		push_warning("MobileUIScale: target is not Control: " + str(target))
		return

	# Текущий размер экрана / окна
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	# На десктопе оставляем исходный размер UI, масштабируем только на мобильных
	var os_name := OS.get_name()
	if os_name != "Android" and os_name != "iOS":
		target.scale = Vector2.ONE
		return

	# Рассчитываем коэффициенты масштабирования по ширине/высоте
	var scale_x := viewport_size.x / BASE_WIDTH
	var scale_y := viewport_size.y / BASE_HEIGHT

	# Берём минимальный коэффициент, чтобы UI влезал целиком
	var k := float(min(scale_x, scale_y))
	# Небольшой "коридор", чтобы на десктопе не было гигантского UI
	# - Если k < 0.9 — масштабируем до мобильного
	# - Если k в [0.9; 1.1] — оставляем как есть
	# - Если k > 1.1 — слегка уменьшаем, чтобы не раздувать интерфейс
	if k < 0.9:
		target.scale = Vector2(k, k)
	elif k > 1.1:
		var desk: float = lerp(1.0, k, 0.3)
		target.scale = Vector2(desk, desk)
	else:
		target.scale = Vector2.ONE
