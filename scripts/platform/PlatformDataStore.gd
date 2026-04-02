extends RefCounted
class_name PlatformDataStore

const SAVE_PATH: String = "user://platforms.json"
const VERSION: int = 2
const SYNC_FILE_NAME: String = "platforms.json"

var platforms: Dictionary = {}

func load_from_file() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		platforms.clear()
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return false
	if typeof(json.data) != TYPE_DICTIONARY:
		return false
	return from_dict(json.data)

func save_to_file() -> bool:
	var payload: Dictionary = to_dict()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true

func get_platform(platform_id: String) -> Dictionary:
	var id: String = platform_id.strip_edges()
	if id == "":
		return {}
	if not platforms.has(id):
		platforms[id] = {
			"platform_id": id,
			"owner_uid": null,
			"platform_type": "normal",
			"image_path": null,
			"link": null,
			"purchase_timestamp": null,
			"expires_at_timestamp": null,
			"version": 1,
			"sync_status": "synced"
		}
	return (platforms[id] as Dictionary).duplicate(true)

func set_platform(platform_id: String, data: Dictionary) -> void:
	platforms[platform_id] = data.duplicate(true)

func buy_platforms_atomic(
	platform_ids: Array,
	owner_uid: String,
	platform_type: String,
	image_path: String,
	link: String,
	expires_at_timestamp: int
) -> Dictionary:
	var now_ts: int = Time.get_unix_time_from_system()
	var unique_ids: Array[String] = []
	for raw_id in platform_ids:
		var id := str(raw_id).strip_edges()
		if id != "" and id not in unique_ids:
			unique_ids.append(id)

	var result: Dictionary = {
		"success": false,
		"purchased_ids": [],
		"conflicts": [],
		"reason": ""
	}
	if unique_ids.is_empty():
		result["reason"] = "empty_selection"
		return result

	var conflicts: Array = []
	for id in unique_ids:
		var rec: Dictionary = get_platform(id)
		var existing_owner: Variant = rec.get("owner_uid", null)
		var existing_expire: Variant = rec.get("expires_at_timestamp", null)
		var is_expired: bool = false
		if existing_expire != null:
			is_expired = int(existing_expire) > 0 and int(existing_expire) <= now_ts
		if existing_owner != null and str(existing_owner) != "" and not is_expired:
			conflicts.append(id)
	if not conflicts.is_empty():
		result["reason"] = "already_owned"
		result["conflicts"] = conflicts
		return result

	for id in unique_ids:
		var rec: Dictionary = get_platform(id)
		rec["owner_uid"] = owner_uid if owner_uid != "" else null
		rec["platform_type"] = platform_type
		rec["image_path"] = image_path if image_path != "" else null
		rec["link"] = link if link != "" else null
		rec["purchase_timestamp"] = now_ts
		rec["expires_at_timestamp"] = expires_at_timestamp if expires_at_timestamp > 0 else null
		rec["version"] = int(rec.get("version", 1)) + 1
		rec["sync_status"] = "pending"
		set_platform(id, rec)

	if not save_to_file():
		result["reason"] = "save_failed"
		return result

	result["success"] = true
	result["purchased_ids"] = unique_ids
	return result

func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"saved_at": Time.get_unix_time_from_system(),
		"platforms": platforms
	}

func from_dict(data: Dictionary) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if data.has("platforms") and data["platforms"] is Dictionary:
		platforms = data["platforms"].duplicate(true)
		return true
	return false

func merge_from_dict(remote_data: Dictionary) -> Dictionary:
	var merge_result: Dictionary = {"changed": false, "conflicts": []}
	if typeof(remote_data) != TYPE_DICTIONARY:
		return merge_result
	var remote_platforms: Dictionary = remote_data.get("platforms", {})
	if typeof(remote_platforms) != TYPE_DICTIONARY:
		return merge_result

	for pid in remote_platforms.keys():
		var remote_rec: Dictionary = remote_platforms[pid]
		if typeof(remote_rec) != TYPE_DICTIONARY:
			continue
		var local_rec: Dictionary = get_platform(str(pid))
		var local_owner: String = str(local_rec.get("owner_uid", ""))
		var remote_owner: String = str(remote_rec.get("owner_uid", ""))
		var local_ts: int = int(local_rec.get("purchase_timestamp", 0))
		var remote_ts: int = int(remote_rec.get("purchase_timestamp", 0))
		var local_ver: int = int(local_rec.get("version", 1))
		var remote_ver: int = int(remote_rec.get("version", 1))

		if local_owner == "" and remote_owner != "":
			set_platform(str(pid), remote_rec)
			merge_result["changed"] = true
			continue
		if local_owner != "" and remote_owner != "":
			# First buyer priority by timestamp, then lower version.
			if remote_ts > 0 and (local_ts <= 0 or remote_ts < local_ts):
				set_platform(str(pid), remote_rec)
				merge_result["changed"] = true
				merge_result["conflicts"].append(str(pid))
			elif remote_ts > local_ts or remote_ver > local_ver:
				local_rec["sync_status"] = "conflict"
				set_platform(str(pid), local_rec)
				merge_result["conflicts"].append(str(pid))
		elif remote_owner == "" and remote_ver > local_ver:
			set_platform(str(pid), remote_rec)
			merge_result["changed"] = true

	if bool(merge_result.get("changed", false)):
		save_to_file()
	return merge_result

func set_sync_status_for_ids(platform_ids: Array, status: String) -> void:
	for raw in platform_ids:
		var pid: String = str(raw)
		var rec: Dictionary = get_platform(pid)
		rec["sync_status"] = status
		set_platform(pid, rec)
	save_to_file()
