extends RefCounted
class_name WallPurchaseController

## Isolates wall purchase orchestration from CubeView.
## Keeps pricing and ownership write decisions in one place.

func _root_node(path: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).root.get_node_or_null(path)
	return null


func _log_store(message: String) -> void:
	var fl: Node = _root_node("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", "[STORE] " + message)
	else:
		print("[STORE] ", message)


func _resolve_effective_buyer_uid(raw_uid: String) -> String:
	var uid: String = raw_uid.strip_edges()
	if uid != "":
		return uid
	var gs: Node = _root_node("/root/GameState")
	if gs != null:
		var gs_uid: String = str(gs.get("player_uid")).strip_edges()
		if gs_uid != "":
			return gs_uid
	# Offline fallback: stable per app userdata directory on this device.
	var salt: String = ProjectSettings.globalize_path("user://").strip_edges()
	if salt == "":
		salt = OS.get_name()
	return "offline_%d" % abs(int(hash(salt)))

func commit_bulk_wall_purchase(
	wall_data: WallData,
	segment_ids: Array,
	default_tile_side: String,
	buyer_uid: String,
	wall_cube_side: String,
	tile_side_by_segment_id: Dictionary = {}
) -> Dictionary:
	var result: Dictionary = {
		"success": false,
		"reason": "invalid_input",
		"purchased_ids": [],
		"conflicts": [],
		"total_spent": 0,
	}
	if wall_data == null:
		result["reason"] = "wall_data_null"
		return result

	var wall_side: String = wall_cube_side.strip_edges()
	var gs: Node = _root_node("/root/GameState")
	if wall_side.is_empty() and gs != null and gs.has_method("get_active_wall_side"):
		wall_side = str(gs.call("get_active_wall_side"))
	if wall_side.is_empty():
		wall_side = "front"
	var effective_buyer_uid: String = _resolve_effective_buyer_uid(buyer_uid)

	var segment_prices: Dictionary = {}
	var conflict_ids: Array = []
	var valid_segment_ids: Array = []
	for seg_id_raw in segment_ids:
		var sid: String = str(seg_id_raw).strip_edges()
		if sid.is_empty():
			continue
		var tile_side: String = str(tile_side_by_segment_id.get(sid, default_tile_side)).strip_edges()
		if tile_side.is_empty():
			tile_side = default_tile_side
		var local_fd: Dictionary = wall_data.get_face_data(sid, tile_side)
		var local_owner: String = str(local_fd.get("owner", "")).strip_edges()
		var is_local_self_repurchase: bool = (local_owner != "" and local_owner == effective_buyer_uid)
		# Best-effort first-come-first-served guard against stale local state.
		var ors: Node = _root_node("/root/OwnershipRemoteSync")
		if ors != null and ors.has_method("is_segment_side_available_remote"):
			if not is_local_self_repurchase and not bool(ors.call("is_segment_side_available_remote", sid, tile_side)):
				conflict_ids.append(sid)
				continue
		var em: Node = _root_node("/root/EconomyManager")
		if em != null and em.has_method("get_listing_price_for_hit"):
			segment_prices[sid] = int(em.call("get_listing_price_for_hit", wall_side, sid, tile_side, wall_data))
		else:
			segment_prices[sid] = int(wall_data.get_segment_price(sid))
		valid_segment_ids.append(sid)

	if not conflict_ids.is_empty():
		result["reason"] = "already_purchased_remote"
		result["conflicts"] = conflict_ids
		return result
	if valid_segment_ids.is_empty():
		result["reason"] = "empty_selection"
		return result

	var purchase_ts: int = int(Time.get_unix_time_from_system())
	_log_store(
		"commit_bulk start count=%d wall_side=%s default_tile_side=%s buyer_uid=%s"
		% [valid_segment_ids.size(), wall_side, default_tile_side, effective_buyer_uid]
	)
	result = wall_data.buy_sides_atomic(
		valid_segment_ids,
		default_tile_side,
		effective_buyer_uid,
		purchase_ts,
		tile_side_by_segment_id,
		segment_prices,
		true
	)

	if not bool(result.get("success", false)):
		_log_store("commit_bulk failed reason=%s" % str(result.get("reason", "unknown")))
		return result
	_log_store(
		"commit_bulk ok purchased=%d spent=%d"
		% [int((result.get("purchased_ids", []) as Array).size()), int(result.get("total_spent", 0))]
	)

	for sid_any in result.get("purchased_ids", []):
		var sid2: String = str(sid_any)
		var tile_side2: String = str(tile_side_by_segment_id.get(sid2, default_tile_side)).strip_edges()
		if tile_side2.is_empty():
			tile_side2 = default_tile_side
		var em2: Node = _root_node("/root/EconomyManager")
		var fid: int = int(em2.call("face_id_from_wall_segment", wall_side, sid2, tile_side2)) if em2 != null and em2.has_method("face_id_from_wall_segment") else 0
		var paid: int = int(segment_prices.get(sid2, 0))
		if em2 != null and em2.has_method("record_face_purchase"):
			em2.call("record_face_purchase", fid, paid)

	return result
