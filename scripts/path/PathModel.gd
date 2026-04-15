extends RefCounted
class_name PathModel

var model_id: int = 0
var trend_degrees: float = 2.0
var steps: Array = []
## Выпеченные слоты: центр платформы, число сегментов по X, vanish (0/1), опционально is_decoy. Level только размещает.
var platforms: Array = []
## Если непусто, validate_full проверяет прыжки только между соседними индексами здесь (карты с decoy между опорными в platforms[]).
var support_chain_indices: Array = []

func to_dict() -> Dictionary:
	var out: Dictionary = {
		"model_id": model_id,
		"trend_degrees": trend_degrees,
		"steps": steps,
	}
	if platforms.size() > 0:
		out["platforms"] = platforms.duplicate(true)
	if support_chain_indices.size() > 0:
		out["support_chain_indices"] = support_chain_indices.duplicate()
	return out

static func from_dict(data: Dictionary) -> PathModel:
	var m: PathModel = PathModel.new()
	m.model_id = int(data.get("model_id", 0))
	m.trend_degrees = float(data.get("trend_degrees", 2.0))
	var src_steps: Array = data.get("steps", [])
	for raw_step in src_steps:
		if typeof(raw_step) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = raw_step
		m.steps.append({
			"x_gap": float(d.get("x_gap", 180.0)),
			"y_delta": float(d.get("y_delta", -12.0)),
			"wave_id": int(d.get("wave_id", 0)),
			"decoy_count": int(d.get("decoy_count", 1)),
			"size": str(d.get("size", "")),
		})
	m.support_chain_indices.clear()
	var sch: Variant = data.get("support_chain_indices", [])
	if typeof(sch) == TYPE_ARRAY:
		for el in sch:
			m.support_chain_indices.append(int(el))
	var raw_plats: Variant = data.get("platforms", [])
	if typeof(raw_plats) == TYPE_ARRAY:
		var plist: Array = []
		for rp in raw_plats:
			if typeof(rp) == TYPE_DICTIONARY:
				plist.append(rp)
		if plist.size() > 0:
			var has_order: bool = false
			var probe: Dictionary = plist[0]
			if probe.has("order"):
				has_order = true
			if has_order:
				plist.sort_custom(func(a: Variant, b: Variant) -> bool:
					if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
						return false
					return int((a as Dictionary).get("order", 0)) < int((b as Dictionary).get("order", 0))
				)
			for pd in plist:
				var pdd: Dictionary = pd
				m.platforms.append({
					"x": float(pdd.get("x", 0.0)),
					"y": float(pdd.get("y", 0.0)),
					"segments": maxi(1, int(pdd.get("segments", 1))),
					"vanish": 1 if int(pdd.get("vanish", 0)) != 0 else 0,
					"is_decoy": bool(pdd.get("is_decoy", false)),
				})
	return m

func _size_key_for_step(step: Dictionary, step_index: int) -> String:
	var sz: Variant = step.get("size", "")
	if typeof(sz) == TYPE_STRING:
		var ks: String = (sz as String).to_lower().strip_edges()
		if ks == "small" or ks == "medium" or ks == "large":
			return ks
	var idx: int = (abs(int(step.get("decoy_count", 1))) + step_index) % 3
	var keys: Array[String] = ["small", "medium", "large"]
	return keys[idx]

func _segment_count_for_size_key(key: String, rules: Dictionary, tile_w: float) -> int:
	var sizes: Dictionary = rules["platform_sizes"]
	if not sizes.has(key):
		return 1
	var arr: Variant = sizes[key]
	if typeof(arr) != TYPE_ARRAY or (arr as Array).size() < 1:
		return 1
	var w: float = float((arr as Array)[0])
	if tile_w <= 0.0:
		return 1
	return maxi(1, int(round(w / tile_w)))

