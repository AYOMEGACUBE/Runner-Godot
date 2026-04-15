extends AcceptDialog

signal purchase_confirmed(
	platform_ids: Array,
	platform_type: String,
	platform_size: String,
	image_path: String,
	image_path_jump_down: String,
	link: String,
	quantity: int,
	height_level: int,
	duration_enabled: bool,
	duration_days: int
)

var selected_platform_ids: Array[String] = []
var selected_image_path: String = ""
var selected_image_path_jump_down: String = ""
var request_timestamp: int = 0

const _PREVIEW_MIN: Vector2 = Vector2(200, 44)

var _purchase_confirm: ConfirmationDialog = null

@onready var count_label: Label = get_node_or_null("VBox/CountLabel")
@onready var balance_label: Label = get_node_or_null("VBox/BalanceLabel")
@onready var cost_label: Label = get_node_or_null("VBox/CostLabel")
@onready var type_option: OptionButton = get_node_or_null("VBox/TypeContainer/TypeOption")
@onready var size_option: OptionButton = get_node_or_null("VBox/SizeContainer/SizeOption")
@onready var height_option: OptionButton = get_node_or_null("VBox/HeightContainer/HeightOption")
@onready var availability_label: Label = get_node_or_null("VBox/AvailabilityLabel")
@onready var queue_label: Label = get_node_or_null("VBox/QueueLabel")
@onready var image_path_label: Label = get_node_or_null("VBox/ImageContainer/ImagePathLabel")
@onready var image_path_label_jump_down: Label = get_node_or_null("VBox/ImageContainer/ImagePathLabelJumpDown")
@onready var preview_rect: TextureRect = get_node_or_null("VBox/ImageContainer/Preview")
@onready var preview_rect_jump_down: TextureRect = get_node_or_null("VBox/ImageContainer/PreviewJumpDown")
@onready var load_image_button: Button = get_node_or_null("VBox/ImageContainer/LoadImageButton")
@onready var load_image_button_jump_down: Button = get_node_or_null("VBox/ImageContainer/LoadImageButtonJumpDown")
@onready var link_edit: LineEdit = get_node_or_null("VBox/LinkContainer/LinkEdit")
@onready var duration_toggle: CheckBox = get_node_or_null("VBox/DurationContainer/DurationToggle")
@onready var duration_days_spin: SpinBox = get_node_or_null("VBox/DurationContainer/DurationDaysSpin")
@onready var quantity_spin: SpinBox = get_node_or_null("VBox/QuantityContainer/QuantitySpin")
@onready var buy_button: Button = get_node_or_null("VBox/Buttons/BuyButton")
@onready var cancel_button: Button = get_node_or_null("VBox/Buttons/CancelButton")
@onready var file_dialog_jump_up: FileDialog = get_node_or_null("FileDialogJumpUp")
@onready var file_dialog_jump_down: FileDialog = get_node_or_null("FileDialogJumpDown")

func _pm() -> Node:
	return get_node_or_null("/root/PurchaseManager")


func _gs() -> Node:
	return get_node_or_null("/root/GameState")


func _ready() -> void:
	# We don't use the built-in AcceptDialog OK button; dialog has its own Buy/Cancel.
	var ok_btn: Button = get_ok_button()
	if ok_btn:
		ok_btn.visible = false
	if type_option:
		type_option.clear()
		for t in ["normal", "crumbling", "decoy"]:
			type_option.add_item(t)
	if size_option:
		size_option.clear()
		size_option.add_item("small (64x64)")
		size_option.add_item("medium (128x64)")
		size_option.add_item("large (256x64)")
	if height_option:
		height_option.clear()
		for lvl in range(1, 8):
			height_option.add_item("Уровень %d" % lvl)
	if load_image_button:
		load_image_button.pressed.connect(_on_load_image_pressed)
	if load_image_button_jump_down:
		load_image_button_jump_down.pressed.connect(_on_load_image_jump_down_pressed)
	if file_dialog_jump_up and not file_dialog_jump_up.file_selected.is_connected(_on_jump_up_file_selected):
		file_dialog_jump_up.file_selected.connect(_on_jump_up_file_selected)
		file_dialog_jump_up.use_native_dialog = true
	if file_dialog_jump_down and not file_dialog_jump_down.file_selected.is_connected(_on_jump_down_file_selected):
		file_dialog_jump_down.file_selected.connect(_on_jump_down_file_selected)
		file_dialog_jump_down.use_native_dialog = true
	if duration_toggle:
		duration_toggle.button_pressed = true
		duration_toggle.toggled.connect(_on_duration_toggled)
	if quantity_spin:
		quantity_spin.value_changed.connect(func(_v: float) -> void: _update_ui())
	if duration_days_spin:
		duration_days_spin.value_changed.connect(func(_v: float) -> void: _update_ui())
	if type_option:
		type_option.item_selected.connect(func(_i: int) -> void: _update_ui())
	if size_option:
		size_option.item_selected.connect(func(_i: int) -> void: _update_ui())
	if height_option:
		height_option.item_selected.connect(func(_i: int) -> void: _update_ui())
	if buy_button:
		buy_button.pressed.connect(_on_buy_pressed)
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)
	_setup_purchase_confirm_dialog()
	_update_ui()


