extends RefCounted
class_name PlatformDataStore

const SAVE_PATH: String = "user://platforms.json"
const VERSION: int = 2
const SYNC_FILE_NAME: String = "platforms.json"
const PLATFORM_IMAGES_DIR: String = "user://platform_images"

var platforms: Dictionary = {}


func _to_int_safe(v: Variant, default_value: int = 0) -> int:
	match typeof(v):
		TYPE_INT:
			return v as int
		TYPE_FLOAT:
			return floori(v as float)
		TYPE_STRING:
			var s: String = (v as String).strip_edges()
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return floori(s.to_float())
	return default_value


func _ensure_platform_images_dir() -> void:
	if DirAccess.dir_exists_absolute(PLATFORM_IMAGES_DIR):
		return
	var user_dir: DirAccess = DirAccess.open("user://")
	if user_dir != null:
		user_dir.make_dir("platform_images")


func _sha256_hex(bytes: PackedByteArray) -> String:
	var hc: HashingContext = HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(bytes)
	return hc.finish().hex_encode()


func build_shared_image_payload(source_path: String) -> Dictionary:
	var src: String = source_path.strip_edges()
	if src == "":
		return {}
	var img: Image = Image.new()
	var err: Error = img.load(src)
	if err != OK or img.is_empty():
		return {}
	img.resize(64, 64, Image.INTERPOLATE_LANCZOS)
	var png_bytes: PackedByteArray = img.save_png_to_buffer()
	if png_bytes.is_empty():
		return {}
	var sha: String = _sha256_hex(png_bytes)
	var local_path: String = "%s/%s.png" % [PLATFORM_IMAGES_DIR, sha]
	if not FileAccess.file_exists(local_path):
		_ensure_platform_images_dir()
		var f: FileAccess = FileAccess.open(local_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(png_bytes)
			f.close()
	return {
		"image_path": local_path,
		"image_payload_b64": Marshalls.raw_to_base64(png_bytes),
		"image_sha256": sha,
		"image_ext": "png",
	}


func _materialize_payload_to_local(payload_b64: String, sha: String, ext: String) -> String:
	var payload: PackedByteArray = Marshalls.base64_to_raw(payload_b64)
	if payload.is_empty():
		return ""
	var hash_now: String = sha.strip_edges().to_lower()
	if hash_now == "":
		hash_now = _sha256_hex(payload)
	var file_ext: String = ext.strip_edges().to_lower()
	if file_ext == "":
		file_ext = "png"
	var local_path: String = "%s/%s.%s" % [PLATFORM_IMAGES_DIR, hash_now, file_ext]
	if not FileAccess.file_exists(local_path):
		_ensure_platform_images_dir()
		var f: FileAccess = FileAccess.open(local_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(payload)
			f.close()
	return local_path


func _is_resolvable_image_path(path_value: String) -> bool:
	var p: String = path_value.strip_edges()
	if p == "":
		return false
	if p.begins_with("res://"):
		return ResourceLoader.exists(p)
	if p.begins_with("user://"):
		return FileAccess.file_exists(p)
	return FileAccess.file_exists(p)


func _materialize_record_images(rec: Dictionary) -> Dictionary:
	var pairs: Array = [
		{"path": "image_path", "b64": "image_payload_b64", "sha": "image_sha256", "ext": "image_ext"},
		{"path": "jump_image_up_path", "b64": "jump_image_up_payload_b64", "sha": "jump_image_up_sha256", "ext": "jump_image_up_ext"},
		{"path": "jump_image_down_path", "b64": "jump_image_down_payload_b64", "sha": "jump_image_down_sha256", "ext": "jump_image_down_ext"},
	]
	for d_any in pairs:
		var d: Dictionary = d_any as Dictionary
		var path_key: String = str(d["path"])
		var b64_key: String = str(d["b64"])
		var sha_key: String = str(d["sha"])
		var ext_key: String = str(d["ext"])
		var p: String = str(rec.get(path_key, "")).strip_edges()
		if _is_resolvable_image_path(p):
			continue
		var b64: String = str(rec.get(b64_key, "")).strip_edges()
		if b64 == "":
			continue
		var sha: String = str(rec.get(sha_key, "")).strip_edges()
		var ext: String = str(rec.get(ext_key, "png")).strip_edges()
		var local_path: String = _materialize_payload_to_local(b64, sha, ext)
		if local_path != "":
			rec[path_key] = local_path
			if sha == "":
				var bytes: PackedByteArray = Marshalls.base64_to_raw(b64)
				if not bytes.is_empty():
					rec[sha_key] = _sha256_hex(bytes)
			if ext == "":
				rec[ext_key] = "png"
	return rec

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
			"image_payload_b64": "",
			"image_sha256": "",
			"image_ext": "png",
			"jump_image_up_path": null,
			"jump_image_up_payload_b64": "",
			"jump_image_up_sha256": "",
			"jump_image_up_ext": "png",
			"jump_image_down_path": null,
			"jump_image_down_payload_b64": "",
			"jump_image_down_sha256": "",
			"jump_image_down_ext": "png",
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
		var changed: bool = false
		for pid_any in platforms.keys():
			var pid: String = str(pid_any)
			var rec: Variant = platforms[pid_any]
			if typeof(rec) != TYPE_DICTIONARY:
				continue
			var before_path: String = str((rec as Dictionary).get("image_path", ""))
			var normalized: Dictionary = _materialize_record_images((rec as Dictionary).duplicate(true))
			var after_path: String = str(normalized.get("image_path", ""))
			if before_path != after_path:
				changed = true
			platforms[pid] = normalized
		if changed:
			save_to_file()
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
		var local_ts: int = _to_int_safe(local_rec.get("purchase_timestamp", 0), 0)
		var remote_ts: int = _to_int_safe(remote_rec.get("purchase_timestamp", 0), 0)
		var local_ver: int = _to_int_safe(local_rec.get("version", 1), 1)
		var remote_ver: int = _to_int_safe(remote_rec.get("version", 1), 1)

		if local_owner == "" and remote_owner != "":
			set_platform(str(pid), _materialize_record_images(remote_rec.duplicate(true)))
			merge_result["changed"] = true
			continue
		if local_owner != "" and remote_owner != "":
			# First buyer priority by timestamp, then lower version.
			if remote_ts > 0 and (local_ts <= 0 or remote_ts < local_ts):
				set_platform(str(pid), _materialize_record_images(remote_rec.duplicate(true)))
				merge_result["changed"] = true
				merge_result["conflicts"].append(str(pid))
			elif remote_ts > local_ts or remote_ver > local_ver:
				local_rec["sync_status"] = "conflict"
				set_platform(str(pid), local_rec)
				merge_result["conflicts"].append(str(pid))
		elif remote_owner == "" and remote_ver > local_ver:
			set_platform(str(pid), _materialize_record_images(remote_rec.duplicate(true)))
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
