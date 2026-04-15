extends CanvasLayer

@export var level_path: NodePath = NodePath("..")

var _level: Node = null
var _label: RichTextLabel = null
var _btn: Button = null
var _seed_edit: LineEdit = null

func _seed_manager() -> Node:
	return get_node_or_null("/root/SeedManager")

func _ready() -> void:
	_level = get_node_or_null(level_path)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 8
	panel.offset_top = 8
	panel.offset_right = 420
	panel.offset_bottom = 200
	add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.scroll_active = false
	_label.custom_minimum_size = Vector2(400, 120)
	v.add_child(_label)
	_seed_edit = LineEdit.new()
	_seed_edit.placeholder_text = "run seed (int)"
	var sm: Node = _seed_manager()
	_seed_edit.text = str(int(sm.get("global_seed")) if sm != null else 0)
	v.add_child(_seed_edit)
	_btn = Button.new()
	_btn.text = "Restart same seed"
	v.add_child(_btn)
	_btn.pressed.connect(_on_restart_same_seed)
	process_mode = Node.PROCESS_MODE_ALWAYS

func _process(_delta: float) -> void:
	if _label == null:
		return
	var pl: int = 0
	var pool_a: int = 0
	var pool_t: int = 0
	var path_id: String = "—"
	if _level != null:
		if _level.get("platforms") != null:
			pl = (_level.get("platforms") as Array).size()
		var pp = _level.get("platform_pool")
		if pp != null:
			pool_a = pp.available_count()
			pool_t = pp.total_nodes()
		var ps = _level.get("path_selector")
		if ps != null and ps.active_model != null:
			path_id = str(ps.active_model_index) + " (id=" + str(ps.active_model.model_id) + ")"
	var fps: float = Engine.get_frames_per_second()
	var sm2: Node = _seed_manager()
	var seed_now: int = int(sm2.get("global_seed")) if sm2 != null else 0
	var locked: bool = bool(sm2.call("is_seed_locked")) if sm2 != null and sm2.has_method("is_seed_locked") else false
	_label.text = "[b]Run debug[/b]\nseed=%s locked=%s\npath=%s platforms=%d pool avail=%d total=%d\nFPS=%.1f" % [
		seed_now, locked, path_id, pl, pool_a, pool_t, fps
	]

func _on_restart_same_seed() -> void:
	var t: String = _seed_edit.text.strip_edges()
	if t.is_valid_int():
		var sm: Node = _seed_manager()
		if sm != null:
			sm.call("lock_seed", false)
			sm.call("assign_run_seed", int(t))
			sm.call("lock_seed", true)
	get_tree().reload_current_scene()