func _setup_purchase_confirm_dialog() -> void:
	if _purchase_confirm != null:
		return
	_purchase_confirm = ConfirmationDialog.new()
	_purchase_confirm.name = "PlatformPurchaseConfirm"
	_purchase_confirm.title = "Подтверждение покупки"
	_purchase_confirm.ok_button_text = "Купить"
	_purchase_confirm.cancel_button_text = "Назад"
	_purchase_confirm.dialog_text = "Вы уверены, что хотите оформить покупку платформ?\n\nСредства списываются с кошелька. Покупка не подлежит возврату."
	_purchase_confirm.exclusive = true
	add_child(_purchase_confirm)
	_purchase_confirm.confirmed.connect(_on_purchase_really_confirmed)

func setup(platform_ids: Array) -> void:
	selected_platform_ids.clear()
	selected_image_path = ""
	selected_image_path_jump_down = ""
	if preview_rect:
		preview_rect.texture = null
	if preview_rect_jump_down:
		preview_rect_jump_down.texture = null
	for id_val in platform_ids:
		var id := str(id_val).strip_edges()
		if id != "" and id not in selected_platform_ids:
			selected_platform_ids.append(id)
	request_timestamp = Time.get_unix_time_from_system()
	if quantity_spin:
		if selected_platform_ids.is_empty():
			quantity_spin.editable = true
		else:
			quantity_spin.value = selected_platform_ids.size()
			quantity_spin.editable = false
	_update_ui()

func get_request_timestamp() -> int:
	return request_timestamp

func _update_ui() -> void:
	if count_label:
		if selected_platform_ids.is_empty():
			count_label.text = "Покупка платформ (по количеству)"
		else:
			count_label.text = "Выбрано платформ: %d" % selected_platform_ids.size()
	if image_path_label:
		image_path_label.text = "Изображение: %s" % (selected_image_path.get_file() if selected_image_path != "" else "не выбрано")
	if image_path_label_jump_down:
		image_path_label_jump_down.text = "Доп. изображение: %s" % (selected_image_path_jump_down.get_file() if selected_image_path_jump_down != "" else "не выбрано")
	if duration_days_spin and duration_toggle:
		duration_days_spin.editable = duration_toggle.button_pressed
	if balance_label:
		var gs: Node = _gs()
		var bal: int = int(gs.call("get_coins")) if gs != null and gs.has_method("get_coins") else 0
		balance_label.text = "Баланс: %d" % bal
	if cost_label:
		var qty: int = int(quantity_spin.value) if quantity_spin else 1
		qty = clampi(qty, 1, 10)
		var size_key: String = _get_selected_size_key()
		var lvl: int = _get_selected_height_level()
		var days: int = int(duration_days_spin.value) if duration_days_spin and duration_toggle and duration_toggle.button_pressed else 1
		var pricing: Dictionary = {}
		var pm: Node = _pm()
		if pm != null and pm.has_method("estimate_platform_purchase_total"):
			pricing = pm.call("estimate_platform_purchase_total", qty, size_key, lvl, days)
		var daily: int = int(pricing.get("daily_price", 0))
		var total: int = int(pricing.get("total", 0))
		cost_label.text = "Стоимость: %d (=%d/день × %d дн × %d)" % [total, daily, days, qty]
	if availability_label:
		var lvl: int = _get_selected_height_level()
		var qty_a: int = int(quantity_spin.value) if quantity_spin else 1
		qty_a = clampi(qty_a, 1, 10)
		var pm2: Node = _pm()
		if pm2 != null and pm2.has_method("get_platform_availability"):
			var av: Dictionary = pm2.call("get_platform_availability", lvl, qty_a)
			if bool(av.get("can_buy", false)):
				availability_label.text = "Доступность: Можно купить (%d слотов)" % int(av.get("available_slots", 0))
			else:
				availability_label.text = "Доступность: Занято"
			if queue_label:
				queue_label.text = "Ваши платформы появятся через %d платформ" % int(av.get("next_after", 0))
		else:
			availability_label.text = "Доступность: нет данных"
			if queue_label:
				queue_label.text = "Ваши платформы появятся через N платформ"
	if buy_button:
		var qok: bool = true
		if quantity_spin:
			var q: int = int(quantity_spin.value)
			qok = q >= 1 and q <= 10
		var days_ok: bool = true
		if duration_days_spin and duration_toggle and duration_toggle.button_pressed:
			days_ok = int(duration_days_spin.value) >= 1
		buy_button.disabled = not (qok and days_ok)
	_sync_image_previews()


