extends AcceptDialog
# ============================================================================
# PurchaseDialog.gd
# Диалог покупки сегмента стены
# ============================================================================
# Позволяет игроку:
# - Выбрать сторону сегмента для покупки
# - Загрузить изображение (опционально)
# - Ввести ссылку (опционально)
# - Подтвердить покупку
# ============================================================================

signal purchase_confirmed(segment_id: String, side: String, image_path: String, link: String)

var segment_id: String = ""
var segment_price: int = 0
var available_sides: Array[String] = ["front", "back", "left", "right", "top", "bottom"]

# UI элементы (будут найдены в _ready)
var price_label: Label = null
var status_label: Label = null
var side_option: OptionButton = null
var image_path_label: Label = null
var load_image_button: Button = null
var link_line_edit: LineEdit = null
var purchase_button: Button = null
var cancel_button: Button = null
var file_dialog: FileDialog = null

var selected_image_path: String = ""
var wall_data: WallData = null

func _ready() -> void:
	# Используем call_deferred для безопасной инициализации UI элементов
	# Это предотвращает ошибки, если узлы ещё не готовы
	call_deferred("_init_ui_elements")

func _init_ui_elements() -> void:
	# Находим UI элементы
	price_label = get_node_or_null("VBoxContainer/PriceLabel")
	status_label = get_node_or_null("VBoxContainer/StatusLabel")
	side_option = get_node_or_null("VBoxContainer/SideContainer/SideOptionButton")
	image_path_label = get_node_or_null("VBoxContainer/ImageContainer/ImagePathLabel")
	load_image_button = get_node_or_null("VBoxContainer/ImageContainer/LoadImageButton")
	link_line_edit = get_node_or_null("VBoxContainer/LinkContainer/LinkLineEdit")
	purchase_button = get_node_or_null("VBoxContainer/ButtonsContainer/PurchaseButton")
	cancel_button = get_node_or_null("VBoxContainer/ButtonsContainer/CancelButton")
	file_dialog = get_node_or_null("FileDialog")
	
	# Заполняем список сторон
	if side_option:
		side_option.clear()
		for side in available_sides:
			side_option.add_item(side.capitalize())
	
	# Подключаем сигналы (проверяем, что элементы существуют)
	if load_image_button:
		if not load_image_button.pressed.is_connected(_on_load_image_pressed):
			load_image_button.pressed.connect(_on_load_image_pressed)
	if purchase_button:
		if not purchase_button.pressed.is_connected(_on_purchase_pressed):
			purchase_button.pressed.connect(_on_purchase_pressed)
	if cancel_button:
		if not cancel_button.pressed.is_connected(_on_cancel_pressed):
			cancel_button.pressed.connect(_on_cancel_pressed)
	if file_dialog:
		if not file_dialog.file_selected.is_connected(_on_file_selected):
			file_dialog.file_selected.connect(_on_file_selected)
	
	# Настройка FileDialog
	if file_dialog:
		file_dialog.add_filter("*.png", "PNG Images")
		file_dialog.add_filter("*.jpg", "JPG Images")
		file_dialog.add_filter("*.jpeg", "JPEG Images")
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE

func setup(seg_id: String, price: int, data: WallData = null) -> void:
	"""
	Настраивает диалог для конкретного сегмента.
	"""
	segment_id = seg_id
	segment_price = price
	wall_data = data
	
	# Обновляем UI цены
	if price_label:
		price_label.text = "Цена: %d coin" % price
	
	# Обновляем статус сегмента
	if status_label:
		var status_text: String = "Статус: Свободен"
		if wall_data:
			var seg_data: Dictionary = wall_data.get_segment(seg_id)
			var first_owner: String = str(seg_data.get("first_owner", ""))
			var purchase_date: int = int(seg_data.get("purchase_date", 0))
			
			if first_owner != "":
				status_text = "Владелец: %s" % first_owner
				if purchase_date > 0:
					var date = Time.get_datetime_dict_from_unix_time(purchase_date)
					status_text += "\nДата покупки: %02d.%02d.%04d" % [date.day, date.month, date.year]
			else:
				status_text = "Статус: Свободен"
		
		status_label.text = status_text
	
	# Проверяем баланс игрока
	if Engine.has_singleton("GameState"):
		var player_coins = GameState.score
		if purchase_button:
			if player_coins < price:
				purchase_button.disabled = true
				purchase_button.text = "Недостаточно монет"
			else:
				purchase_button.disabled = false
				purchase_button.text = "Купить"
	
	# Сбрасываем поля
	selected_image_path = ""
	if image_path_label:
		image_path_label.text = "Изображение не выбрано"
	if link_line_edit:
		link_line_edit.text = ""
	
	# Выбираем первую сторону по умолчанию
	if side_option:
		side_option.selected = 0

func _on_load_image_pressed() -> void:
	if file_dialog:
		file_dialog.popup_centered(Vector2(800, 600))

func _on_file_selected(path: String) -> void:
	selected_image_path = path
	if image_path_label:
		# Показываем только имя файла
		var file_name = path.get_file()
		image_path_label.text = "Изображение: " + file_name

func _on_purchase_pressed() -> void:
	if segment_id.is_empty():
		return
	
	# Получаем выбранную сторону
	var selected_side: String = available_sides[side_option.selected] if side_option.selected >= 0 else "front"
	
	# Получаем ссылку
	var link: String = link_line_edit.text.strip_edges() if link_line_edit else ""
	
	# Эмитируем сигнал с данными покупки
	purchase_confirmed.emit(segment_id, selected_side, selected_image_path, link)
	
	# Закрываем диалог
	hide()

func _on_cancel_pressed() -> void:
	hide()
