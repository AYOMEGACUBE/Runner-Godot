extends AcceptDialog
# ============================================================================
# BulkPurchaseDialog.gd
# Диалог для покупки нескольких сегментов
# ============================================================================

signal purchase_confirmed(segment_ids: Array, side: String, image_paths: Dictionary, links: Dictionary, corporate_mode: bool, group_id: String)
signal location_selection_started()
signal preview_requested()
signal images_upload_requested()

var quantity: int = 1
var start_segment_id: String = ""
var selected_segment_ids: Array[String] = []
var selected_side: String = "front"
var wall_data: WallData = null
var selected_links: Dictionary = {}  # segment_id -> link

# UI элементы
@onready var quantity_spinbox: SpinBox = get_node_or_null("VBoxContainer/QuantityContainer/QuantitySpinBox")
@onready var select_location_button: Button = get_node_or_null("VBoxContainer/LocationContainer/SelectLocationButton")
@onready var selected_location_label: Label = get_node_or_null("VBoxContainer/LocationContainer/SelectedLocationLabel")
@onready var price_label: Label = get_node_or_null("VBoxContainer/PriceLabel")
@onready var balance_label: Label = get_node_or_null("VBoxContainer/BalanceLabel")
@onready var purchase_button: Button = get_node_or_null("VBoxContainer/ButtonsContainer/PurchaseButton")
@onready var cancel_button: Button = get_node_or_null("VBoxContainer/ButtonsContainer/CancelButton")
@onready var preview_button: Button = get_node_or_null("VBoxContainer/ImageContainer/PreviewButton")
@onready var upload_images_button: Button = get_node_or_null("VBoxContainer/ImageContainer/UploadImagesButton")
@onready var link_line_edit: LineEdit = get_node_or_null("VBoxContainer/LinkContainer/LinkLineEdit")
@onready var privacy_checkbox: CheckBox = get_node_or_null("VBoxContainer/PrivacyContainer/PrivacyCheckBox")

var location_selection_mode: bool = false
var selected_image_paths: Dictionary = {}  # segment_id -> image_path
var _privacy_accepted: bool = false
var corporate_mode_enabled: bool = false
var corporate_group_id: String = ""

func _ready() -> void:
	call_deferred("_init_ui")

func _init_ui() -> void:
	if quantity_spinbox:
		quantity_spinbox.value_changed.connect(_on_quantity_changed)
	
	if select_location_button:
		select_location_button.pressed.connect(_on_select_location_pressed)
	
	if preview_button:
		preview_button.pressed.connect(_on_preview_pressed)
	
	if upload_images_button:
		upload_images_button.pressed.connect(_on_upload_images_pressed)
	
	if purchase_button:
		purchase_button.pressed.connect(_on_purchase_pressed)
	
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)
	
	if privacy_checkbox:
		privacy_checkbox.toggled.connect(_on_privacy_checkbox_toggled)
	
	_update_price_display()
	_update_buttons_state()  # Инициализируем состояние кнопок

func setup(data: WallData = null, side: String = "front") -> void:
	wall_data = data
	selected_side = side
	start_segment_id = ""
	selected_segment_ids.clear()
	quantity = 1
	_privacy_accepted = false
	if quantity_spinbox:
		quantity_spinbox.value = 1
	if selected_location_label:
		selected_location_label.text = "Локация не выбрана"
	if privacy_checkbox:
		privacy_checkbox.button_pressed = false
	
	# Обновляем баланс
	if balance_label and Engine.has_singleton("GameState"):
		var balance = GameState.score
		balance_label.text = "Ваш баланс: %d coin" % balance
	
	# Сбрасываем выбранные изображения и ссылки
	selected_image_paths.clear()
	corporate_mode_enabled = false
	corporate_group_id = ""
	selected_links.clear()
	if upload_images_button:
		upload_images_button.disabled = selected_segment_ids.size() == 0
		upload_images_button.text = "Загрузить"
	if link_line_edit:
		link_line_edit.text = ""
	
	_update_price_display()

func _on_quantity_changed(value: float) -> void:
	quantity = int(value)
	_update_price_display()

func _on_preview_pressed() -> void:
	"""Показать предпросмотр выбранных сегментов."""
	if selected_segment_ids.size() > 0 or start_segment_id != "":
		emit_signal("preview_requested")

