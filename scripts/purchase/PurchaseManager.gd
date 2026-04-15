extends Node
## Централизованная покупка: баланс `GameState.wallet_coins` (get_coins), каталог `DataManager.shop_data`,
## массовые покупки лиц сегментов через `WallData.buy_side`.

const WallPurchaseController = preload("res://scripts/purchase/WallPurchaseController.gd")

signal purchase_started(item_id: String)
signal purchase_succeeded(item_id: String)
signal purchase_failed(item_id: String, reason: String)
signal coins_updated(new_balance: int)

var _wall_purchase_controller: WallPurchaseController = WallPurchaseController.new()
var _platform_store: PlatformDataStore = PlatformDataStore.new()

const PLATFORM_PRICE_NORMAL: int = 50
const PLATFORM_PRICE_CRUMBLING: int = 75
const PLATFORM_PRICE_DECOY: int = 15
const PLATFORM_DAILY_PRICE_SMALL_L1: int = 100
const PLATFORM_DAILY_PRICE_MEDIUM_L1: int = 200
const PLATFORM_DAILY_PRICE_LARGE_L1: int = 300
const PLATFORM_HEIGHT_LEVELS: int = 7
const PLATFORM_LEVEL_HEIGHTS: Array[int] = [1000, 5000, 10000, 20000, 50000, 100000, 200000]
const PLATFORM_MAX_SLOTS_PER_LEVEL: int = 256


