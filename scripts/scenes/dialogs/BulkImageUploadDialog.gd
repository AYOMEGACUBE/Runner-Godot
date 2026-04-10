extends AcceptDialog

signal images_selected(image_paths: Dictionary, corporate_mode: bool, group_id: String)
signal single_image_selected(image_path: String)

const SEGMENT_SIZE: int = 48

var segment_ids: Array[String] = []
var selected_images: Dictionary = {}
var single_image_path: String = ""
var use_single_image: bool = false
var use_unified_mode: bool = false
var selected_side_id: String = "front"
var corporate_group_id: String = ""

@onready var mode_container: HBoxContainer = $VBoxContainer/ModeContainer
@onready var single_image_button: Button = $VBoxContainer/ModeContainer/SingleImageButton
@onready var unified_image_button: Button = $VBoxContainer/ModeContainer/UnifiedImageButton
@onready var separate_images_button: Button = $VBoxContainer/ModeContainer/SeparateImagesButton
@onready var single_image_container: VBoxContainer = $VBoxContainer/SingleImageContainer
@onready var single_image_label: Label = $VBoxContainer/SingleImageContainer/SingleImageLabel
@onready var single_image_load_button: Button = $VBoxContainer/SingleImageContainer/SingleImageLoadButton
@onready var separate_images_container: VBoxContainer = $VBoxContainer/SeparateImagesContainer
@onready var separate_images_scroll: ScrollContainer = $VBoxContainer/SeparateImagesContainer/ScrollContainer
@onready var separate_images_list: VBoxContainer = $VBoxContainer/SeparateImagesContainer/ScrollContainer/ImageList
@onready var confirm_button: Button = $VBoxContainer/ButtonsContainer/ConfirmButton
@onready var cancel_button: Button = $VBoxContainer/ButtonsContainer/CancelButton

var _current_editing_segment_id: String = ""

func _ready() -> void:
	get_ok_button().visible = false
	if single_image_button:
		single_image_button.pressed.connect(_on_single_image_mode_pressed)
	if unified_image_button:
		unified_image_button.pressed.connect(_on_unified_mode_pressed)
	if separate_images_button:
		separate_images_button.pressed.connect(_on_separate_images_mode_pressed)
	if single_image_load_button:
		single_image_load_button.pressed.connect(_on_single_image_load_pressed)
	if confirm_button:
		confirm_button.pressed.connect(_on_confirm_pressed)
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)

func setup(seg_ids: Array, side_id: String = "front") -> void:
	segment_ids.clear()
	for sid in seg_ids:
		segment_ids.append(str(sid))
	selected_side_id = side_id

	selected_images.clear()
	single_image_path = ""
	use_single_image = false
	use_unified_mode = false
	corporate_group_id = ""
	_current_editing_segment_id = ""

	_update_dialog_size()
	_show_mode_selection()
	_update_mode_buttons()
	_update_ui()

func get_segment_count() -> int:
	return segment_ids.size()

func _update_dialog_size() -> void:
	var segment_count: int = max(segment_ids.size(), 1)
	var dialog_width: int = 700
	var dialog_height: int = int(clamp(420 + segment_count * 34, 520, 820))
	size = Vector2i(dialog_width, dialog_height)

func _show_mode_selection() -> void:
	mode_container.visible = true
	single_image_container.visible = false
	separate_images_container.visible = false

func _update_mode_buttons() -> void:
	if single_image_button:
		single_image_button.text = "Одна картинка для всех одинаковая"
	if unified_image_button:
		unified_image_button.disabled = not _can_use_unified_mode()

func _can_use_unified_mode() -> bool:
	if segment_ids.size() < 2:
		return false
	# selected_side_id в этом диалоге один для всех выбранных сегментов,
	# проверка непрерывности обязательна.
	return _are_segments_contiguous(segment_ids)

func _are_segments_contiguous(ids: Array[String]) -> bool:
	if ids.is_empty():
		return false
	var set_ids: Dictionary = {}
	for sid in ids:
		set_ids[sid] = true
	var start_id: String = ids[0]
	var queue: Array[String] = [start_id]
	var visited: Dictionary = {}
	visited[start_id] = true
	var q_idx: int = 0
	while q_idx < queue.size():
		var current: String = queue[q_idx]
		q_idx += 1
		var p: Vector2i = _seg_to_xy(current)
		var neighbors: Array[String] = [
			"%d_%d" % [p.x + 1, p.y],
			"%d_%d" % [p.x - 1, p.y],
			"%d_%d" % [p.x, p.y + 1],
			"%d_%d" % [p.x, p.y - 1]
		]
		for n in neighbors:
			if set_ids.has(n) and not visited.has(n):
				visited[n] = true
				queue.append(n)
	return visited.size() == set_ids.size()

func _seg_to_xy(seg_id: String) -> Vector2i:
	var parts := seg_id.split("_")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))

func _on_single_image_mode_pressed() -> void:
	use_single_image = true
	use_unified_mode = false
	mode_container.visible = false
	single_image_container.visible = true
	separate_images_container.visible = false
	_update_ui()

func _on_unified_mode_pressed() -> void:
	if not _can_use_unified_mode():
		return
	use_single_image = false
	use_unified_mode = true
	mode_container.visible = false
	single_image_container.visible = false
	separate_images_container.visible = true
	separate_images_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_separate_segment_rows(segment_ids)
	_show_native_file_dialog()

