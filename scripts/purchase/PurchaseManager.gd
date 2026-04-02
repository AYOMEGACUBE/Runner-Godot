extends Node
## Централизованная покупка: баланс `GameState.score`, каталог `DataManager.shop_data`,
## массовые покупки лиц сегментов через `WallData.buy_side`.

signal purchase_started(item_id: String)
signal purchase_succeeded(item_id: String)
signal purchase_failed(item_id: String, reason: String)
signal coins_updated(new_balance: int)


func get_coin_balance() -> int:
	if not Engine.has_singleton("GameState"):
		return 0
	return GameState.score


func try_purchase(item_id: String) -> bool:
	purchase_started.emit(item_id)
	if not Engine.has_singleton("GameState"):
		FileLogger.error("PurchaseManager.try_purchase: GameState missing")
		purchase_failed.emit(item_id, "gamestate_missing")
		return false
	if not DataManager.is_data_ready:
		FileLogger.warn("PurchaseManager.try_purchase: DataManager not ready id=%s" % item_id)
		purchase_failed.emit(item_id, "data_not_ready")
		return false
	var item: Dictionary = _resolve_shop_item(item_id)
	if item.is_empty():
		FileLogger.warn("PurchaseManager.try_purchase: missing catalog item id=%s" % item_id)
		purchase_failed.emit(item_id, "missing_item")
		return false
	var price: int = int(item.get("price", item.get("cost", 0)))
	if price <= 0:
		FileLogger.warn("PurchaseManager.try_purchase: invalid price id=%s" % item_id)
		purchase_failed.emit(item_id, "invalid_price")
		return false
	if get_coin_balance() < price:
		FileLogger.warn(
			"PurchaseManager.try_purchase: insufficient funds id=%s balance=%d need=%d"
			% [item_id, get_coin_balance(), price]
		)
		purchase_failed.emit(item_id, "insufficient_funds")
		return false
	GameState.score -= price
	GameState.save_scores()
	FileLogger.info("PurchaseManager.try_purchase: spent %d for id=%s" % [price, item_id])
	purchase_succeeded.emit(item_id)
	coins_updated.emit(get_coin_balance())
	return true


func unlock_item(item_id: String) -> void:
	FileLogger.warn("PurchaseManager.unlock_item: not implemented id=%s" % item_id)


func sync_purchases() -> void:
	FileLogger.info("PurchaseManager.sync_purchases: no-op (BlackoutSync остаётся в CubeView)")


## Одна покупка лица сегмента. `price_override < 0` — взять цену из `wall_data`.
func commit_wall_face_purchase(
	segment_id: String,
	side: String,
	wall_data: WallData,
	buyer_uid: String,
	price_override: int = -1,
	wall_cube_side: String = ""
) -> bool:
	var op_id: String = "wall:%s:%s" % [segment_id, side]
	purchase_started.emit(op_id)
	if wall_data == null:
		FileLogger.error("PurchaseManager.commit_wall_face_purchase: wall_data null")
		purchase_failed.emit(op_id, "wall_data_null")
		return false
	if not Engine.has_singleton("GameState"):
		FileLogger.error("PurchaseManager.commit_wall_face_purchase: GameState missing")
		purchase_failed.emit(op_id, "gamestate_missing")
		return false
	var price: int = wall_data.get_segment_price(segment_id)
	if price_override >= 0:
		price = price_override
	var ok: bool = wall_data.buy_side(segment_id, side, buyer_uid, price)
	if ok:
		if wall_cube_side != "":
			var fid: int = EconomyManager.face_id_from_wall_segment(wall_cube_side, segment_id, side)
			EconomyManager.record_face_purchase(fid, price)
		FileLogger.info(
			"PurchaseManager.commit_wall_face_purchase: ok segment=%s side=%s price=%d"
			% [segment_id, side, price]
		)
		purchase_succeeded.emit(op_id)
		coins_updated.emit(get_coin_balance())
	else:
		FileLogger.warn(
			"PurchaseManager.commit_wall_face_purchase: rejected segment=%s side=%s" % [segment_id, side]
		)
		purchase_failed.emit(op_id, "buy_side_rejected")
	return ok


