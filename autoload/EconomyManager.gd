extends Node
## Offline-first экономика мега-куба: ключи граней, цены из economy.json, разрежённое хранилище покупок.
## Autoload: EconomyManager

signal economy_price_calculated(
	price: int, side_external: int, is_owned: bool, face_id: int, segment_id: String
)
## [FIX] Уведомление для UI (миникарта) без изменения формулы face_id
signal face_purchase_recorded(face_id: int, price_paid: int)

const RES_CONFIG_PATH: String = "res://config/economy.json"
const USER_OWNED_PATH: String = "user://economy/owned_faces.json"
const USER_CACHE_PATH: String = "user://economy/config_cache.json"

var _version: String = "1.0"
var _price_paid: int = 50
var _price_buyout_free: int = 400
var _coin_to_usd: float = 0.01
var _free_side_internals: Dictionary = {}
var _wall_side_to_face: Dictionary = {}
var _side_name_to_external: Dictionary = {}

## face_id (строка) -> { "ts": int, "price_paid": int }
var _owned_faces: Dictionary = {}

var _save_timer: Timer


func _ready() -> void:
	_ensure_user_dirs()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 2.0
	add_child(_save_timer)
	_save_timer.timeout.connect(_flush_owned_to_disk)
	load_economy_config()
	load_owned_faces_from_disk()


func _ensure_user_dirs() -> void:
	var d := DirAccess.open("user://")
	if d == null:
		return
	if not d.dir_exists("economy"):
		d.make_dir("economy")


func load_economy_config() -> void:
	var bundled: Dictionary = _load_json_file(RES_CONFIG_PATH)
	if bundled.is_empty() and FileAccess.file_exists(RES_CONFIG_PATH):
		push_warning("EconomyManager: economy.json parse failed")
	var cached: Dictionary = {}
	if FileAccess.file_exists(USER_CACHE_PATH):
		cached = _load_json_file(USER_CACHE_PATH)
	var bundled_ver: String = str(bundled.get("version", "1.0"))
	var cached_ver: String = str(cached.get("version", "0.0"))
	var use_dict: Dictionary = bundled
	if _version_compare(bundled_ver, cached_ver) > 0:
		use_dict = bundled
		if not bundled.is_empty():
			_write_json_file(USER_CACHE_PATH, bundled)
	elif not cached.is_empty():
		use_dict = cached
	_apply_economy_dict(use_dict)


func _apply_economy_dict(data: Dictionary) -> void:
	_version = str(data.get("version", "2.0"))
	_price_paid = int(data.get("price_paid", 50))
	_price_buyout_free = int(data.get("price_buyout_free", 400))
	_coin_to_usd = float(data.get("coin_to_usd", 0.01))
	_free_side_internals.clear()
	var free_arr: Array = data.get("free_sides_external", []) as Array
	for x in free_arr:
		var ext: int = int(x)
		var internal_i: int = clampi(ext - 1, 0, 5)
		_free_side_internals[internal_i] = true
	_wall_side_to_face.clear()
	var wmap: Dictionary = data.get("wall_side_to_face_global", {}) as Dictionary
	for k in wmap.keys():
		_wall_side_to_face[str(k)] = int(wmap[k])
	_side_name_to_external.clear()
	var smap: Dictionary = data.get("side_name_to_external", {}) as Dictionary
	for k in smap.keys():
		_side_name_to_external[str(k)] = int(smap[k])
	if _wall_side_to_face.is_empty():
		_wall_side_to_face = {
			"front": 4, "back": 5, "left": 0, "right": 1, "top": 2, "bottom": 3
		}
	if _side_name_to_external.is_empty():
		_side_name_to_external = {
			"front": 1, "back": 2, "left": 3, "right": 4, "top": 5, "bottom": 6
		}
	if _free_side_internals.is_empty():
		_free_side_internals[0] = true
		_free_side_internals[4] = true


static func _version_compare(a: String, b: String) -> int:
	var pa: PackedStringArray = a.strip_edges().split(".")
	var pb: PackedStringArray = b.strip_edges().split(".")
	var n: int = maxi(pa.size(), pb.size())
	for i in range(n):
		var av: int = int(pa[i]) if i < pa.size() else 0
		var bv: int = int(pb[i]) if i < pb.size() else 0
		if av < bv:
			return -1
		if av > bv:
			return 1
	return 0


func load_owned_faces_from_disk() -> void:
	_owned_faces.clear()
	if not FileAccess.file_exists(USER_OWNED_PATH):
		return
	var data: Dictionary = _load_json_file(USER_OWNED_PATH)
	var raw: Variant = data.get("faces", {})
	if raw is Dictionary:
		_owned_faces = (raw as Dictionary).duplicate(true)


func calculate_face_id(face_global: int, u: int, v: int, side_external: int) -> int:
	var fg: int = clampi(face_global, 0, 5)
	var uu: int = clampi(u, 0, CubeMath.SEGMENTS_PER_SIDE - 1)
	var vv: int = clampi(v, 0, CubeMath.SEGMENTS_PER_SIDE - 1)
	var se: int = clampi(side_external, 1, 6)
	return CubeMath.calculate_face_id(fg, uu, vv, se)


func face_global_for_wall_side(wall_side_name: String) -> int:
	var key: String = wall_side_name.to_lower()
	if _wall_side_to_face.has(key):
		return clampi(int(_wall_side_to_face[key]), 0, 5)
	return 4