func _clamp_x_for_jump(
	last_pos: Vector2, last_seg: int, target: Vector2, new_seg: int,
	tile_w: float, plat_h: float, safe_margin_x: float,
	bounds: Dictionary,
	reach_fraction: float = 1.0
) -> float:
	var start_surface_y: float = last_pos.y - plat_h * 0.5
	var target_surface_y: float = target.y - plat_h * 0.5
	var delta_surf: float = target_surface_y - start_surface_y
	var rf: float = clampf(reach_fraction, 0.05, 1.0)
	var reach: float = PhysicsConfig.horizontal_reach_surface_to_surface(delta_surf) * rf
	var half_p: float = float(last_seg) * tile_w * 0.5
	var half_n: float = float(new_seg) * tile_w * 0.5
	var max_dx: float = max(0.0, reach + half_p + half_n - safe_margin_x)
	var dx: float = target.x - last_pos.x
	dx = clampf(dx, -max_dx, max_dx)
	var x: float = last_pos.x + dx
	var lim: Vector2 = _center_x_limits_for_segments(new_seg, tile_w, bounds)
	return clampf(x, lim.x, lim.y)

func _center_x_limits_for_segments(segments: int, tile_w: float, bounds: Dictionary) -> Vector2:
	var half_w: float = float(segments) * tile_w * 0.5
	var min_x: float = float(bounds["min_x"]) + half_w
	var max_x: float = float(bounds["max_x"]) - half_w
	if max_x < min_x:
		var mid: float = (min_x + max_x) * 0.5
		return Vector2(mid, mid)
	return Vector2(min_x, max_x)

func _reachable_x_bounds(
	last_pos: Vector2, last_seg: int, target_y: float, new_seg: int,
	tile_w: float, plat_h: float, safe_margin_x: float, bounds: Dictionary, reach_fraction: float
) -> Vector2:
	var start_surface_y: float = last_pos.y - plat_h * 0.5
	var target_surface_y: float = target_y - plat_h * 0.5
	var delta_surf: float = target_surface_y - start_surface_y
	var rf: float = clampf(reach_fraction, 0.05, 1.0)
	var reach: float = PhysicsConfig.horizontal_reach_surface_to_surface(delta_surf) * rf
	var half_p: float = float(last_seg) * tile_w * 0.5
	var half_n: float = float(new_seg) * tile_w * 0.5
	var max_dx: float = max(0.0, reach + half_p + half_n - safe_margin_x)
	var lim: Vector2 = _center_x_limits_for_segments(new_seg, tile_w, bounds)
	var x_lo: float = clampf(last_pos.x - max_dx, lim.x, lim.y)
	var x_hi: float = clampf(last_pos.x + max_dx, lim.x, lim.y)
	if x_lo > x_hi:
		var mid2: float = (x_lo + x_hi) * 0.5
		return Vector2(mid2, mid2)
	return Vector2(x_lo, x_hi)

func _two_slots_overlap(
	p0: Vector2, s0: int, p1: Vector2, s1: int, tile_w: float, plat_h: float, min_edge_gap: float, vertical_gap: float
) -> bool:
	var hw0: float = float(s0) * tile_w * 0.5
	var hw1: float = float(s1) * tile_w * 0.5
	var dx: float = abs(p0.x - p1.x)
	var dy: float = abs(p0.y - p1.y)
	return dx < hw0 + hw1 + min_edge_gap and dy < plat_h + vertical_gap

func _slot_overlaps_any_in_list(
	pos: Vector2, seg: int, existing: Array, tile_w: float, plat_h: float, min_g: float, vg: float
) -> bool:
	var y_cut: float = plat_h + vg + 2.0
	for e in existing:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if abs(float(d["y"]) - pos.y) > y_cut:
			continue
		var ep: Vector2 = Vector2(float(d["x"]), float(d["y"]))
		var es: int = int(d["segments"])
		if _two_slots_overlap(pos, seg, ep, es, tile_w, plat_h, min_g, vg):
			return true
	return false

func _pick_x_clear_in_bounds(
	preferred_x: float, y: float, seg: int, existing: Array,
	x_bounds: Vector2, tile_w: float, plat_h: float, min_g: float, vg: float
) -> float:
	var x_lo: float = x_bounds.x
	var x_hi: float = x_bounds.y
	var px: float = clampf(preferred_x, x_lo, x_hi)
	if not _slot_overlaps_any_in_list(Vector2(px, y), seg, existing, tile_w, plat_h, min_g, vg):
		return px
	var span: float = x_hi - x_lo
	var samples: int = clampi(int(ceil(span / 10.0)), 8, 32)
	for k in range(samples + 1):
		var t: float = float(k) / float(samples)
		var xa: float = lerpf(x_lo, x_hi, t)
		if not _slot_overlaps_any_in_list(Vector2(xa, y), seg, existing, tile_w, plat_h, min_g, vg):
			return xa
	for k in range(samples + 1):
		var t2: float = 1.0 - float(k) / float(samples)
		var xb: float = lerpf(x_lo, x_hi, t2)
		if not _slot_overlaps_any_in_list(Vector2(xb, y), seg, existing, tile_w, plat_h, min_g, vg):
			return xb
	return px