## Массовая покупка: проверка суммарной цены, затем `buy_side` по каждому id.
## `tile_side_by_segment_id`: segment_id → грань тайла (front/back/…); пусто — для всех `default_tile_side`.
## Возвращает список id, для которых покупка прошла успешно.
func commit_bulk_wall_segment_purchase(
	segment_ids: Array,
	default_tile_side: String,
	wall_data: WallData,
	buyer_uid: String,
	tile_side_by_segment_id: Dictionary = {}
) -> Array[String]:
	var bulk_id: String = "bulk_wall:%d" % segment_ids.size()
	purchase_started.emit(bulk_id)
	var purchased: Array[String] = []
	if wall_data == null:
		FileLogger.error("PurchaseManager.commit_bulk_wall_segment_purchase: wall_data null")
		purchase_failed.emit(bulk_id, "wall_data_null")
		return purchased
	if not Engine.has_singleton("GameState"):
		FileLogger.error("PurchaseManager.commit_bulk_wall_segment_purchase: GameState missing")
		purchase_failed.emit(bulk_id, "gamestate_missing")
		return purchased
	var balance: int = GameState.score
	var wall_side: String = "front"
	if GameState.has_method("get_active_wall_side"):
		wall_side = str(GameState.get_active_wall_side())
	var total_price: int = 0
	for seg_id in segment_ids:
		var sid: String = str(seg_id)
		if sid.is_empty():
			continue
		var tile_side: String = str(tile_side_by_segment_id.get(sid, default_tile_side))
		if tile_side.strip_edges().is_empty():
			tile_side = default_tile_side
		## [FIX] Согласовано с EconomyManager; сумма = free_total + paid_total по каждой грани
		total_price += EconomyManager.get_listing_price_for_hit(wall_side, sid, tile_side, wall_data)
	FileLogger.info(
		"PurchaseManager.commit_bulk_wall_segment_purchase: balance=%d total_price=%d count=%d"
		% [balance, total_price, segment_ids.size()]
	)
	if balance < total_price:
		FileLogger.error(
			"PurchaseManager.commit_bulk_wall_segment_purchase: insufficient funds balance=%d need=%d"
			% [balance, total_price]
		)
		purchase_failed.emit(bulk_id, "insufficient_funds")
		return purchased
	for seg_id in segment_ids:
		var sid: String = str(seg_id)
		if sid.is_empty():
			continue
		var tile_side2: String = str(tile_side_by_segment_id.get(sid, default_tile_side))
		if tile_side2.strip_edges().is_empty():
			tile_side2 = default_tile_side
		var price: int = EconomyManager.get_listing_price_for_hit(wall_side, sid, tile_side2, wall_data)
		if wall_data.buy_side(sid, tile_side2, buyer_uid, price):
			purchased.append(sid)
			FileLogger.info(
				"PurchaseManager.commit_bulk_wall_segment_purchase: purchased segment=%s tile_side=%s price=%d"
				% [sid, tile_side2, price]
			)
		else:
			FileLogger.warn("PurchaseManager.commit_bulk_wall_segment_purchase: buy_side failed segment=%s" % sid)
	if purchased.size() > 0:
		purchase_succeeded.emit(bulk_id)
		coins_updated.emit(get_coin_balance())
	elif segment_ids.size() > 0:
		purchase_failed.emit(bulk_id, "no_segments_purchased")
	return purchased


func _resolve_shop_item(item_id: String) -> Dictionary:
	var shop: Dictionary = DataManager.shop_data
	if shop.is_empty():
		return {}
	if shop.has("items"):
		var raw_items: Variant = shop.get("items", [])
		if raw_items is Array:
			for it in raw_items:
				if it is Dictionary and str((it as Dictionary).get("id", "")) == item_id:
					return it as Dictionary
	elif shop.has(item_id):
		var entry: Variant = shop[item_id]
		if entry is Dictionary:
			return entry as Dictionary
	return {}
