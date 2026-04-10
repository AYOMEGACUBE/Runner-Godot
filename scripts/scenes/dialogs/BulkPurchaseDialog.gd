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
## [FIX] «front» в economy часто free (external 1); дефолт для UI — платная грань тайла до sync с WallRenderer.
var selected_side: String = "back"
var wall_data: WallData = null
var selected_links: Dictionary = {}  # segment_id -> link

# UI (пути через VBoxContainer; AcceptDialog/Window может менять дерево — дозаполняем в _resolve_ui_nodes)
var select_location_button: Button
var selected_location_label: Label
var price_label: Label
var balance_label: Label
var purchase_button: Button
var cancel_button: Button
var preview_button: Button
var upload_images_button: Button
var link_line_edit: LineEdit
var privacy_checkbox: CheckBox
var side_option: OptionButton

var location_selection_mode: bool = false
var selected_image_paths: Dictionary = {}  # segment_id -> image_path
var _privacy_accepted: bool = false
var corporate_mode_enabled: bool = false
var corporate_group_id: String = ""
var _side_locked_by_user: bool = false

var _purchase_confirm: ConfirmationDialog = null
var _pending_bulk_ids: Array = []

## Ссылка на ноду стены (CubeView): синхронизация грани тайла с WallRenderer._segment_sides
var _wall_root: Node2D = null

## Чтобы не засорять лог сотнями одинаковых строк за кадр
var _logged_balance_label_missing: bool = false
var _logged_gamestate_missing: bool = false

func _ready() -> void:
	# We don't use the built-in AcceptDialog OK button; dialog has its own Buy/Cancel.
	var ok_btn: Button = get_ok_button()
	if ok_btn:
		ok_btn.visible = false
	call_deferred("_init_ui")
	if not PurchaseManager.coins_updated.is_connected(_on_coins_updated):
		PurchaseManager.coins_updated.connect(_on_coins_updated)

func _resolve_ui_nodes() -> void:
	# Сначала уникальные имена сцены (%), затем пути, затем рекурсивный поиск (Window может сдвинуть иерархию)
	if balance_label == null:
		balance_label = get_node_or_null("%BalanceLabel") as Label
	if price_label == null:
		price_label = get_node_or_null("%PriceLabel") as Label
	if select_location_button == null:
		select_location_button = get_node_or_null("VBoxContainer/LocationContainer/SelectLocationButton") as Button
	if selected_location_label == null:
		selected_location_label = get_node_or_null("VBoxContainer/LocationContainer/SelectedLocationLabel") as Label
	if price_label == null:
		price_label = get_node_or_null("VBoxContainer/PriceLabel") as Label
	if balance_label == null:
		balance_label = get_node_or_null("VBoxContainer/BalanceLabel") as Label
	if purchase_button == null:
		purchase_button = get_node_or_null("VBoxContainer/ButtonsContainer/PurchaseButton") as Button
	if cancel_button == null:
		cancel_button = get_node_or_null("VBoxContainer/ButtonsContainer/CancelButton") as Button
	if preview_button == null:
		preview_button = get_node_or_null("VBoxContainer/ImageContainer/PreviewButton") as Button
	if upload_images_button == null:
		upload_images_button = get_node_or_null("VBoxContainer/ImageContainer/UploadImagesButton") as Button
	if link_line_edit == null:
		link_line_edit = get_node_or_null("VBoxContainer/LinkContainer/LinkLineEdit") as LineEdit
	if privacy_checkbox == null:
		privacy_checkbox = get_node_or_null("VBoxContainer/PrivacyContainer/PrivacyCheckBox") as CheckBox
	if side_option == null:
		side_option = get_node_or_null("VBoxContainer/SideContainer/SideOptionButton") as OptionButton
	# Fallback: Window/AcceptDialog может вложить контент иначе
	if balance_label == null:
		balance_label = find_child("BalanceLabel", true, false) as Label
	if price_label == null:
		price_label = find_child("PriceLabel", true, false) as Label
	if balance_label == null:
		balance_label = _find_label_by_node_name(self, "BalanceLabel")
	if price_label == null:
		price_label = _find_label_by_node_name(self, "PriceLabel")
	if balance_label == null:
		FileLogger.error("BulkPurchaseDialog: BalanceLabel not found under dialog root")
	if price_label == null:
		FileLogger.error("BulkPurchaseDialog: PriceLabel not found under dialog root")


func _find_label_by_node_name(root_node: Node, node_name: String) -> Label:
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == node_name and n is Label:
			return n as Label
		for c in n.get_children():
			stack.append(c)
	return null