func _on_select_location_pressed() -> void:
	"""Включает режим выбора сегментов на карте (drag-жест)."""
	location_selection_mode = true
	if selected_location_label:
		selected_location_label.text = "Зажмите и ведите для выбора сегментов..."
	
	# Эмитируем сигнал для CubeView чтобы включить режим выбора
	# CubeView будет слушать этот сигнал и обрабатывать клики
	if has_signal("location_selection_started"):
		emit_signal("location_selection_started")

func set_selected_location(segment_id: String, x: int, y: int) -> void:
	"""Устанавливает одну выбранную локацию (для обратной совместимости)."""
	set_selected_segments([segment_id])
	
	if selected_location_label:
		selected_location_label.text = "Выбрано: X=%d, Y=%d (ID: %s)" % [x, y, segment_id]

func set_selected_segments(segment_ids: Array) -> void:
	"""Устанавливает выбранные сегменты (после drag-выбора)."""
	selected_segment_ids.clear()
	for id_val in segment_ids:
		var s: String = str(id_val)
		if s != "" and s not in selected_segment_ids:
			selected_segment_ids.append(s)
	quantity = selected_segment_ids.size()
	if quantity > 0:
		start_segment_id = selected_segment_ids[0]
	if quantity_spinbox:
		quantity_spinbox.value = quantity
	if selected_location_label:
		selected_location_label.text = "Выбрано сегментов: %d" % quantity
	if upload_images_button:
		upload_images_button.disabled = selected_segment_ids.size() == 0
	_update_price_display()

func _update_price_display() -> void:
	var total_price = 0
	if wall_data and selected_segment_ids.size() > 0:
		for seg_id in selected_segment_ids:
			total_price += wall_data.get_segment_price(seg_id)
	elif wall_data and start_segment_id != "":
		var coords = start_segment_id.split("_")
		if coords.size() >= 2:
			var start_x = int(coords[0])
			var start_y = int(coords[1])
			for i in range(quantity):
				var seg_x = start_x + i
				var seg_id = "%d_%d" % [seg_x, start_y]
				total_price += wall_data.get_segment_price(seg_id)
	
	# Предпросмотр активен, если есть хотя бы выбранные сегменты (независимо от цены и wall_data)
	var has_segments: bool = selected_segment_ids.size() > 0 or start_segment_id != ""
	if preview_button:
		preview_button.disabled = not has_segments
	
	if total_price == 0:
		if price_label:
			price_label.text = "Общая стоимость: выберите сегменты"
		if purchase_button:
			purchase_button.disabled = true
		return
	
	if price_label:
		price_label.text = "Общая стоимость: %d coin" % total_price
	# Проверяем баланс и согласие с политикой
	if purchase_button and Engine.has_singleton("GameState"):
		var balance = GameState.score
		var can_purchase: bool = balance >= total_price and quantity > 0 and _privacy_accepted
		purchase_button.disabled = not can_purchase
		if balance < total_price:
			price_label.text += " (недостаточно монет)"
		elif not _privacy_accepted:
			price_label.text += " (требуется согласие с политикой)"
	
	# Обновляем состояние всех кнопок в зависимости от согласия
	_update_buttons_state()

func get_preview_image_paths() -> Dictionary:
	"""Возвращает словарь segment_id -> image_path для предпросмотра. Если загружена одна картинка для всех — в словаре один путь на каждый segment_id."""
	return selected_image_paths.duplicate()

func get_selected_side() -> String:
	return selected_side

func get_preview_segment_ids() -> Array:
	"""Возвращает массив ID сегментов для предпросмотра."""
	if selected_segment_ids.size() > 0:
		var arr: Array = []
		for sid in selected_segment_ids:
			arr.append(sid)
		return arr
	if start_segment_id != "" and wall_data:
		var coords = start_segment_id.split("_")
		if coords.size() >= 2:
			var start_x = int(coords[0])
			var start_y = int(coords[1])
			var arr: Array = []
			for i in range(quantity):
				arr.append("%d_%d" % [start_x + i, start_y])
			return arr
	return []

func _on_upload_images_pressed() -> void:
	"""Открывает диалог загрузки изображений."""
	if selected_segment_ids.size() > 0:
		emit_signal("images_upload_requested")