## Сдвигает уже выпеченные слоты, если AABB всё ещё пересекаются (после smooth_path).
func resolve_platform_overlaps(rules: Dictionary, bounds: Dictionary, tile_w: float, plat_h: float) -> void:
	var min_g: float = float(rules["min_edge_gap"])
	var vg: float = float(rules["vertical_gap"])
	var y_cut: float = plat_h + vg + 2.0
	var changed: bool = true
	var guard: int = 0
	while changed and guard < 12:
		guard += 1
		changed = false
		for i in range(1, platforms.size()):
			var slot_i: Dictionary = platforms[i]
			var xi: float = float(slot_i["x"])
			var yi: float = float(slot_i["y"])
			var segi: int = int(slot_i["segments"])
			var pos_i: Vector2 = Vector2(xi, yi)
			for j in range(i):
				var slot_j: Dictionary = platforms[j]
				if abs(yi - float(slot_j["y"])) > y_cut:
					continue
				var pos_j: Vector2 = Vector2(float(slot_j["x"]), float(slot_j["y"]))
				var segj: int = int(slot_j["segments"])
				if not _two_slots_overlap(pos_i, segi, pos_j, segj, tile_w, plat_h, min_g, vg):
					continue
				var hw_i: float = float(segi) * tile_w * 0.5
				var hw_j: float = float(segj) * tile_w * 0.5
				var need: float = hw_i + hw_j + min_g - abs(xi - float(slot_j["x"]))
				if need <= 0.001:
					continue
				var dir: float = 1.0 if xi >= float(slot_j["x"]) else -1.0
				var new_x: float = xi + dir * need
				var lim: Vector2 = _center_x_limits_for_segments(segi, tile_w, bounds)
				new_x = clampf(new_x, lim.x, lim.y)
				if abs(new_x - xi) > 0.05:
					platforms[i]["x"] = new_x
					xi = new_x
					pos_i.x = new_x
					changed = true

func _deterministic_vanish(salt: int, chance: float) -> bool:
	if chance <= 0.0:
		return false
	if chance >= 1.0:
		return true
	var p: int = int(round(clampf(chance, 0.0, 1.0) * 10000.0))
	var h: int = int(abs(salt)) * 1103515245 + 12345 + model_id * 17
	return (h % 10000) < p

