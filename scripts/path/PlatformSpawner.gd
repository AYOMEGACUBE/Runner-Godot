extends RefCounted
class_name PlatformSpawner
## Инстансинг платформ колена через существующую Platform.tscn (StaticBody2D + Platform.gd).
## Crumble назначается процедурно по высоте (не из JSON слота).

const TILE_W: float = 64.0
const TILE_H: float = 64.0

var _platform_scene: PackedScene = preload("res://Platform.tscn")


## Прогресс по вертикали относительно старта забега; шанс crumble линейно 5% → 90%.
static func crumble_probability_at_y(platform_y: float, run_start_y: float) -> float:
	var max_h: float = float(WorldSegmentGrid.FACE_AXIS_PX)
	var progress: float = (run_start_y - platform_y) / maxf(1.0, max_h)
	progress = clampf(progress, 0.0, 1.0)
	return lerpf(0.05, 0.90, progress)


func spawn_leg(chunks: Array, parent: Node, run_start_y: float, rng: RandomNumberGenerator) -> Node2D:
	var leg_root: Node2D = Node2D.new()
	leg_root.name = "LegContainer"
	parent.add_child(leg_root)
	for ch_variant in chunks:
		if typeof(ch_variant) != TYPE_DICTIONARY:
			continue
		var chunk: Dictionary = ch_variant as Dictionary
		var plats: Array = chunk.get("platforms", []) as Array
		var sorted: Array = plats.duplicate()
		sorted.sort_custom(func(a: Variant, b: Variant) -> bool:
			return int((a as Dictionary).get("order", 0)) < int((b as Dictionary).get("order", 0))
		)
		for p_variant in sorted:
			if typeof(p_variant) != TYPE_DICTIONARY:
				continue
			var slot: Dictionary = p_variant as Dictionary
			var node: Node2D = _platform_scene.instantiate() as Node2D
			if node == null:
				continue
			leg_root.add_child(node)
			_apply_slot(node, slot, run_start_y, rng)
	return leg_root


func _apply_slot(p: Node2D, slot: Dictionary, run_start_y: float, rng: RandomNumberGenerator) -> void:
	var pos: Vector2 = Vector2(float(slot.get("x", 0.0)), float(slot.get("y", 0.0)))
	var seg: int = maxi(1, int(slot.get("segments", 1)))
	var kind: String = str(slot.get("kind", "")).to_lower()
	var decoy: bool = bool(slot.get("is_decoy", false)) or kind == "decoy"
	p.global_position = pos
	p.scale = Vector2(float(seg), 1.0)
	p.set("suppress_auto_coin", true)
	p.set("coin_spawn_chance", 0.0)
	p.set("size", Vector2(TILE_W, TILE_H))
	p.set("is_decoy", decoy)
	p.set("fake_visual_only", decoy)
	if decoy:
		p.set("is_crumbling", false)
	else:
		var p_crumb: float = crumble_probability_at_y(pos.y, run_start_y)
		p.set("is_crumbling", rng.randf() < p_crumb)
	if p.has_method("apply_size_to_shape"):
		p.call("apply_size_to_shape")
	var cs: Node = p.get_node_or_null("CollisionShape2D")
	if cs is CollisionShape2D:
		if decoy:
			(cs as CollisionShape2D).disabled = true
		else:
			(cs as CollisionShape2D).disabled = false
	if decoy:
		p.set_collision_layer_value(1, false)
		p.set_collision_mask_value(1, false)
	else:
		p.set_collision_layer_value(1, true)
		p.set_collision_mask_value(1, true)