func _init_ui() -> void:
	_resolve_ui_nodes()
	if side_option:
		if side_option.item_count == 0:
			for side_name in ["front", "back", "left", "right", "top", "bottom"]:
				side_option.add_item(side_name)
		side_option.item_selected.connect(_on_side_selected)
	
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
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)
	_setup_purchase_confirm_dialog()
	_update_price_display()
	_update_buttons_state()  # Инициализируем состояние кнопок


func _setup_purchase_confirm_dialog() -> void:
	if _purchase_confirm != null:
		return
	_purchase_confirm = ConfirmationDialog.new()
	_purchase_confirm.name = "BulkPurchaseConfirm"
	_purchase_confirm.title = "Подтверждение покупки"
	_purchase_confirm.ok_button_text = "Купить"
	_purchase_confirm.cancel_button_text = "Назад"
	_purchase_confirm.dialog_text = "Вы уверены, что хотите оформить покупку сторон сегментов?\n\nСредства списываются с кошелька. Покупка не подлежит возврату."
	_purchase_confirm.exclusive = true
	add_child(_purchase_confirm)
	_purchase_confirm.confirmed.connect(_on_bulk_purchase_really_confirmed)
	if not _purchase_confirm.canceled.is_connected(_on_bulk_purchase_confirm_canceled):
		_purchase_confirm.canceled.connect(_on_bulk_purchase_confirm_canceled)

func _on_visibility_changed() -> void:
	if visible:
		_resolve_ui_nodes()
		_refresh_balance_label()
		sync_purchase_side_from_wall()
		_update_price_display()


func _on_coins_updated(_new_balance: int) -> void:
	if not visible:
		return
	_refresh_balance_label()
	_update_price_display()

func _refresh_balance_label() -> void:
	if not visible:
		return
	if balance_label == null:
		_resolve_ui_nodes()
	if balance_label == null:
		if not _logged_balance_label_missing:
			FileLogger.error("BulkPurchaseDialog: balance_label is null after resolve")
			_logged_balance_label_missing = true
		return
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state == null:
		if not _logged_gamestate_missing:
			FileLogger.error("BulkPurchaseDialog: GameState NOT found at /root/GameState")
			_logged_gamestate_missing = true
		return
	if not game_state.has_method("get_coins"):
		if not _logged_gamestate_missing:
			FileLogger.error("BulkPurchaseDialog: GameState has no get_coins()")
			_logged_gamestate_missing = true
		return
	var coins: int = int(game_state.call("get_coins"))
	balance_label.text = "Ваш баланс: %d coin" % coins

func set_wall_root(wall: Node2D) -> void:
	_wall_root = wall


## [FIX] `side` — грань тайла для покупки (front/back/…), НЕ грань мегакуба из GameState. Пусто → «back» (paid) до sync.
func setup(data: WallData = null, segment_purchase_side: String = "") -> void:
	_resolve_ui_nodes()
	wall_data = data
	if segment_purchase_side.strip_edges() != "":
		selected_side = segment_purchase_side.strip_edges()
	else:
		selected_side = "back"
	_side_locked_by_user = false
	_apply_selected_side_to_ui()
	start_segment_id = ""
	selected_segment_ids.clear()
	quantity = 1
	_privacy_accepted = false
	if selected_location_label:
		selected_location_label.text = "Локация не выбрана"
	if privacy_checkbox:
		privacy_checkbox.button_pressed = false
	
	_refresh_balance_label()
	
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
	sync_purchase_side_from_wall()
	_apply_selected_side_to_ui()
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
	quantity = 1
	if selected_segment_ids.size() > 0:
		start_segment_id = selected_segment_ids[0]
	if selected_location_label:
		selected_location_label.text = "Выбрано сегментов: %d" % selected_segment_ids.size()
	if upload_images_button:
		upload_images_button.disabled = selected_segment_ids.size() == 0
	sync_purchase_side_from_wall()
	_update_price_display()


## [FIX] Визуальная грань тайла из WallRenderer (первый ref-сегмент: список или start_segment_id).
func sync_purchase_side_from_wall() -> void:
	if _side_locked_by_user:
		return
	if _wall_root == null:
		return
	var ref_id: String = ""
	if not selected_segment_ids.is_empty():
		ref_id = str(selected_segment_ids[0])
	elif start_segment_id.strip_edges() != "":
		ref_id = start_segment_id.strip_edges()
	if ref_id == "":
		return
	var wr: WallRenderer = null
	for c in _wall_root.get_children():
		if c is WallRenderer:
			wr = c as WallRenderer
			break
	if wr == null:
		return
	if wr.has_method("get_visible_segment_side"):
		var vis: String = str(wr.get_visible_segment_side(ref_id)).strip_edges().to_lower()
		if vis != "":
			selected_side = vis
			_apply_selected_side_to_ui()