## Строит platforms[] из steps + правил + оси min/max (bounds). Детерминированно, без RNG.
func bake_from_steps(
	rules: Dictionary,
	bounds: Dictionary,
	start_center: Vector2,
	start_segments: int,
	initial_direction: int,
	tile_w: float,
	plat_h: float
) -> void:
	platforms.clear()
	if steps.is_empty():
		return
	var direction: int = 1 if initial_direction >= 0 else -1
	var cursor: Vector2 = start_center
	var last_pos: Vector2 = start_center
	var last_seg: int = start_segments
	var mid_gap: float = (float(rules["min_gap"]) + float(rules["max_gap"])) * 0.5
	var hv: float = float(rules["height_variation"])
	var default_y_delta: float = -hv * 0.05
	var safe_mx: float = float(rules["safe_margin_x"])
	var vanish_ch: float = float(rules["vanish_chance"])
	var reach_frac: float = float(rules.get("jump_reach_max_fraction", 1.0))
	var min_g: float = float(rules["min_edge_gap"])
	var vg: float = float(rules["vertical_gap"])
	var world_w: float = float(bounds["max_x"]) - float(bounds["min_x"])
	var span_ratio: float = float(rules.get("path_min_horizontal_span_ratio", 0.88))
	var max_iter: int = int(rules.get("path_bake_max_iterations", 1400))
	var min_steps_span: int = int(rules.get("path_bake_min_steps_before_span_ok", 120))
	var max_slots: int = int(rules.get("path_bake_max_slots", 480))
	max_slots = maxi(max_slots, min_steps_span + 8)
	var target_span: float = world_w * clampf(span_ratio, 0.5, 1.0)

	var half_w0: float = float(last_seg) * tile_w * 0.5
	var min_edge_x: float = last_pos.x - half_w0
	var max_edge_x: float = last_pos.x + half_w0

	platforms.append({
		"x": last_pos.x,
		"y": last_pos.y,
		"segments": last_seg,
		"vanish": 1 if _deterministic_vanish(0, vanish_ch) else 0,
	})

	var step_index: int = 0
	var guard: int = 0
	while guard < max_iter:
		guard += 1
		var step: Dictionary = steps[step_index % steps.size()]
		if step_index > 0:
			var prev_step: Dictionary = steps[(step_index - 1) % steps.size()]
			if int(step.get("wave_id", 0)) != int(prev_step.get("wave_id", 0)):
				direction *= -1

		var x_gap: float = clampf(float(step.get("x_gap", mid_gap)), float(rules["min_gap"]), float(rules["max_gap"]))
		var y_delta: float = clampf(float(step.get("y_delta", default_y_delta)), -hv, hv)
		cursor.x += float(direction) * x_gap
		cursor.y += y_delta
		var half_h: float = plat_h * 0.5
		cursor.y = clampf(cursor.y, float(bounds["min_y"]) + half_h, float(bounds["max_y"]) - half_h)

		var seg: int = _segment_count_for_size_key(_size_key_for_step(step, step_index), rules, tile_w)
		cursor.x = _clamp_x_for_jump(last_pos, last_seg, cursor, seg, tile_w, plat_h, safe_mx, bounds, reach_frac)
		var x_bounds: Vector2 = _reachable_x_bounds(
			last_pos, last_seg, cursor.y, seg, tile_w, plat_h, safe_mx, bounds, reach_frac
		)
		cursor.x = _pick_x_clear_in_bounds(
			cursor.x, cursor.y, seg, platforms, x_bounds, tile_w, plat_h, min_g, vg
		)

		var vanish_i: int = 1 if _deterministic_vanish(step_index + 1 + model_id * 131, vanish_ch) else 0
		platforms.append({
			"x": cursor.x,
			"y": cursor.y,
			"segments": seg,
			"vanish": vanish_i,
		})
		var hw_n: float = float(seg) * tile_w * 0.5
		min_edge_x = minf(min_edge_x, cursor.x - hw_n)
		max_edge_x = maxf(max_edge_x, cursor.x + hw_n)
		last_pos = cursor
		last_seg = seg
		step_index += 1
		var span: float = max_edge_x - min_edge_x
		if step_index >= min_steps_span and span >= target_span:
			break
		if platforms.size() >= max_slots:
			break

	if max_edge_x - min_edge_x < target_span * 0.92:
		push_warning(
			"PathModel id=%d: horizontal span %.0f < target %.0f (world_w=%.0f, steps=%d, iters=%d)"
			% [model_id, max_edge_x - min_edge_x, target_span, world_w, step_index, guard]
		)

	smooth_path(plat_h * 0.25)
	resolve_platform_overlaps(rules, bounds, tile_w, plat_h)
	_log("[PATHMODEL] bake model_id=%d slots=%d" % [model_id, platforms.size()])

func _log(msg: String) -> void:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		var fl: Node = (ml as SceneTree).root.get_node_or_null("/root/FileLogger")
		if fl != null and fl.has_method("write_log"):
			fl.call("write_log", msg)
			return
	print(msg)

func smooth_path(min_dy_merge: float) -> void:
	if platforms.size() < 3:
		return
	var merged: Array = []
	merged.append(platforms[0])
	for i in range(1, platforms.size()):
		var prev: Dictionary = merged[merged.size() - 1]
		var cur: Dictionary = platforms[i]
		var dy: float = abs(float(cur["y"]) - float(prev["y"]))
		var dx: float = abs(float(cur["x"]) - float(prev["x"]))
		if dy < min_dy_merge and dx < float(prev.get("segments", 2)) * 32.0:
			continue
		merged.append(cur)
	if merged.size() >= 2:
		platforms = merged

func is_stair_pattern(stair_epsilon: float, min_same_run: int) -> bool:
	if platforms.size() < min_same_run + 1:
		return false
	var run: int = 1
	for i in range(1, platforms.size()):
		var dy: float = abs(float(platforms[i]["y"]) - float(platforms[i - 1]["y"]))
		if dy < stair_epsilon:
			run += 1
			if run >= min_same_run:
				return true
		else:
			run = 1
	return false

