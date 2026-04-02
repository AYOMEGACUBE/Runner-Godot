extends RefCounted
class_name PlatformPool

const MAX_POOL_SIZE: int = 256

var _scene: PackedScene
var _root: Node2D
var _available: Array[Node2D] = []
var _in_available: Dictionary = {}
var _overflow_count: int = 0
var _reuse_count: int = 0
const MAX_OVERFLOW_LOGS: int = 12

func _init(platform_scene: PackedScene, platforms_root: Node2D, initial_count: int) -> void:
	_scene = platform_scene
	_root = platforms_root
	_prebuild(mini(initial_count, MAX_POOL_SIZE))

func _log(msg: String) -> void:
	FileLogger.write_log(msg)

func _prebuild(count: int) -> void:
	var n: int = clampi(count, 0, MAX_POOL_SIZE)
	for i in n:
		var p: Node2D = _scene.instantiate() as Node2D
		if p == null:
			push_error("PlatformPool: scene root must be Node2D")
			return
		p.set("suppress_auto_coin", true)
		_root.add_child(p)
		p.visible = false
		p.process_mode = Node.PROCESS_MODE_DISABLED
		p.global_position = Vector2(-100000.0, -100000.0)
		var id: int = p.get_instance_id()
		_available.append(p)
		_in_available[id] = true
	_log("[POOL] prebuilt count=%d" % n)

func clear() -> void:
	for p in _available:
		if is_instance_valid(p):
			p.queue_free()
	_available.clear()
	_in_available.clear()
	_reuse_count = 0
	_overflow_count = 0
	_log("[POOL] clear")

func get_platform() -> Node2D:
	if _available.is_empty():
		var total_live: int = _root.get_child_count()
		if total_live >= MAX_POOL_SIZE:
			_log("[POOL] MAX_POOL_SIZE=%d reached — cannot create" % MAX_POOL_SIZE)
			return null
		_overflow_count += 1
		if _overflow_count <= MAX_OVERFLOW_LOGS:
			_log("[POOL] empty — extra instantiate #%d" % _overflow_count)
		var extra: Node2D = _scene.instantiate() as Node2D
		extra.set("suppress_auto_coin", true)
		_root.add_child(extra)
		_activate(extra)
		return extra
	var p: Node2D = _available.pop_back() as Node2D
	var pid: int = p.get_instance_id()
	_in_available.erase(pid)
	_reuse_count += 1
	_log("[POOL] reused platform id=%d total_reuse=%d avail=%d" % [pid, _reuse_count, _available.size()])
	_activate(p)
	return p

func _activate(p: Node2D) -> void:
	p.process_mode = Node.PROCESS_MODE_INHERIT
	p.visible = true

func release_platform(p: Node2D) -> void:
	if p == null or not is_instance_valid(p):
		return
	var id: int = p.get_instance_id()
	if _in_available.has(id):
		return
	if p.has_method("prepare_for_pool"):
		p.prepare_for_pool()
	p.visible = false
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.global_position = Vector2(-100000.0, -100000.0)
	if _available.size() + 1 > MAX_POOL_SIZE:
		p.queue_free()
		return
	_available.append(p)
	_in_available[id] = true

func available_count() -> int:
	return _available.size()

func total_nodes() -> int:
	return _root.get_child_count()

func reuse_count() -> int:
	return _reuse_count
