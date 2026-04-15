extends Node
## Syncs wall/platform ownership via Firebase RTDB.
## RTDB is treated as source of truth for release runtime.

signal ownership_updated(wall_changed: bool, platform_changed: bool)
signal ownership_sync_failed(reason: String)

var _http: HTTPRequest
var _op: String = ""
var _bound_wall_data: WallData = null
var _bound_platform_store: PlatformDataStore = null
var _push_payload: String = ""
var _last_remote_snapshot: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	if not AuthService.login_succeeded.is_connected(_on_login_succeeded):
		AuthService.login_succeeded.connect(_on_login_succeeded)


func bind_sources(wall_data: WallData, platform_store: PlatformDataStore) -> void:
	_bound_wall_data = wall_data
	_bound_platform_store = platform_store


func request_push_all() -> void:
	if not AuthService.is_signed_in():
		return
	if _op != "":
		return
	var wall_data: WallData = _resolve_wall_data()
	var platform_store: PlatformDataStore = _resolve_platform_store()
	if wall_data == null or platform_store == null:
		return
	var payload_dict: Dictionary = {
		"wall": wall_data.to_dict(),
		"platforms": platform_store.to_dict(),
		"t": int(Time.get_unix_time_from_system()),
	}
	_push_payload = JSON.stringify(payload_dict)
	_start_put_ownership(_push_payload)


func pull_ownership_then_merge() -> void:
	if not AuthService.is_signed_in():
		return
	if _op != "":
		return
	var uid: String = GameState.player_uid.strip_edges()
	var tok: String = GameState.auth_token.strip_edges()
	if uid.is_empty() or tok.is_empty():
		return
	var base: String = AuthService.get_rtdb_base_url()
	if base.is_empty():
		return
	_op = "pull"
	var url: String = "%s/users/%s/ownership.json?auth=%s" % [base, uid.uri_encode(), tok.uri_encode()]
	var err: int = _http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		_log("pull schedule err=%d" % err)
		ownership_sync_failed.emit("pull_schedule_err_%d" % err)
		_op = ""


func get_cached_remote_snapshot() -> Dictionary:
	return _last_remote_snapshot.duplicate(true)


func is_segment_side_available_remote(segment_id: String, side: String) -> bool:
	var root: Dictionary = _last_remote_snapshot
	var wall: Dictionary = root.get("wall", {})
	var segs: Dictionary = wall.get("segments", {})
	if not segs.has(segment_id):
		return true
	var seg: Variant = segs[segment_id]
	if typeof(seg) != TYPE_DICTIONARY:
		return true
	var faces: Dictionary = (seg as Dictionary).get("faces", {})
	if not faces.has(side):
		return true
	var fd: Variant = faces[side]
	if typeof(fd) != TYPE_DICTIONARY:
		return true
	return str((fd as Dictionary).get("owner", "")).strip_edges().is_empty()


func _on_login_succeeded() -> void:
	call_deferred("pull_ownership_then_merge")


func _start_put_ownership(payload: String) -> void:
	var uid: String = GameState.player_uid.strip_edges()
	var tok: String = GameState.auth_token.strip_edges()
	if uid.is_empty() or tok.is_empty():
		return
	var base: String = AuthService.get_rtdb_base_url()
	if base.is_empty():
		return
	_op = "push"
	var url: String = "%s/users/%s/ownership.json?auth=%s" % [base, uid.uri_encode(), tok.uri_encode()]
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var err: int = _http.request(url, headers, HTTPClient.METHOD_PUT, payload)
	if err != OK:
		_log("push schedule err=%d" % err)
		ownership_sync_failed.emit("push_schedule_err_%d" % err)
		_op = ""


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var op_now: String = _op
	_op = ""
	var txt: String = body.get_string_from_utf8().strip_edges()
	if result != HTTPRequest.RESULT_SUCCESS:
		_log("%s failed result=%d" % [op_now, result])
		ownership_sync_failed.emit("%s_result_%d" % [op_now, result])
		return
	if response_code < 200 or response_code >= 300:
		_log("%s bad http=%d body=%s" % [op_now, response_code, txt.substr(0, mini(120, txt.length()))])
		ownership_sync_failed.emit("%s_http_%d" % [op_now, response_code])
		return
	if op_now == "pull":
		_apply_pull(txt)
	elif op_now == "push":
		_mark_synced_for_current_owner()
		ownership_updated.emit(true, true)
		_log("push ownership ok")


func _apply_pull(txt: String) -> void:
	if txt.is_empty() or txt == "null":
		_log("pull ownership empty, pushing local")
		request_push_all()
		return
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		_log("pull ownership invalid json, pushing local")
		request_push_all()
		return
	var d: Dictionary = data as Dictionary
	_last_remote_snapshot = d.duplicate(true)
	var wall_remote: Dictionary = d.get("wall", {})
	var platforms_remote: Dictionary = d.get("platforms", {})
	var wall_data: WallData = _resolve_wall_data()
	var platform_store: PlatformDataStore = _resolve_platform_store()
	if wall_data == null or platform_store == null:
		return
	var wall_res: Dictionary = wall_data.merge_from_dict(wall_remote)
	var p_res: Dictionary = platform_store.merge_from_dict(platforms_remote)
	ownership_updated.emit(bool(wall_res.get("changed", false)), bool(p_res.get("changed", false)))
	_log("pull ownership merged wall_changed=%s platform_changed=%s" % [str(bool(wall_res.get("changed", false))), str(bool(p_res.get("changed", false)))])


func _resolve_wall_data() -> WallData:
	if _bound_wall_data != null:
		return _bound_wall_data
	var w: WallData = WallData.new()
	w.auto_save_enabled = true
	w.load_from_file()
	return w


func _resolve_platform_store() -> PlatformDataStore:
	if _bound_platform_store != null:
		return _bound_platform_store
	var p: PlatformDataStore = PlatformDataStore.new()
	p.load_from_file()
	return p


func _mark_synced_for_current_owner() -> void:
	var uid: String = str(GameState.player_uid).strip_edges()
	if uid.is_empty():
		return
	var wall_data: WallData = _resolve_wall_data()
	var platform_store: PlatformDataStore = _resolve_platform_store()
	if wall_data != null:
		var changed_wall: bool = false
		for seg_id in wall_data.segments.keys():
			var seg: Dictionary = wall_data.get_segment(str(seg_id))
			var faces: Dictionary = seg.get("faces", {})
			for side in faces.keys():
				var fd: Dictionary = faces[side]
				if str(fd.get("owner", "")).strip_edges() == uid and str(fd.get("sync_status", "")) == "pending":
					fd["sync_status"] = "synced"
					faces[side] = fd
					changed_wall = true
			seg["faces"] = faces
			wall_data.segments[str(seg_id)] = seg
		if changed_wall and wall_data.auto_save_enabled:
			wall_data.save_to_file()
	if platform_store != null:
		var changed_platforms: bool = false
		for pid in platform_store.platforms.keys():
			var rec: Dictionary = platform_store.get_platform(str(pid))
			if str(rec.get("owner_uid", "")).strip_edges() == uid and str(rec.get("sync_status", "")) == "pending":
				rec["sync_status"] = "synced"
				platform_store.set_platform(str(pid), rec)
				changed_platforms = true
		if changed_platforms:
			platform_store.save_to_file()


func _log(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", "[OwnershipRemoteSync] " + msg)
	else:
		print("[OwnershipRemoteSync] ", msg)
