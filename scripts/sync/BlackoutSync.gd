extends Node

signal sync_status_changed(entity: String, status: String, details: String)

const STATUS_PENDING: String = "pending"
const STATUS_SYNCED: String = "synced"
const STATUS_CONFLICT: String = "conflict"
const STATUS_FAILED: String = "failed"

var repo_root: String = ""
## Legacy sync path. Disabled for release runtime in favor of RTDB ownership sync.
@export var legacy_git_sync_enabled: bool = false

func _ready() -> void:
	repo_root = ProjectSettings.globalize_path("res://")

func push_all(wall_data: WallData, platform_store: PlatformDataStore) -> String:
	if not legacy_git_sync_enabled:
		emit_signal("sync_status_changed", "all", STATUS_FAILED, "legacy git sync disabled")
		return STATUS_FAILED
	emit_signal("sync_status_changed", "all", STATUS_PENDING, "push started")
	if not _write_repo_jsons(wall_data, platform_store):
		emit_signal("sync_status_changed", "all", STATUS_FAILED, "write repo json failed")
		return STATUS_FAILED
	var ok: bool = _run_git(["fetch"]) and _run_git(["pull", "--rebase"]) and _run_git(["add", "wall_segments.json", "platforms.json"]) and _run_git(["commit", "-m", "BLACKOUT sync update"]) and _run_git(["push"])
	if not ok:
		emit_signal("sync_status_changed", "all", STATUS_FAILED, "git push sequence failed")
		return STATUS_FAILED
	emit_signal("sync_status_changed", "all", STATUS_SYNCED, "push complete")
	return STATUS_SYNCED

func periodic_pull_and_merge(wall_data: WallData, platform_store: PlatformDataStore) -> String:
	if not legacy_git_sync_enabled:
		emit_signal("sync_status_changed", "all", STATUS_FAILED, "legacy git sync disabled")
		return STATUS_FAILED
	emit_signal("sync_status_changed", "all", STATUS_PENDING, "pull started")
	if not _run_git(["fetch"]) or not _run_git(["pull", "--rebase"]):
		emit_signal("sync_status_changed", "all", STATUS_FAILED, "git pull failed")
		return STATUS_FAILED
	var wall_remote: Dictionary = _read_repo_json("wall_segments.json")
	var platform_remote: Dictionary = _read_repo_json("platforms.json")

	var wall_merge: Dictionary = wall_data.merge_from_dict(wall_remote)
	var platform_merge: Dictionary = platform_store.merge_from_dict(platform_remote)
	if (wall_merge.get("conflicts", []) as Array).size() > 0 or (platform_merge.get("conflicts", []) as Array).size() > 0:
		emit_signal("sync_status_changed", "all", STATUS_CONFLICT, "merge conflicts found")
		return STATUS_CONFLICT

	emit_signal("sync_status_changed", "all", STATUS_SYNCED, "pull merged")
	return STATUS_SYNCED

func _write_repo_jsons(wall_data: WallData, platform_store: PlatformDataStore) -> bool:
	var wall_path: String = repo_root.path_join("wall_segments.json")
	var platform_path: String = repo_root.path_join("platforms.json")
	return _write_json_file(wall_path, wall_data.to_dict()) and _write_json_file(platform_path, platform_store.to_dict())

func _read_repo_json(file_name: String) -> Dictionary:
	var path: String = repo_root.path_join(file_name)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	var text: String = f.get_as_text()
	f.close()
	if json.parse(text) != OK:
		return {}
	return json.data if typeof(json.data) == TYPE_DICTIONARY else {}

func _write_json_file(path: String, payload: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true

func _run_git(args: Array[String]) -> bool:
	if OS.get_name() in ["Android", "iOS"]:
		return false
	var out: Array = []
	var git_args: Array[String] = [
		"--git-dir=" + repo_root + "/.git",
		"--work-tree=" + repo_root
	]
	git_args.append_array(args)
	var code: int = OS.execute("git", git_args, out, true, true)
	return code == 0