func _on_side_selected(idx: int) -> void:
	if side_option == null or idx < 0 or idx >= side_option.item_count:
		return
	_side_locked_by_user = true
	selected_side = side_option.get_item_text(idx).strip_edges().to_lower()
	_update_price_display()


func _apply_selected_side_to_ui() -> void:
	if side_option == null:
		return
	for i in range(side_option.item_count):
		if side_option.get_item_text(i).to_lower() == selected_side:
			side_option.select(i)
			return


func _active_wall_side_for_economy() -> String:
	if Engine.has_singleton("GameState") and GameState.has_method("get_active_wall_side"):
		return str(GameState.get_active_wall_side())
	return "front"


func _wall_renderer() -> WallRenderer:
	if _wall_root == null:
		return null
	for c in _wall_root.get_children():
		if c is WallRenderer:
			return c as WallRenderer
	return null


## Грань тайла в момент покупки: `WallRenderer` отдаёт живую грань или `_last_known_tile_side` после скролла.
## «back» только если id никогда не попадал в рендерер (нет в памяти) — не копируем грань первого выбранного.
func _tile_side_for_segment_id(segment_id: String) -> String:
	return selected_side


func _iter_purchase_segment_ids() -> Array[String]:
	var ids: Array[String] = []
	if not selected_segment_ids.is_empty():
		for s in selected_segment_ids:
			var id_s: String = str(s)
			if id_s != "":
				ids.append(id_s)
	elif start_segment_id.strip_edges() != "":
		var coords: PackedStringArray = start_segment_id.split("_")
		if coords.size() >= 2:
			var start_x: int = int(coords[0])
			var start_y: int = int(coords[1])
			for i in range(quantity):
				ids.append("%d_%d" % [start_x + i, start_y])
	return ids


## [FIX] Итог = free_total + paid_total: по каждому сегменту цена из EconomyManager (0 / 400 на free, 50 / 0 на paid).
func _compute_bulk_purchase_totals() -> Dictionary:
	var free_total: int = 0
	var paid_total: int = 0
	var free_slots: int = 0
	var paid_slots: int = 0
	if wall_data == null:
		return {"total": 0, "free_total": 0, "paid_total": 0, "free_slots": 0, "paid_slots": 0}
	var wall_mega: String = _active_wall_side_for_economy()
	for seg_id in _iter_purchase_segment_ids():
		var tile: String = _tile_side_for_segment_id(seg_id)
		var unit: int = EconomyManager.get_listing_price_for_hit(wall_mega, seg_id, tile, wall_data)
		var ext: int = EconomyManager.side_external_for_name(tile)
		if EconomyManager.is_side_external_free(ext):
			free_total += unit
			free_slots += 1
		else:
			paid_total += unit
			paid_slots += 1
	return {
		"total": free_total + paid_total,
		"free_total": free_total,
		"paid_total": paid_total,
		"free_slots": free_slots,
		"paid_slots": paid_slots
	}


## Для PurchaseManager / CubeView: фактическая грань тайла по каждому выбранному сегменту.
func get_tile_side_by_segment_id() -> Dictionary:
	var d: Dictionary = {}
	for seg_id in _iter_purchase_segment_ids():
		d[seg_id] = _tile_side_for_segment_id(seg_id)
	return d


## Та же формула, что у тултипа (один сегмент).
func _economy_unit_price_for_segment(seg_id: String) -> int:
	if wall_data == null:
		return 0
	var tile_side: String = _tile_side_for_segment_id(str(seg_id))
	return EconomyManager.get_listing_price_for_hit(
		_active_wall_side_for_economy(), str(seg_id), tile_side, wall_data
	)