func detect_stairs(stair_epsilon: float, min_same_run: int) -> bool:
	return is_stair_pattern(stair_epsilon, min_same_run)

func validate_full(rules: Dictionary, bounds: Dictionary, tile_w: float, plat_h: float) -> bool:
	if platforms.is_empty():
		return false
	var reach_frac: float = clampf(float(rules.get("jump_reach_max_fraction", 1.0)), 0.05, 1.0)
	for i in range(platforms.size()):
		var slot: Dictionary = platforms[i]
		var pos: Vector2 = Vector2(float(slot["x"]), float(slot["y"]))
		var seg: int = int(slot["segments"])
		if not _slot_inside_bounds(pos, seg, tile_w, plat_h, bounds):
			return false
	var jump_pairs: Array = []
	if support_chain_indices.size() >= 2:
		for j in range(1, support_chain_indices.size()):
			jump_pairs.append([int(support_chain_indices[j - 1]), int(support_chain_indices[j])])
	else:
		for i in range(1, platforms.size()):
			jump_pairs.append([i - 1, i])
	for pair in jump_pairs:
		var i_prev: int = int(pair[0])
		var i_curr: int = int(pair[1])
		if i_prev < 0 or i_curr < 0 or i_prev >= platforms.size() or i_curr >= platforms.size():
			return false
		var prev: Dictionary = platforms[i_prev]
		var slot: Dictionary = platforms[i_curr]
		var p0: Vector2 = Vector2(float(prev["x"]), float(prev["y"]))
		var p1: Vector2 = Vector2(float(slot["x"]), float(slot["y"]))
		var s0: int = int(prev["segments"])
		var s1: int = int(slot["segments"])
		var surf0: float = p0.y - plat_h * 0.5
		var surf1: float = p1.y - plat_h * 0.5
		var reach: float = PhysicsConfig.horizontal_reach_surface_to_surface(surf1 - surf0) * reach_frac
		var half0: float = float(s0) * tile_w * 0.5
		var half1: float = float(s1) * tile_w * 0.5
		var edge_dx: float = abs(p1.x - p0.x) - half0 - half1
		if edge_dx > reach + float(rules["safe_margin_x"]):
			return false
	var min_g2: float = float(rules["min_edge_gap"])
	var vg2: float = float(rules["vertical_gap"])
	var y_band: float = plat_h + vg2 + 0.5
	for ia in range(platforms.size()):
		var sa: Dictionary = platforms[ia]
		var ya: float = float(sa["y"])
		for ib in range(ia + 1, platforms.size()):
			var sb: Dictionary = platforms[ib]
			if abs(ya - float(sb["y"])) > y_band:
				continue
			var pa: Vector2 = Vector2(float(sa["x"]), ya)
			var pb: Vector2 = Vector2(float(sb["x"]), float(sb["y"]))
			if _two_slots_overlap(pa, int(sa["segments"]), pb, int(sb["segments"]), tile_w, plat_h, min_g2, vg2):
				return false
	return true

func _slot_inside_bounds(pos: Vector2, seg: int, tile_w: float, plat_h: float, bounds: Dictionary) -> bool:
	var half_w: float = float(seg) * tile_w * 0.5
	var half_h: float = plat_h * 0.5
	if pos.x - half_w < float(bounds["min_x"]):
		return false
	if pos.x + half_w > float(bounds["max_x"]):
		return false
	if pos.y - half_h < float(bounds["min_y"]):
		return false
	if pos.y + half_h > float(bounds["max_y"]):
		return false
	return true

static func create_minimal_safe(start_center: Vector2, tile_w: float, plat_h: float, bounds: Dictionary) -> PathModel:
	var m: PathModel = PathModel.new()
	m.model_id = -1
	var y: float = start_center.y
	var x: float = start_center.x
	var hh: float = plat_h * 0.5
	for i in range(6):
		m.platforms.append({
			"x": x,
			"y": y,
			"segments": 2,
			"vanish": 0,
		})
		x += tile_w * 3.0
		y -= plat_h * 0.5
		y = clampf(y, float(bounds["min_y"]) + hh, float(bounds["max_y"]) - hh)
	return m
