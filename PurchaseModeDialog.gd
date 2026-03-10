extends AcceptDialog
# ============================================================================
# PurchaseModeDialog.gd
# Окно выбора режима покупки (ТЗ п.1)
# Две кнопки: Купить один сегмент | Купить несколько сегментов
# ============================================================================

signal mode_single_selected()
signal mode_multi_selected()
signal back_pressed()

func _ready() -> void:
	call_deferred("_setup_ui")

func _setup_ui() -> void:
	title = "Покупка сегмента"
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	add_child(vbox)
	
	# Крупные кнопки
	var btn_single = Button.new()
	btn_single.name = "BtnSingle"
	btn_single.text = "Купить один сегмент"
	btn_single.custom_minimum_size = Vector2(0, 56)
	btn_single.add_theme_font_size_override("font_size", 22)
	btn_single.pressed.connect(_on_single_pressed)
	vbox.add_child(btn_single)
	
	var btn_multi = Button.new()
	btn_multi.name = "BtnMulti"
	btn_multi.text = "Купить несколько сегментов"
	btn_multi.custom_minimum_size = Vector2(0, 56)
	btn_multi.add_theme_font_size_override("font_size", 22)
	btn_multi.pressed.connect(_on_multi_pressed)
	vbox.add_child(btn_multi)
	
	# Пояснение
	var hint = Label.new()
	hint.text = "Выберите режим и следуйте подсказкам на экране"
	hint.add_theme_font_size_override("font_size", 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)
	
	# Кнопка Назад
	var btn_back = Button.new()
	btn_back.name = "BtnBack"
	btn_back.text = "Назад"
	btn_back.custom_minimum_size = Vector2(0, 44)
	btn_back.pressed.connect(_on_back_pressed)
	vbox.add_child(btn_back)

func _on_single_pressed() -> void:
	hide()
	mode_single_selected.emit()

func _on_multi_pressed() -> void:
	hide()
	mode_multi_selected.emit()

func _on_back_pressed() -> void:
	hide()
	back_pressed.emit()