func _update_price_display() -> void:
	_refresh_balance_label()
	var br: Dictionary = _compute_bulk_purchase_totals()
	var total_price: int = int(br.get("total", 0))
	var free_total: int = int(br.get("free_total", 0))
	var paid_total: int = int(br.get("paid_total", 0))
	var free_slots: int = int(br.get("free_slots", 0))
	var paid_slots: int = int(br.get("paid_slots", 0))

	var has_segments: bool = selected_segment_ids.size() > 0 or start_segment_id != ""
	if preview_button:
		preview_button.disabled = not has_segments

	if not has_segments:
		if price_label:
			price_label.text = "Общая стоимость: выберите сегменты"
		if purchase_button:
			purchase_button.disabled = true
		return

	if wall_data == null:
		if price_label:
			price_label.text = "Общая стоимость: нет WallData (стена не привязана к диалогу)"
		if purchase_button:
			purchase_button.disabled = true
		_update_buttons_state()
		return

	## Единый текст: сколько сегментов free/paid (шт.) и их вклад в coin.
	var _breakdown_line: String = "free: %d шт. (%d coin), paid: %d шт. (%d coin)" % [
		free_slots, free_total, paid_slots, paid_total
	]

	if total_price == 0:
		if price_label:
			if free_slots + paid_slots > 0:
				price_label.text = "Общая стоимость: 0 coin (%s)" % _breakdown_line
			else:
				price_label.text = "Общая стоимость: 0 coin"
		var gs0: Node = get_node_or_null("/root/GameState")
		if purchase_button and gs0 != null and gs0.has_method("get_coins"):
			var can_free: bool = quantity > 0 and _privacy_accepted
			purchase_button.disabled = not can_free
		_update_buttons_state()
		return

	if price_label:
		price_label.text = "Общая стоимость: %d coin (%s)" % [total_price, _breakdown_line]
	# Проверяем баланс и согласие с политикой
	var gs_price: Node = get_node_or_null("/root/GameState")
	if purchase_button and gs_price != null and gs_price.has_method("get_coins"):
		var balance: int = int(gs_price.call("get_coins"))
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
	
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null or not gs.has_method("get_coins"):
		FileLogger.error("BulkPurchaseDialog: GameState недоступен при покупке")
		push_error("BulkPurchaseDialog: GameState недоступен!")
		return
	
	var br2: Dictionary = _compute_bulk_purchase_totals()
	var total_price: int = int(br2.get("total", 0))

	var balance: int = int(gs.call("get_coins"))
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
	
	_pending_bulk_ids = ids_to_buy.duplicate()
	if Engine.has_singleton("FileLogger"):
		FileLogger.write_log("[STORE] Buy pressed: selected=%d total_price=%d side=%s" % [_pending_bulk_ids.size(), total_price, selected_side])
	if _purchase_confirm == null:
		_setup_purchase_confirm_dialog()
	if _purchase_confirm:
		_purchase_confirm.popup_centered()
	return


func _on_bulk_purchase_confirm_canceled() -> void:
	_pending_bulk_ids.clear()


func _on_bulk_purchase_really_confirmed() -> void:
	var gs2: Node = get_node_or_null("/root/GameState")
	if gs2 == null or not gs2.has_method("get_coins"):
		FileLogger.error("BulkPurchaseDialog: GameState недоступен при подтверждении покупки")
		_pending_bulk_ids.clear()
		return
	var br3: Dictionary = _compute_bulk_purchase_totals()
	var total_price2: int = int(br3.get("total", 0))
	var balance2: int = int(gs2.call("get_coins"))
	if balance2 < total_price2:
		push_warning("BulkPurchaseDialog: Недостаточно монет при подтверждении! Баланс: %d, требуется: %d" % [balance2, total_price2])
		_pending_bulk_ids.clear()
		return
	var ids_to_buy: Array = []
	for x in _pending_bulk_ids:
		ids_to_buy.append(x)
	_pending_bulk_ids.clear()
	if ids_to_buy.is_empty():
		push_warning("BulkPurchaseDialog: Нет сегментов для покупки после подтверждения!")
		return
	print("BulkPurchaseDialog: Начинаем покупку ", ids_to_buy.size(), " сегментов за ", total_price2, " монет")
	if Engine.has_singleton("FileLogger"):
		FileLogger.write_log("[STORE] Confirmed in dialog: count=%d total_price=%d side=%s" % [ids_to_buy.size(), total_price2, selected_side])
	var links_dict: Dictionary = {}
	var link_text: String = link_line_edit.text.strip_edges() if link_line_edit else ""
	if link_text != "":
		for seg_id in ids_to_buy:
			links_dict[str(seg_id)] = link_text
	purchase_confirmed.emit(ids_to_buy, selected_side, selected_image_paths, links_dict, corporate_mode_enabled, corporate_group_id)
	hide()

func _on_cancel_pressed() -> void:
	location_selection_mode = false
	hide()
