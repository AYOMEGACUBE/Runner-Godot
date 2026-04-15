extends RefCounted
class_name LegBuilder
## Сборка колена из случайных чанков: зеркало по X относительно x=1000 в шаблоне, стыки по support_chain.

const REF_X_TEMPLATE: float = 1000.0
## Половина ширины платформы по центру: в шаблонах совпадает с логикой стыков (segments * 32 от центра до края).
const TILE_HALF_W_FROM_CENTER: float = 32.0
## Поверхность для расчёта прыжка: верх AABB при size.y=64 (как в Platform.tscn).
const PLATFORM_SURFACE_OFFSET_Y: float = 32.0

@export var min_joint_gap_px: float = 120.0
@export var max_joint_gap_px: float = 180.0
@export var target_joint_gap_px: float = 150.0
## Вертикальный отступ следующего колена от верха текущего (дублирует PathManager.leg_next_row_drop_px для согласованности в инспекторе, если LegBuilder сделать Resource).
@export_range(200, 800, 1.0) var leg_next_row_drop_px: float = 480.0

## С rules: jump_reach_max_fraction / safe_margin_x; выставляются из PathManager.
var jump_reach_fraction: float = 0.8
var safe_margin_x: float = 32.0
## Максимум |ΔY| за один вызов валидации (между чанками или коленами).
var max_y_correction_per_transition_px: float = 300.0

var registry: ChunkRegistry = null
var scaler: DifficultyScaler = null
## Перемешать model_id на каждое колено и брать по кругу (после каждого полного круга — новый shuffle). Даёт равномерное покрытие всех моделей за забег.
var use_shuffled_chunk_deck: bool = true
## Лог выбора чанка (ставится из PathManager.trace_chunk_selection).
var trace_chunk_selection: bool = false
## Индекс колена только для трассировки (PathManager выставляет перед build_leg).
var trace_leg_index: int = 0
## Якорь X старта забега и угол наклона пути (градусы); PathManager выставляет перед build_leg. При deg≈0 наклон не применяется.
var path_slope_origin_x: float = 0.0
var path_slope_deg: float = 0.0


func _trace_chunk_pick(message: String) -> void:
	print(message)
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		var fl: Node = (ml as SceneTree).root.get_node_or_null("/root/FileLogger")
		if fl != null and fl.has_method("write_log"):
			fl.call("write_log", message)


func _init(p_registry: ChunkRegistry = null, p_scaler: DifficultyScaler = null) -> void:
	registry = p_registry
	scaler = p_scaler


func _shuffle_model_id_deck(deck: Array, rng: RandomNumberGenerator) -> void:
	var n: int = deck.size()
	if n < 2:
		return
	for s in range(n - 1, 0, -1):
		var j: int = rng.randi_range(0, s)
		var tmp: Variant = deck[s]
		deck[s] = deck[j]
		deck[j] = tmp


