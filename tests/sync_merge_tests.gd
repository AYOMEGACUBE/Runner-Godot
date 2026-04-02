extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var wall := WallData.new()
	var platform_store := PlatformDataStore.new()
	var seg_id: String = "1_1"
	var side: String = "front"
	wall.get_segment(seg_id)
	wall.buy_side(seg_id, side, "local_owner", 0)

	var remote_wall: Dictionary = wall.to_dict()
	var remote_seg: Dictionary = remote_wall["segments"][seg_id]
	var remote_face: Dictionary = remote_seg["faces"][side]
	remote_face["owner"] = "remote_first"
	remote_face["purchase_date"] = int(remote_face.get("purchase_date", 0)) - 50
	remote_seg["faces"][side] = remote_face
	remote_wall["segments"][seg_id] = remote_seg
	var merge_res: Dictionary = wall.merge_from_dict(remote_wall)
	_expect(bool(merge_res.get("changed", false)), "wall merge should apply first buyer")

	var pid: String = "2_3"
	platform_store.buy_platforms_atomic([pid], "local_owner", "normal", "", "", 0)
	var remote_platforms: Dictionary = platform_store.to_dict()
	var remote_rec: Dictionary = remote_platforms["platforms"][pid]
	remote_rec["owner_uid"] = "remote_first"
	remote_rec["purchase_timestamp"] = int(remote_rec.get("purchase_timestamp", 0)) - 100
	remote_platforms["platforms"][pid] = remote_rec
	var platform_merge: Dictionary = platform_store.merge_from_dict(remote_platforms)
	_expect(bool(platform_merge.get("changed", false)), "platform merge should apply first buyer")

	_finish("sync_merge_tests")

func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)

func _finish(name: String) -> void:
	if _failures.is_empty():
		print("[TEST] PASS %s" % name)
		quit(0)
		return
	for f in _failures:
		push_error("[TEST] FAIL %s: %s" % [name, f])
	quit(1)