func _log_info(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("info"):
		fl.call("info", msg)
	else:
		print("[PurchaseManager] ", msg)


func _log_warn(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("warn"):
		fl.call("warn", msg)
	else:
		print("[PurchaseManager][WARN] ", msg)


func _log_error(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("error"):
		fl.call("error", msg)
	else:
		push_error("[PurchaseManager] " + msg)


func get_coin_balance() -> int:
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null:
		return 0
	return int(gs.call("get_coins"))

func _ready() -> void:
	_platform_store.load_from_file()


func _payload_or_empty(source_path: String) -> Dictionary:
	if _platform_store == null:
		return {}
	return _platform_store.build_shared_image_payload(source_path)


func _apply_payload_to_record(rec: Dictionary, path_key: String, b64_key: String, sha_key: String, ext_key: String, payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return rec
	rec[path_key] = str(payload.get("image_path", ""))
	rec[b64_key] = str(payload.get("image_payload_b64", ""))
	rec[sha_key] = str(payload.get("image_sha256", ""))
	rec[ext_key] = str(payload.get("image_ext", "png"))
	return rec


func get_platform_store_ref() -> PlatformDataStore:
	return _platform_store

func get_platform_unit_price(platform_type: String) -> int:
	var t: String = platform_type.strip_edges().to_lower()
	if t == "crumbling":
		return PLATFORM_PRICE_CRUMBLING
	if t == "decoy":
		return PLATFORM_PRICE_DECOY
	return PLATFORM_PRICE_NORMAL


func get_platform_level_world_y(level: int) -> int:
	var idx: int = clampi(level, 1, PLATFORM_HEIGHT_LEVELS) - 1
	return int(PLATFORM_LEVEL_HEIGHTS[idx])


func get_platform_daily_price(platform_size: String, height_level: int) -> int:
	var lvl: int = clampi(height_level, 1, PLATFORM_HEIGHT_LEVELS)
	var size_key: String = platform_size.strip_edges().to_lower()
	var base: int = PLATFORM_DAILY_PRICE_MEDIUM_L1
	if size_key == "small":
		base = PLATFORM_DAILY_PRICE_SMALL_L1
	elif size_key == "large":
		base = PLATFORM_DAILY_PRICE_LARGE_L1
	return base + (lvl - 1) * 100


func estimate_platform_purchase_total(quantity: int, platform_size: String, height_level: int, duration_days: int) -> Dictionary:
	var qty: int = clampi(quantity, 1, 10)
	var days: int = maxi(1, duration_days)
	var daily: int = get_platform_daily_price(platform_size, height_level)
	var total: int = daily * days * qty
	return {"quantity": qty, "days": days, "daily_price": daily, "total": total}


func get_platform_availability(height_level: int, quantity: int) -> Dictionary:
	var lvl: int = clampi(height_level, 1, PLATFORM_HEIGHT_LEVELS)
	var qty: int = clampi(quantity, 1, 10)
	var occupied: Dictionary = {}
	for pid_any in _platform_store.platforms.keys():
		var pid: String = str(pid_any)
		if not pid.begins_with("h%d_slot_" % lvl):
			continue
		var rec: Dictionary = _platform_store.get_platform(pid)
		var owner: String = str(rec.get("owner_uid", "")).strip_edges()
		var exp: int = int(rec.get("expires_at_timestamp", 0))
		var expired: bool = exp > 0 and exp <= int(Time.get_unix_time_from_system())
		if not owner.is_empty() and not expired:
			var parts: PackedStringArray = pid.split("_")
			if parts.size() >= 3:
				occupied[int(parts[2])] = true
	var free_slots: Array[int] = []
	for i in range(PLATFORM_MAX_SLOTS_PER_LEVEL):
		if not occupied.has(i):
			free_slots.append(i)
			if free_slots.size() >= qty:
				break
	var can_buy: bool = free_slots.size() >= qty
	var next_after: int = 0
	if not can_buy:
		next_after = qty - free_slots.size()
	return {
		"height_level": lvl,
		"requested": qty,
		"available_slots": free_slots.size(),
		"next_after": next_after,
		"can_buy": can_buy,
	}

func buy_platforms(
	platform_type: String,
	quantity: int,
	image_path: String,
	link: String,
	expires_at_timestamp: int,
	platform_size: String = "medium",
	height_level: int = 1,
	jump_image_up_path: String = "",
	jump_image_down_path: String = "",
	duration_days: int = 1
) -> Dictionary:
	var result: Dictionary = {"success": false, "reason": "", "count": 0, "total_spent": 0, "purchased_ids": []}
	if not Engine.has_singleton("GameState"):
		result["reason"] = "gamestate_missing"
		return result
	if quantity <= 0:
		result["reason"] = "invalid_quantity"
		return result
	var qty: int = clampi(int(quantity), 1, 10)
	var lvl: int = clampi(height_level, 1, PLATFORM_HEIGHT_LEVELS)
	var av: Dictionary = get_platform_availability(lvl, qty)
	if not bool(av.get("can_buy", false)):
		result["reason"] = "slots_unavailable"
		result["next_after"] = int(av.get("next_after", 0))
		return result
	var pricing: Dictionary = estimate_platform_purchase_total(qty, platform_size, lvl, duration_days)
	var total: int = int(pricing.get("total", 0))
	if get_coin_balance() < total:
		result["reason"] = "insufficient_funds"
		return result
	var gs: Node = get_node_or_null("/root/GameState")
	if total > 0 and (gs == null or not bool(gs.call("spend_wallet_coins", total))):
		result["reason"] = "insufficient_funds"
		return result

	var uid: String = str(gs.get("player_uid") if gs != null else "").strip_edges()
	var now_ts: int = int(Time.get_unix_time_from_system())
	var ids: Array[String] = []
	var occupied: Dictionary = {}
	for pid_any in _platform_store.platforms.keys():
		var pid: String = str(pid_any)
		if not pid.begins_with("h%d_slot_" % lvl):
			continue
		var rec_old: Dictionary = _platform_store.get_platform(pid)
		var owner_old: String = str(rec_old.get("owner_uid", "")).strip_edges()
		var exp_old: int = int(rec_old.get("expires_at_timestamp", 0))
		var expired_old: bool = exp_old > 0 and exp_old <= now_ts
		if not owner_old.is_empty() and not expired_old:
			var parts_old: PackedStringArray = pid.split("_")
			if parts_old.size() >= 3:
				occupied[int(parts_old[2])] = true
	for i in range(PLATFORM_MAX_SLOTS_PER_LEVEL):
		if occupied.has(i):
			continue
		ids.append("h%d_slot_%d" % [lvl, i])
		if ids.size() >= qty:
			break
	if ids.size() < qty:
		result["reason"] = "slots_unavailable"
		result["next_after"] = qty - ids.size()
		return result

	var tx: Dictionary = _platform_store.buy_platforms_atomic(ids, uid, platform_type, image_path, link, expires_at_timestamp)
	if not bool(tx.get("success", false)):
		# Best-effort rollback of wallet on failed store write/validation.
		if gs != null:
			gs.set("wallet_coins", int(gs.get("wallet_coins")) + total)
			gs.call("save_scores")
		result["reason"] = str(tx.get("reason", "store_failed"))
		return result

	result["success"] = true
	result["reason"] = "ok"
	result["count"] = qty
	result["total_spent"] = total
	result["purchased_ids"] = tx.get("purchased_ids", [])
	result["height_level"] = lvl
	result["height_world_y"] = get_platform_level_world_y(lvl)
	result["platform_size"] = platform_size
	result["duration_days"] = int(pricing.get("days", 1))
	result["daily_price"] = int(pricing.get("daily_price", 0))
	var main_payload: Dictionary = _payload_or_empty(image_path)
	var up_payload: Dictionary = _payload_or_empty(jump_image_up_path if jump_image_up_path != "" else image_path)
	var down_payload: Dictionary = _payload_or_empty(jump_image_down_path if jump_image_down_path != "" else image_path)

	# Store extra display/runtime metadata in purchased records.
	for pid_new_any in result["purchased_ids"]:
		var pid_new: String = str(pid_new_any)
		var rec_new: Dictionary = _platform_store.get_platform(pid_new)
		rec_new["platform_size"] = platform_size
		rec_new["height_level"] = lvl
		rec_new["height_world_y"] = get_platform_level_world_y(lvl)
		rec_new["jump_image_up_path"] = jump_image_up_path if jump_image_up_path != "" else image_path
		rec_new["jump_image_down_path"] = jump_image_down_path if jump_image_down_path != "" else image_path
		rec_new["duration_days"] = int(pricing.get("days", 1))
		rec_new["daily_price"] = int(pricing.get("daily_price", 0))
		rec_new = _apply_payload_to_record(rec_new, "image_path", "image_payload_b64", "image_sha256", "image_ext", main_payload)
		rec_new = _apply_payload_to_record(rec_new, "jump_image_up_path", "jump_image_up_payload_b64", "jump_image_up_sha256", "jump_image_up_ext", up_payload)
		rec_new = _apply_payload_to_record(rec_new, "jump_image_down_path", "jump_image_down_payload_b64", "jump_image_down_sha256", "jump_image_down_ext", down_payload)
		_platform_store.set_platform(pid_new, rec_new)
	_platform_store.save_to_file()

	coins_updated.emit(get_coin_balance())
	purchase_succeeded.emit("platforms:%d" % qty)
	var ors: Node = get_node_or_null("/root/OwnershipRemoteSync")
	if ors != null and ors.has_method("request_push_all"):
		ors.call("request_push_all")
	return result


func try_purchase(item_id: String) -> bool:
	purchase_started.emit(item_id)
	if not Engine.has_singleton("GameState"):
		_log_error("PurchaseManager.try_purchase: GameState missing")
		purchase_failed.emit(item_id, "gamestate_missing")
		return false
	var dm: Node = get_node_or_null("/root/DataManager")
	if dm == null or not bool(dm.get("is_data_ready")):
		_log_warn("PurchaseManager.try_purchase: DataManager not ready id=%s" % item_id)
		purchase_failed.emit(item_id, "data_not_ready")
		return false
	var item: Dictionary = _resolve_shop_item(item_id)
	if item.is_empty():
		_log_warn("PurchaseManager.try_purchase: missing catalog item id=%s" % item_id)
		purchase_failed.emit(item_id, "missing_item")
		return false
	var price: int = int(item.get("price", item.get("cost", 0)))
	if price <= 0:
		_log_warn("PurchaseManager.try_purchase: invalid price id=%s" % item_id)
		purchase_failed.emit(item_id, "invalid_price")
		return false
	if get_coin_balance() < price:
		_log_warn(
			"PurchaseManager.try_purchase: insufficient funds id=%s balance=%d need=%d"
			% [item_id, get_coin_balance(), price]
		)
		purchase_failed.emit(item_id, "insufficient_funds")
		return false
	var gs2: Node = get_node_or_null("/root/GameState")
	if gs2 == null or not bool(gs2.call("spend_wallet_coins", price)):
		purchase_failed.emit(item_id, "insufficient_funds")
		return false
	_log_info("PurchaseManager.try_purchase: spent %d for id=%s" % [price, item_id])
	purchase_succeeded.emit(item_id)
	coins_updated.emit(get_coin_balance())
	return true


func unlock_item(item_id: String) -> void:
	_log_warn("PurchaseManager.unlock_item: not implemented id=%s" % item_id)


func sync_purchases() -> void:
	_log_info("PurchaseManager.sync_purchases: no-op (RTDB sync managed by OwnershipRemoteSync)")


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
		_log_error("PurchaseManager.commit_wall_face_purchase: wall_data null")
		purchase_failed.emit(op_id, "wall_data_null")
		return false
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null:
		_log_error("PurchaseManager.commit_wall_face_purchase: GameState missing")
		purchase_failed.emit(op_id, "gamestate_missing")
		return false
	var price: int = wall_data.get_segment_price(segment_id)
	if price_override >= 0:
		price = price_override
	var ok: bool = wall_data.buy_side(segment_id, side, buyer_uid, price)
	if ok:
		if wall_cube_side != "":
			var em: Node = get_node_or_null("/root/EconomyManager")
			if em != null:
				var fid: int = int(em.call("face_id_from_wall_segment", wall_cube_side, segment_id, side))
				em.call("record_face_purchase", fid, price)
		_log_info(
			"PurchaseManager.commit_wall_face_purchase: ok segment=%s side=%s price=%d"
			% [segment_id, side, price]
		)
		purchase_succeeded.emit(op_id)
		coins_updated.emit(get_coin_balance())
		var ors: Node = get_node_or_null("/root/OwnershipRemoteSync")
		if ors != null and ors.has_method("request_push_all"):
			ors.call("request_push_all")
	else:
		_log_warn(
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
	var tx: Dictionary = commit_bulk_wall_segment_purchase_tx(
		segment_ids, default_tile_side, wall_data, buyer_uid, tile_side_by_segment_id
	)
	var purchased: Array[String] = []
	for sid_any in tx.get("purchased_ids", []):
		purchased.append(str(sid_any))
	return purchased


## Транзакционный результат для UI/тестов: причины/конфликты/список id.
func commit_bulk_wall_segment_purchase_tx(
	segment_ids: Array,
	default_tile_side: String,
	wall_data: WallData,
	buyer_uid: String,
	tile_side_by_segment_id: Dictionary = {}
) -> Dictionary:
	var bulk_id: String = "bulk_wall:%d" % segment_ids.size()
	purchase_started.emit(bulk_id)
	var tx_out: Dictionary = {
		"success": false,
		"reason": "invalid_input",
		"purchased_ids": [],
		"conflicts": [],
		"total_spent": 0
	}
	if wall_data == null:
		_log_error("PurchaseManager.commit_bulk_wall_segment_purchase: wall_data null")
		purchase_failed.emit(bulk_id, "wall_data_null")
		tx_out["reason"] = "wall_data_null"
		return tx_out
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null:
		_log_error("PurchaseManager.commit_bulk_wall_segment_purchase: GameState missing")
		purchase_failed.emit(bulk_id, "gamestate_missing")
		tx_out["reason"] = "gamestate_missing"
		return tx_out
	var wall_side: String = "front"
	if gs != null and gs.has_method("get_active_wall_side"):
		wall_side = str(gs.call("get_active_wall_side"))
	var tx_result: Dictionary = _wall_purchase_controller.commit_bulk_wall_purchase(
		wall_data,
		segment_ids,
		default_tile_side,
		buyer_uid,
		wall_side,
		tile_side_by_segment_id
	)
	tx_out = tx_result.duplicate(true)
	var purchased: Array[String] = []
	for sid_any in tx_result.get("purchased_ids", []):
		purchased.append(str(sid_any))
	tx_out["purchased_ids"] = purchased
	if purchased.size() > 0:
		purchase_succeeded.emit(bulk_id)
		coins_updated.emit(get_coin_balance())
		var ors2: Node = get_node_or_null("/root/OwnershipRemoteSync")
		if ors2 != null and ors2.has_method("request_push_all"):
			ors2.call("request_push_all")
		_log_info(
			"PurchaseManager.commit_bulk_wall_segment_purchase: ok count=%d spent=%d"
			% [purchased.size(), int(tx_result.get("total_spent", 0))]
		)
	elif segment_ids.size() > 0:
		var reason: String = str(tx_out.get("reason", "no_segments_purchased"))
		purchase_failed.emit(bulk_id, reason)
		_log_warn("PurchaseManager.commit_bulk_wall_segment_purchase: failed reason=%s" % reason)
	return tx_out


func _resolve_shop_item(item_id: String) -> Dictionary:
	var dm: Node = get_node_or_null("/root/DataManager")
	var shop: Dictionary = dm.get("shop_data") as Dictionary if dm != null else {}
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