func _on_separate_images_mode_pressed() -> void:
	use_single_image = false
	use_unified_mode = false
	mode_container.visible = false
	single_image_container.visible = false
	separate_images_container.visible = true
	separate_images_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_separate_segment_rows(segment_ids)
	_update_ui()
	if separate_images_scroll:
		separate_images_scroll.scroll_vertical = 0

func _build_separate_segment_rows(ids: Array) -> void:
	# Явная UI-логика для режима "отдельные картинки":
	# - показываем контейнер
	# - очищаем список
	# - создаём строку "segment_id + кнопка Выбрать" для каждого сегмента
	separate_images_container.visible = true
	separate_images_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_separate_images_list(ids)

func _build_separate_images_list(ids: Array) -> void:
	for child in separate_images_list.get_children():
		child.queue_free()
	for seg_id_val in ids:
		var seg_id: String = str(seg_id_val)
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 32)

		var segment_label := Label.new()
		segment_label.text = seg_id
		segment_label.custom_minimum_size = Vector2(260, 0)
		row.add_child(segment_label)

		var path_label := Label.new()
		path_label.name = "PathLabel_" + seg_id
		path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_label.text = selected_images.get(seg_id, "Не выбрано").get_file() if selected_images.has(seg_id) else "Не выбрано"
		row.add_child(path_label)

		var load_button := Button.new()
		load_button.text = "Выбрать"
		load_button.custom_minimum_size = Vector2(120, 0)
		load_button.pressed.connect(_on_segment_image_load_pressed.bind(seg_id))
		row.add_child(load_button)

		separate_images_list.add_child(row)

func _on_single_image_load_pressed() -> void:
	_show_native_file_dialog()

func _on_segment_image_load_pressed(seg_id: String) -> void:
	_current_editing_segment_id = seg_id
	_show_native_file_dialog()

func _show_native_file_dialog() -> void:
	var filters: PackedStringArray = PackedStringArray(["*.png", "*.jpg", "*.jpeg", "*.webp"])
	DisplayServer.file_dialog_show(
		"Выберите изображение",
		"",
		"",
		false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		filters,
		_on_file_dialog_result
	)

func _on_file_dialog_result(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if status and selected_paths.size() > 0:
		_on_file_selected(selected_paths[0])

func _on_file_selected(path: String) -> void:
	if use_single_image:
		single_image_path = path
		single_image_label.text = "Выбрано: " + path.get_file()
	elif use_unified_mode:
		_apply_unified_image(path)
	else:
		if _current_editing_segment_id != "":
			selected_images[_current_editing_segment_id] = path
			_build_separate_segment_rows(segment_ids)
	_current_editing_segment_id = ""
	_update_ui()

func _apply_unified_image(source_path: String) -> void:
	if segment_ids.is_empty():
		return
	var src := Image.new()
	if src.load(source_path) != OK:
		push_error("BulkImageUploadDialog: не удалось загрузить изображение для unified режима: " + source_path)
		return
	var min_x: int = 2147483647
	var min_y: int = 2147483647
	var max_x: int = -2147483648
	var max_y: int = -2147483648
	for sid in segment_ids:
		var p := _seg_to_xy(sid)
		min_x = min(min_x, p.x)
		min_y = min(min_y, p.y)
		max_x = max(max_x, p.x)
		max_y = max(max_y, p.y)
	var cols: int = max_x - min_x + 1
	var rows: int = max_y - min_y + 1
	var banner_w: int = cols * SEGMENT_SIZE
	var banner_h: int = rows * SEGMENT_SIZE
	var resized := src.duplicate()
	resized.resize(banner_w, banner_h, Image.INTERPOLATE_LANCZOS)
	var images_dir := "user://wall_images"
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("wall_images"):
		dir.make_dir("wall_images")
	corporate_group_id = "corp_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	selected_images.clear()
	for sid in segment_ids:
		var p := _seg_to_xy(sid)
		var tile_x: int = (p.x - min_x) * SEGMENT_SIZE
		var tile_y: int = (p.y - min_y) * SEGMENT_SIZE
		var tile := Image.create(SEGMENT_SIZE, SEGMENT_SIZE, false, Image.FORMAT_RGBA8)
		tile.blit_rect(resized, Rect2i(tile_x, tile_y, SEGMENT_SIZE, SEGMENT_SIZE), Vector2i.ZERO)
		var out_path := "%s/%s_%s.png" % [images_dir, corporate_group_id, sid.replace("-", "m")]
		if tile.save_png(out_path) == OK:
			selected_images[sid] = out_path
	_build_separate_segment_rows(segment_ids)

func _update_ui() -> void:
	if confirm_button:
		var can_confirm := false
		if use_single_image:
			can_confirm = single_image_path != ""
		else:
			can_confirm = selected_images.size() == segment_ids.size() and segment_ids.size() > 0
		confirm_button.disabled = not can_confirm

func _on_confirm_pressed() -> void:
	if use_single_image:
		single_image_selected.emit(single_image_path)
	else:
		images_selected.emit(selected_images.duplicate(), use_unified_mode, corporate_group_id if use_unified_mode else "")
	hide()

func _on_cancel_pressed() -> void:
	hide()