func side_external_for_name(side_name: String) -> int:
	## [FIX] Неизвестное/пустое имя не должно мапиться на external 1 — в economy.json [1,5] часто free → ложный «всегда 0 coin».
	var key: String = side_name.strip_edges().to_lower()
	if key.is_empty():
		return 2
	if _side_name_to_external.has(key):
		return clampi(int(_side_name_to_external[key]), 1, 6)
	return 2


func parse_segment_grid(segment_id: String) -> Vector2i:
	var parts: PackedStringArray = segment_id.split("_")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


func face_id_from_wall_segment(wall_side_name: String, segment_id: String, side_name: String) -> int:
	var fg: int = face_global_for_wall_side(wall_side_name)
	var g: Vector2i = parse_segment_grid(segment_id)
	var uv: Vector2i = CubeMath.grid_xy_to_uv(g.x, g.y)
	var ext: int = side_external_for_name(side_name)
	return calculate_face_id(fg, uv.x, uv.y, ext)


func get_coin_to_usd() -> float:
	return _coin_to_usd


func get_buyout_free_coin() -> int:
	return _price_buyout_free


func is_side_external_free(side_external: int) -> bool:
	var internal_f: int = clampi(side_external - 1, 0, 5)
	return _free_side_internals.has(internal_f)


func get_price(side_external: int, face_has_owner: bool) -> int:
	if face_has_owner:
		var internal_i: int = clampi(side_external - 1, 0, 5)
		if _free_side_internals.has(internal_i):
			return _price_buyout_free
		return 0
	var internal_f: int = clampi(side_external - 1, 0, 5)
	if _free_side_internals.has(internal_f):
		return 0
	return _price_paid


func get_listing_price_for_hit(
	wall_side_name: String, segment_id: String, segment_side_name: String, wall_data: WallData
) -> int:
	if wall_data == null:
		return _price_paid
	var ext: int = side_external_for_name(segment_side_name)
	var fd: Dictionary = wall_data.get_face_data(segment_id, segment_side_name)
	var owned: bool = str(fd.get("owner", "")) != ""
	return get_price(ext, owned)


func is_face_owned(face_id: int) -> bool:
	return _owned_faces.has(str(face_id))


func record_face_purchase(face_id: int, price_paid: int) -> void:
	_owned_faces[str(face_id)] = {"ts": Time.get_unix_time_from_system(), "price_paid": price_paid}
	face_purchase_recorded.emit(face_id, price_paid)
	_schedule_save_owned()


func buy_face(face_id: int, price: int) -> bool:
	if is_face_owned(face_id):
		return false
	if not Engine.has_singleton("GameState"):
		return false
	if not GameState.spend_wallet_coins(price):
		return false
	record_face_purchase(face_id, price)
	return true


## 3D рейкаст: без WallData — учёт только журнала покупок на устройстве.
func on_segment_hit(hit_point: Vector3, hit_normal: Vector3, side_external: int) -> void:
	var hv: Dictionary = CubeMath.hit_to_face_and_uv_cells(hit_point, hit_normal)
	var fg: int = int(hv.get("face_global", 0))
	var u: int = int(hv.get("u", 0))
	var v: int = int(hv.get("v", 0))
	var fid: int = calculate_face_id(fg, u, v, side_external)
	if is_face_owned(fid):
		economy_price_calculated.emit(0, side_external, true, fid, "")
		return
	var price: int = get_price(side_external, false)
	economy_price_calculated.emit(price, side_external, false, fid, "")


## 2D стена CubeView: segment_side — текущая грань кубика (front/back/…).
func on_wall_hit_2d(
	wall_side_name: String, wall_data: WallData, segment_id: String, segment_side_name: String
) -> void:
	var ext: int = side_external_for_name(segment_side_name)
	var fid: int = face_id_from_wall_segment(wall_side_name, segment_id, segment_side_name)
	var fd: Dictionary = wall_data.get_face_data(segment_id, segment_side_name) if wall_data else {}
	var wall_has_owner: bool = str(fd.get("owner", "")) != ""
	var journal_owned: bool = is_face_owned(fid)
	var price: int = 0
	if journal_owned:
		price = 0
	else:
		price = get_listing_price_for_hit(wall_side_name, segment_id, segment_side_name, wall_data)
	var display_owned: bool = wall_has_owner or journal_owned
	economy_price_calculated.emit(price, ext, display_owned, fid, segment_id)


func _schedule_save_owned() -> void:
	_save_timer.stop()
	_save_timer.start()


func _flush_owned_to_disk() -> void:
	call_deferred("_flush_owned_to_disk_deferred")


func _flush_owned_to_disk_deferred() -> void:
	var payload: Dictionary = {"version": 1, "faces": _owned_faces}
	_write_json_file(USER_OWNED_PATH, payload)


func _load_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) and path.begins_with("res://"):
		push_warning("EconomyManager: missing %s" % path)
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var p: JSON = JSON.new()
	if p.parse(text) != OK:
		return {}
	if p.data is Dictionary:
		return p.data as Dictionary
	return {}


func _write_json_file(path: String, data: Dictionary) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("EconomyManager: cannot write %s" % path)
		return
	var s: String = JSON.stringify(data, "\t", false)
	f.store_string(s)
	f.close()