func build_leg(start_pos: Vector2, direction: int, chunk_count: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	if registry == null or scaler == null or chunk_count <= 0:
		return out
	var last_trailing_edge: float = NAN
	var last_row_y: float = start_pos.y
	var dir_sign: float = 1.0 if direction >= 0 else -1.0

	var deck: Array = []
	var deck_pos: int = 0
	if use_shuffled_chunk_deck and registry.size() > 0:
		deck = registry.get_sorted_model_ids()
		_shuffle_model_id_deck(deck, rng)

	for i in range(chunk_count):
		var raw: Dictionary = {}
		if not deck.is_empty():
			if deck_pos >= deck.size():
				_shuffle_model_id_deck(deck, rng)
				deck_pos = 0
			var mid: int = int(deck[deck_pos])
			deck_pos += 1
			raw = registry.get_model_by_id(mid)
		else:
			raw = registry.get_random_chunk(rng)
		if raw.is_empty():
			push_warning("[LegBuilder] Empty chunk at index %d — registry size=%d" % [i, registry.size()])
			continue
		if trace_chunk_selection:
			_trace_chunk_pick("[PathManager][chunks] Leg %d | chunk %d/%d | model_id=%s | dir=%d" % [trace_leg_index, i + 1, chunk_count, str(raw.get("model_id", "?")), direction])
		var chunk: Dictionary = raw.duplicate(true)
		var ref_y: float = _first_support_y(chunk)
		var anchor: Vector2
		if i == 0:
			anchor = start_pos
		else:
			var gap: float = clampf(target_joint_gap_px, min_joint_gap_px, max_joint_gap_px)
			var cx0: float = _first_support_center_x_local(chunk)
			var seg0: int = _first_support_segments(chunk)
			var half0: float = float(seg0) * 32.0
			var want_center_x: float
			if dir_sign > 0.0:
				want_center_x = last_trailing_edge + gap + half0
			else:
				want_center_x = last_trailing_edge - gap - half0
			var ax: float = want_center_x - dir_sign * (cx0 - REF_X_TEMPLATE)
			anchor = Vector2(ax, last_row_y)
		_transform_chunk(chunk, anchor, direction, REF_X_TEMPLATE, ref_y)
		_apply_path_slope_to_chunk(chunk)
		out.append(chunk)
		if out.size() >= 2:
			validate_transition_adjust_landing_chunk(out[out.size() - 2], out[out.size() - 1])
		last_trailing_edge = _trailing_support_edge(chunk, direction)
		last_row_y = _trailing_support_center_y(chunk)

	return out


func _apply_path_slope_to_chunk(chunk: Dictionary) -> void:
	if path_slope_deg < 0.001:
		return
	var rad: float = deg_to_rad(path_slope_deg)
	var tan_slope: float = tan(rad)
	var plats: Array = chunk.get("platforms", []) as Array
	for p_variant in plats:
		if typeof(p_variant) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = p_variant as Dictionary
		var wx: float = float(d.get("x", 0.0))
		var wy: float = float(d.get("y", 0.0))
		var dist: float = absf(wx - path_slope_origin_x)
		d["y"] = wy - dist * tan_slope


## После трансформации: проверка прыжка с последней опоры предыдущего чанка на первую опору следующего; сдвигает **весь** landing_chunk по Y (±max_y_correction_per_transition_px).
func validate_transition_adjust_landing_chunk(prev_chunk: Dictionary, landing_chunk: Dictionary) -> void:
	var last_plat: Dictionary = _last_support_slot(prev_chunk)
	var first_plat: Dictionary = _first_support_slot(landing_chunk)
	if last_plat.is_empty() or first_plat.is_empty():
		return

	var dy_used: float = 0.0
	var delta_surf: float = _surface_y(first_plat) - _surface_y(last_plat)
	var v0: float = PhysicsConfig.JUMP_VELOCITY
	var g: float = PhysicsConfig.GRAVITY
	var disc: float = v0 * v0 + 2.0 * g * delta_surf

	if disc < 0.0:
		var max_h: float = (v0 * v0) / (2.0 * g)
		var target_delta: float = clampf(delta_surf, -max_h * 0.92, max_h * 0.78)
		var dy: float = clampf(target_delta - delta_surf, -max_y_correction_per_transition_px, max_y_correction_per_transition_px)
		if absf(dy) > 0.01:
			push_warning("[LegBuilder] Impossible jump (disc<0). Adjusting landing chunk Y by %.0f px." % dy)
			_apply_y_shift_to_chunk(landing_chunk, dy)
			dy_used += dy

	delta_surf = _surface_y(first_plat) - _surface_y(last_plat)
	disc = v0 * v0 + 2.0 * g * delta_surf
	if disc < 0.0:
		return

	var reach: float = PhysicsConfig.horizontal_reach_with_fraction(delta_surf, jump_reach_fraction)
	var dx_centers: float = absf(float(first_plat.get("x", 0.0)) - float(last_plat.get("x", 0.0)))
	var edge_gap: float = dx_centers - _half_width_from_center(last_plat) - _half_width_from_center(first_plat)
	edge_gap = maxf(0.0, edge_gap)

	if edge_gap > reach - safe_margin_x + 0.01:
		var y_pull: float = (edge_gap - (reach - safe_margin_x)) * 0.6
		var cap: float = maxf(0.0, max_y_correction_per_transition_px - absf(dy_used))
		y_pull = clampf(y_pull, -cap, cap)
		if absf(y_pull) > 0.01:
			push_warning("[LegBuilder] Gap exceeds reach. Adjusting landing chunk Y by %.0f px." % y_pull)
			_apply_y_shift_to_chunk(landing_chunk, y_pull)


func _support_chain_slots(chunk: Dictionary) -> Array:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	var acc: Array = []
	for idx_var in chain:
		var pi: int = int(idx_var)
		if pi < 0 or pi >= plats.size():
			continue
		var d: Dictionary = plats[pi] as Dictionary
		acc.append(d)
	return acc


func _last_support_slot(chunk: Dictionary) -> Dictionary:
	var acc: Array = _support_chain_slots(chunk)
	if acc.is_empty():
		return {}
	return acc[acc.size() - 1]


func _first_support_slot(chunk: Dictionary) -> Dictionary:
	var acc: Array = _support_chain_slots(chunk)
	if acc.is_empty():
		return {}
	return acc[0]


func _surface_y(slot: Dictionary) -> float:
	return float(slot.get("y", 0.0)) - PLATFORM_SURFACE_OFFSET_Y


func _half_width_from_center(slot: Dictionary) -> float:
	return float(maxi(1, int(slot.get("segments", 1)))) * TILE_HALF_W_FROM_CENTER


func _apply_y_shift_to_chunk(chunk: Dictionary, dy: float) -> void:
	var plats: Array = chunk.get("platforms", []) as Array
	for pv in plats:
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = pv as Dictionary
		d["y"] = float(d.get("y", 0.0)) + dy


func _first_support_y(chunk: Dictionary) -> float:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.is_empty() or plats.is_empty():
		return 0.0
	var pi: int = int(chain[0])
	if pi < 0 or pi >= plats.size():
		return 0.0
	return float((plats[pi] as Dictionary).get("y", 0.0))


func _first_support_center_x_local(chunk: Dictionary) -> float:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.is_empty() or plats.is_empty():
		return REF_X_TEMPLATE
	var pi: int = int(chain[0])
	if pi < 0 or pi >= plats.size():
		return REF_X_TEMPLATE
	return float((plats[pi] as Dictionary).get("x", REF_X_TEMPLATE))


func _first_support_segments(chunk: Dictionary) -> int:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.is_empty() or plats.is_empty():
		return 1
	var pi: int = int(chain[0])
	if pi < 0 or pi >= plats.size():
		return 1
	return maxi(1, int((plats[pi] as Dictionary).get("segments", 1)))


func _transform_chunk(chunk: Dictionary, anchor: Vector2, direction: int, ref_x: float, ref_y: float) -> void:
	var plats: Array = chunk.get("platforms", []) as Array
	for p_variant in plats:
		var p: Dictionary = p_variant as Dictionary
		var lx: float = float(p.get("x", ref_x))
		var ly: float = float(p.get("y", ref_y))
		var nx: float
		if direction >= 0:
			nx = anchor.x + (lx - ref_x)
		else:
			nx = anchor.x - (lx - ref_x)
		var ny: float = anchor.y + (ly - ref_y)
		p["x"] = nx
		p["y"] = ny


func _trailing_support_edge(chunk: Dictionary, direction: int) -> float:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.is_empty() or plats.is_empty():
		return REF_X_TEMPLATE
	if direction >= 0:
		var max_right: float = -1.0e15
		for idx_variant in chain:
			var pi: int = int(idx_variant)
			if pi < 0 or pi >= plats.size():
				continue
			var d: Dictionary = plats[pi] as Dictionary
			var cx: float = float(d.get("x", 0.0))
			var sg: int = maxi(1, int(d.get("segments", 1)))
			var right: float = cx + float(sg) * 32.0
			max_right = maxf(max_right, right)
		return max_right
	var min_left: float = 1.0e15
	for idx_variant in chain:
		var pi: int = int(idx_variant)
		if pi < 0 or pi >= plats.size():
			continue
		var d2: Dictionary = plats[pi] as Dictionary
		var cx2: float = float(d2.get("x", 0.0))
		var sg2: int = maxi(1, int(d2.get("segments", 1)))
		var left: float = cx2 - float(sg2) * 32.0
		min_left = minf(min_left, left)
	return min_left


func _trailing_support_center_y(chunk: Dictionary) -> float:
	var plats: Array = chunk.get("platforms", []) as Array
	var chain: Array = chunk.get("support_chain_indices", []) as Array
	if chain.is_empty() or plats.is_empty():
		return 0.0
	var last_i: int = int(chain[chain.size() - 1])
	if last_i < 0 or last_i >= plats.size():
		return 0.0
	return float((plats[last_i] as Dictionary).get("y", 0.0))