func _sync_image_previews() -> void:
	if preview_rect:
		var has_u: bool = preview_rect.texture != null
		preview_rect.visible = has_u
		preview_rect.custom_minimum_size = _PREVIEW_MIN if has_u else Vector2.ZERO
	if preview_rect_jump_down:
		var has_d: bool = preview_rect_jump_down.texture != null
		preview_rect_jump_down.visible = has_d
		preview_rect_jump_down.custom_minimum_size = _PREVIEW_MIN if has_d else Vector2.ZERO


func _on_duration_toggled(enabled: bool) -> void:
	if duration_days_spin:
		duration_days_spin.editable = enabled

func _on_load_image_pressed() -> void:
	if file_dialog_jump_up:
		file_dialog_jump_up.popup_centered_ratio(0.85)
		return
	var filters: PackedStringArray = PackedStringArray(["*.png", "*.jpg", "*.jpeg", "*.webp"])
	DisplayServer.file_dialog_show("Выберите изображение платформы", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, _on_file_dialog_result_jump_up)

func _on_load_image_jump_down_pressed() -> void:
	if file_dialog_jump_down:
		file_dialog_jump_down.popup_centered_ratio(0.85)
		return
	var filters: PackedStringArray = PackedStringArray(["*.png", "*.jpg", "*.jpeg", "*.webp"])
	DisplayServer.file_dialog_show("Выберите jump(1) изображение платформы", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, _on_file_dialog_result_jump_down)

func _on_file_dialog_result_jump_up(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	selected_image_path = selected_paths[0]
	if preview_rect:
		var texture: Texture2D = load(selected_image_path) as Texture2D
		if texture:
			preview_rect.texture = texture
	_update_ui()

func _on_file_dialog_result_jump_down(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	selected_image_path_jump_down = selected_paths[0]
	if preview_rect_jump_down:
		var texture: Texture2D = load(selected_image_path_jump_down) as Texture2D
		if texture:
			preview_rect_jump_down.texture = texture
	_update_ui()


func _on_jump_up_file_selected(path: String) -> void:
	selected_image_path = path
	if preview_rect:
		var texture: Texture2D = load(selected_image_path) as Texture2D
		if texture:
			preview_rect.texture = texture
	_update_ui()


func _on_jump_down_file_selected(path: String) -> void:
	selected_image_path_jump_down = path
	if preview_rect_jump_down:
		var texture: Texture2D = load(selected_image_path_jump_down) as Texture2D
		if texture:
			preview_rect_jump_down.texture = texture
	_update_ui()

func _on_buy_pressed() -> void:
	if buy_button and buy_button.disabled:
		return
	if _purchase_confirm == null:
		_setup_purchase_confirm_dialog()
	if _purchase_confirm:
		_purchase_confirm.popup_centered()


func _on_purchase_really_confirmed() -> void:
	var type_text: String = "normal"
	if type_option and type_option.selected >= 0:
		type_text = type_option.get_item_text(type_option.selected)
	var link_text: String = link_edit.text.strip_edges() if link_edit else ""
	var size_text: String = _get_selected_size_key()
	var duration_enabled: bool = duration_toggle.button_pressed if duration_toggle else false
	var duration_days: int = int(duration_days_spin.value) if duration_days_spin else 0
	var qty: int = int(quantity_spin.value) if quantity_spin else 1
	qty = clampi(qty, 1, 10)
	var lvl: int = _get_selected_height_level()
	purchase_confirmed.emit(
		selected_platform_ids,
		type_text,
		size_text,
		selected_image_path,
		selected_image_path_jump_down,
		link_text,
		qty,
		lvl,
		duration_enabled,
		duration_days
	)
	hide()

func _on_cancel_pressed() -> void:
	hide()


func _get_selected_size_key() -> String:
	if size_option == null or size_option.selected < 0:
		return "medium"
	var txt: String = size_option.get_item_text(size_option.selected).to_lower()
	if txt.begins_with("small"):
		return "small"
	if txt.begins_with("large"):
		return "large"
	return "medium"


func _get_selected_height_level() -> int:
	if height_option == null:
		return 1
	return clampi(height_option.selected + 1, 1, 7)
