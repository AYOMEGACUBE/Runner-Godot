extends Node
## Мост: клик по стене → EconomyManager.on_wall_hit_2d (тултип цены). Autoload: SegmentManager


func notify_wall_segment_selected(wall_root: Node2D, wall_data: WallData, click_data: Dictionary) -> void:
	if click_data.is_empty():
		return
	var seg_id: String = str(click_data.get("segment_id", ""))
	if seg_id.is_empty():
		return
	var segment_side: String = str(click_data.get("segment_side", click_data.get("side", "front")))
	var wall_side: String = "front"
	if wall_root != null:
		var v: Variant = wall_root.get("side_id")
		if v != null:
			wall_side = str(v)
	EconomyManager.on_wall_hit_2d(wall_side, wall_data, seg_id, segment_side)