func set_selected_images(image_paths: Dictionary) -> void:
	"""Устанавливает выбранные изображения для сегментов."""
	selected_image_paths = image_paths.duplicate()
	if upload_images_button:
		if selected_image_paths.size() > 0:
			upload_images_button.text = "Изображения выбраны (%d)" % selected_image_paths.size()
		else:
			upload_images_button.text = "Загрузить"
	# Обновляем состояние Preview кнопки после загрузки изображений
	_update_price_display()

func set_image_selection_metadata(corporate_mode: bool, group_id: String) -> void:
	corporate_mode_enabled = corporate_mode
	corporate_group_id = group_id

func _on_privacy_checkbox_toggled(button_pressed: bool) -> void:
	"""Обрабатывает изменение состояния чекбокса согласия."""
	_privacy_accepted = button_pressed
	print("BulkPurchaseDialog: Согласие с политикой конфиденциальности: ", "да" if _privacy_accepted else "нет")
	_update_price_display()

func _update_buttons_state() -> void:
	"""Обновляет состояние всех кнопок в зависимости от согласия с политикой."""
	if _privacy_accepted:
		# Если согласие дано, деактивируем все кнопки кроме "Купить"
		if quantity_spinbox:
			quantity_spinbox.editable = false
		if select_location_button:
			select_location_button.disabled = true
		if preview_button:
			preview_button.disabled = true
		if upload_images_button:
			upload_images_button.disabled = true
		if link_line_edit:
			link_line_edit.editable = false
		if cancel_button:
			cancel_button.disabled = true
	else:
		# Если согласие не дано, активируем все кнопки
		if quantity_spinbox:
			quantity_spinbox.editable = true
		if select_location_button:
			select_location_button.disabled = false
		if preview_button:
			preview_button.disabled = not (selected_segment_ids.size() > 0 or start_segment_id != "")
		if upload_images_button:
			upload_images_button.disabled = selected_segment_ids.size() == 0
		if link_line_edit:
			link_line_edit.editable = true
		if cancel_button:
			cancel_button.disabled = false

func _on_purchase_pressed() -> void:
	"""Обрабатывает нажатие кнопки 'Купить' - выполняет покупку сегментов."""
	# Проверяем согласие с политикой
	if not _privacy_accepted:
		push_warning("BulkPurchaseDialog: Покупка невозможна без согласия с политикой конфиденциальности")
		return
	
	# Проверяем баланс
	if not Engine.has_singleton("GameState"):
		push_error("BulkPurchaseDialog: GameState недоступен!")
		return
	
	var total_price = 0
	if wall_data and selected_segment_ids.size() > 0:
		for seg_id in selected_segment_ids:
			total_price += wall_data.get_segment_price(seg_id)
	elif wall_data and start_segment_id != "":
		var coords = start_segment_id.split("_")
		if coords.size() >= 2:
			var start_x = int(coords[0])
			var start_y = int(coords[1])
			for i in range(quantity):
				var seg_id = "%d_%d" % [start_x + i, start_y]
				total_price += wall_data.get_segment_price(seg_id)
	
	var balance = GameState.score
	if balance < total_price:
		push_warning("BulkPurchaseDialog: Недостаточно монет для покупки! Баланс: %d, требуется: %d" % [balance, total_price])
		return
	
	var ids_to_buy: Array = selected_segment_ids if selected_segment_ids.size() > 0 else []
	if ids_to_buy.is_empty() and start_segment_id != "":
		var coords = start_segment_id.split("_")
		if coords.size() >= 2:
			var start_x = int(coords[0])
			var start_y = int(coords[1])
			for i in range(quantity):
				ids_to_buy.append("%d_%d" % [start_x + i, start_y])
	if ids_to_buy.is_empty():
		push_warning("BulkPurchaseDialog: Нет сегментов для покупки!")
		return
	
	print("BulkPurchaseDialog: Начинаем покупку ", ids_to_buy.size(), " сегментов за ", total_price, " монет")
	
	# Собираем ссылки для всех сегментов (если указана одна ссылка для всех)
	var links_dict: Dictionary = {}
	var link_text: String = link_line_edit.text.strip_edges() if link_line_edit else ""
	if link_text != "":
		for seg_id in ids_to_buy:
			links_dict[str(seg_id)] = link_text
	
	# Эмитируем сигнал покупки - логика покупки будет обработана в CubeView
	purchase_confirmed.emit(ids_to_buy, selected_side, selected_image_paths, links_dict, corporate_mode_enabled, corporate_group_id)
	hide()

func _on_cancel_pressed() -> void:
	location_selection_mode = false
	hide()
