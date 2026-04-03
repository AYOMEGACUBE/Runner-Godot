extends RefCounted
class_name PlatformSpawner
## Инстансинг платформ колена через существующую Platform.tscn (StaticBody2D + Platform.gd).

const TILE_W: float = 64.0
const TILE_H: float = 64.0

var _platform_scene: PackedScene = preload("res://Platform.tscn")


func spawn_leg(chunks: Array, parent: Node) -> Node2D:
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
			_apply_slot(node, slot)
	return leg_root


func _apply_slot(p: Node2D, slot: Dictionary) -> void:
	var pos: Vector2 = Vector2(float(slot.get("x", 0.0)), float(slot.get("y", 0.0)))
	var seg: int = maxi(1, int(slot.get("segments", 1)))
	var vanish: bool = int(slot.get("vanish", 0)) != 0
	var kind: String = str(slot.get("kind", "")).to_lower()
	if kind == "crumble":
		vanish = true
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
		p.set("is_crumbling", vanish)
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
