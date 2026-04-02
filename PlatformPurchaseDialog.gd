extends AcceptDialog

signal purchase_confirmed(
	platform_ids: Array,
	platform_type: String,
	image_path: String,
	link: String,
	quantity: int,
	duration_enabled: bool,
	duration_days: int
)

var selected_platform_ids: Array[String] = []
var selected_image_path: String = ""
var request_timestamp: int = 0

@onready var count_label: Label = get_node_or_null("VBox/CountLabel")
@onready var type_option: OptionButton = get_node_or_null("VBox/TypeContainer/TypeOption")
@onready var image_path_label: Label = get_node_or_null("VBox/ImageContainer/ImagePathLabel")
@onready var preview_rect: TextureRect = get_node_or_null("VBox/ImageContainer/Preview")
@onready var load_image_button: Button = get_node_or_null("VBox/ImageContainer/LoadImageButton")
@onready var link_edit: LineEdit = get_node_or_null("VBox/LinkContainer/LinkEdit")
@onready var duration_toggle: CheckBox = get_node_or_null("VBox/DurationContainer/DurationToggle")
@onready var duration_days_spin: SpinBox = get_node_or_null("VBox/DurationContainer/DurationDaysSpin")
@onready var quantity_spin: SpinBox = get_node_or_null("VBox/QuantityContainer/QuantitySpin")
@onready var buy_button: Button = get_node_or_null("VBox/Buttons/BuyButton")
@onready var cancel_button: Button = get_node_or_null("VBox/Buttons/CancelButton")

func _ready() -> void:
	if type_option:
		type_option.clear()
		for t in ["normal", "crumbling", "short", "long", "special"]:
			type_option.add_item(t)
	if load_image_button:
		load_image_button.pressed.connect(_on_load_image_pressed)
	if duration_toggle:
		duration_toggle.toggled.connect(_on_duration_toggled)
	if buy_button:
		buy_button.pressed.connect(_on_buy_pressed)
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)
	_update_ui()

func setup(platform_ids: Array) -> void:
	selected_platform_ids.clear()
	for id_val in platform_ids:
		var id := str(id_val).strip_edges()
		if id != "" and id not in selected_platform_ids:
			selected_platform_ids.append(id)
	request_timestamp = Time.get_unix_time_from_system()
	if quantity_spin:
		quantity_spin.value = selected_platform_ids.size()
		quantity_spin.editable = false
	_update_ui()

func get_request_timestamp() -> int:
	return request_timestamp

func _update_ui() -> void:
	if count_label:
		count_label.text = "Выбрано платформ: %d" % selected_platform_ids.size()
	if image_path_label:
		image_path_label.text = "Изображение: %s" % (selected_image_path.get_file() if selected_image_path != "" else "не выбрано")
	if duration_days_spin and duration_toggle:
		duration_days_spin.editable = duration_toggle.button_pressed
	if buy_button:
		buy_button.disabled = selected_platform_ids.is_empty()

func _on_duration_toggled(enabled: bool) -> void:
	if duration_days_spin:
		duration_days_spin.editable = enabled

func _on_load_image_pressed() -> void:
	var filters: PackedStringArray = PackedStringArray(["*.png", "*.jpg", "*.jpeg", "*.webp"])
	DisplayServer.file_dialog_show(
		"Выберите изображение платформы",
		"",
		"",
		false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		filters,
		_on_file_dialog_result
	)

func _on_file_dialog_result(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	selected_image_path = selected_paths[0]
	if preview_rect:
		var texture: Texture2D = load(selected_image_path) as Texture2D
		if texture:
			preview_rect.texture = texture
	_update_ui()

func _on_buy_pressed() -> void:
	var type_text: String = "normal"
	if type_option and type_option.selected >= 0:
		type_text = type_option.get_item_text(type_option.selected)
	var link_text: String = link_edit.text.strip_edges() if link_edit else ""
	var duration_enabled: bool = duration_toggle.button_pressed if duration_toggle else false
	var duration_days: int = int(duration_days_spin.value) if duration_days_spin else 0
	var qty: int = int(quantity_spin.value) if quantity_spin else selected_platform_ids.size()
	purchase_confirmed.emit(selected_platform_ids, type_text, selected_image_path, link_text, qty, duration_enabled, duration_days)
	hide()

func _on_cancel_pressed() -> void:
	hide()
