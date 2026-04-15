extends RefCounted
class_name CubeViewPurchaseService

## Keeps purchase orchestration outside CubeView scene script.

func _pick_image_path_for_segment(segment_id: String, image_paths: Dictionary) -> String:
	if image_paths.is_empty():
		return ""
	if image_paths.has(segment_id):
		var p0: String = str(image_paths[segment_id]).strip_edges()
		if p0 != "":
			return p0
	for k in image_paths.keys():
		if str(k) == segment_id:
			var p1: String = str(image_paths[k]).strip_edges()
			if p1 != "":
				return p1
	if image_paths.size() == 1:
		var fk = image_paths.keys()[0]
		var p2: String = str(image_paths[fk]).strip_edges()
		if p2 != "":
			return p2
	for k2 in image_paths.keys():
		var p3: String = str(image_paths[k2]).strip_edges()
		if p3 != "":
			return p3
	return ""


func commit_bulk_purchase(
	wall_instance: Node2D,
	wall_data: WallData,
	segment_ids: Array,
	default_side: String,
	buyer_uid: String,
	tile_by_seg: Dictionary
) -> Dictionary:
	var empty_result: Dictionary = {
		"success": false,
		"reason": "invalid_input",
		"purchased_ids": [],
		"conflicts": [],
		"total_spent": 0
	}
	if wall_instance == null or wall_data == null:
		empty_result["reason"] = "wall_not_ready"
		return empty_result
	if segment_ids.is_empty():
		empty_result["reason"] = "empty_selection"
		return empty_result

	var tx: Dictionary = PurchaseManager.commit_bulk_wall_segment_purchase_tx(
		segment_ids,
		default_side,
		wall_data,
		buyer_uid,
		tile_by_seg
	)
	return tx


func apply_visuals_for_bulk_purchase(
	wall_instance: Node2D,
	wall_data: WallData,
	purchased_ids: Array,
	default_side: String,
	tile_by_seg: Dictionary,
	image_paths: Dictionary,
	links: Dictionary,
	corporate_mode: bool,
	group_id: String,
	copy_and_set_image_cb: Callable
) -> void:
	if wall_instance == null or wall_data == null:
		return
	var prev_auto_save: bool = wall_data.auto_save_enabled
	wall_data.auto_save_enabled = false
	for sid_any in purchased_ids:
		var sid: String = str(sid_any)
		var tile_for_sid: String = str(tile_by_seg.get(sid, default_side)).strip_edges().to_lower()
		if tile_for_sid == "":
			tile_for_sid = str(default_side).strip_edges().to_lower()
		if wall_instance.has_method("force_segment_visual_side"):
			wall_instance.call("force_segment_visual_side", sid, tile_for_sid)
		if corporate_mode and wall_data.has_method("set_segment_corporate_info"):
			wall_data.set_segment_corporate_info(sid, group_id, true)
		var src_img: String = _pick_image_path_for_segment(sid, image_paths)
		if src_img != "":
			copy_and_set_image_cb.call(sid, tile_for_sid, src_img, wall_data)
		if links.has(sid) and str(links[sid]) != "":
			wall_data.set_face_link(sid, tile_for_sid, str(links[sid]))
		if wall_instance.has_method("update_segment_visual"):
			wall_instance.call("update_segment_visual", sid)
	wall_data.auto_save_enabled = prev_auto_save
	if prev_auto_save:
		wall_data.save_to_file()
	if wall_instance.has_method("refresh_segment_textures"):
		wall_instance.call("refresh_segment_textures")
