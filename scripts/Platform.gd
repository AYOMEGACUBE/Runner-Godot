extends StaticBody2D

signal platform_lifecycle_ended(platform: Node2D)

func _log(message: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", message)
	else:
		print(message)

@export var debug_log_ready: bool = false
@export var size: Vector2 = Vector2(64, 64)
@export var is_crumbling: bool = false
@export var crumble_delay: float = 0.08
@export var suppress_auto_coin: bool = false
@export var is_decoy: bool = false
@export var fake_visual_only: bool = false
@export var image_path_runtime: String = ""
@export var jump_image_up_path_runtime: String = ""
@export var jump_image_down_path_runtime: String = ""

@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var _player_landed: bool = false
var _crumble_timer: float = 0.0
var _player_ref: CharacterBody2D = null
var _crumble_dispatched: bool = false
var _runtime_texture: Texture2D = null

func _ready() -> void:
	_crumble_dispatched = false
	if is_decoy or fake_visual_only:
		is_crumbling = false
	if debug_log_ready:
		_log("[PLATFORM_READY] pos=%s size=%s crumbling=%s" % [global_position, size, is_crumbling])

	apply_size_to_shape()
	_reload_runtime_texture()

	if is_decoy or fake_visual_only:
		set_collision_layer_value(1, false)
		set_collision_mask_value(1, false)
		if collision_shape:
			collision_shape.disabled = true
		queue_redraw()
		return

	set_collision_layer_value(1, true)
	for i in range(2, 33):
		set_collision_layer_value(i, false)
	if collision_shape:
		collision_shape.disabled = false

	queue_redraw()

func apply_size_to_shape() -> void:
	if collision_shape == null:
		return
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = size
	collision_shape.shape = rect_shape
	collision_shape.one_way_collision = true
	collision_shape.one_way_collision_margin = 10.0

func prepare_for_pool() -> void:
	for conn in platform_lifecycle_ended.get_connections():
		if conn is Dictionary and (conn as Dictionary).has("callable"):
			platform_lifecycle_ended.disconnect((conn as Dictionary)["callable"])
	is_crumbling = false
	_player_landed = false
	_crumble_timer = 0.0
	_crumble_dispatched = false
	_player_ref = null
	image_path_runtime = ""
	jump_image_up_path_runtime = ""
	jump_image_down_path_runtime = ""
	_runtime_texture = null
	set_collision_layer_value(1, true)
	set_collision_mask_value(1, true)
	for i in range(2, 33):
		set_collision_mask_value(i, false)
	if collision_shape:
		collision_shape.disabled = false
	queue_redraw()


func set_runtime_images(up_path: String, down_path: String = "") -> void:
	jump_image_up_path_runtime = up_path.strip_edges()
	jump_image_down_path_runtime = down_path.strip_edges()
	image_path_runtime = jump_image_up_path_runtime
	_reload_runtime_texture()
	queue_redraw()


func _reload_runtime_texture() -> void:
	_runtime_texture = null
	var p: String = image_path_runtime.strip_edges()
	if p == "":
		return
	if p.begins_with("res://") and ResourceLoader.exists(p):
		var tex: Resource = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REUSE)
		if tex is Texture2D:
			_runtime_texture = tex as Texture2D
			return
	var img: Image = Image.new()
	var err: Error = img.load(p)
	if err == OK and not img.is_empty():
		_runtime_texture = ImageTexture.create_from_image(img)


func has_runtime_texture() -> bool:
	return _runtime_texture != null

func _physics_process(_delta: float) -> void:
	if not is_crumbling or _player_landed:
		return

	if _player_ref == null:
		_player_ref = get_tree().get_first_node_in_group("player")
		if _player_ref == null:
			var lvl := get_parent().get_parent()
			if lvl:
				_player_ref = lvl.get_node_or_null("Player")

	if _player_ref == null:
		return

	var collision_count: int = _player_ref.get_slide_collision_count()
	for i in range(collision_count):
		var collision = _player_ref.get_slide_collision(i)
		if collision and collision.get_collider() == self:
			var normal: Vector2 = collision.get_normal()
			if normal.y < -0.7:
				_player_landed = true
				_crumble_timer = 0.0
				set_collision_layer_value(1, false)
				set_collision_mask_value(1, false)
				if collision_shape:
					collision_shape.disabled = true
				_log("[PLATFORM_LANDED] pos=%s" % global_position)
				break

func _process(delta: float) -> void:
	if not is_crumbling or not _player_landed or _crumble_dispatched:
		return

	_crumble_timer += delta
	queue_redraw()
	if _crumble_timer >= crumble_delay:
		_crumble_dispatched = true
		_log("[PLATFORM_CRUMBLE] pos=%s" % global_position)
		platform_lifecycle_ended.emit(self)

func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	if _runtime_texture != null:
		draw_texture_rect(_runtime_texture, rect, false, Color(1, 1, 1, 1))
	elif is_crumbling:
		var alpha: float = 1.0
		if _player_landed:
			alpha = max(0.0, 1.0 - (_crumble_timer / crumble_delay))
		draw_rect(rect, Color(0.9, 0.2, 0.1, alpha))
	else:
		draw_rect(rect, Color(0.1, 0.9, 0.2, 1.0))
