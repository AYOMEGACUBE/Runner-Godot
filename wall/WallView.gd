extends Node2D
class_name WallView

@export var segment_scene: PackedScene = preload("res://wall/segment/WallSegment.tscn")
@export var segment_size: float = 48.0
@export var visible_cols: int = 8
@export var visible_rows: int = 6
@export var side_id: String = "front"

var wall_data: WallData = null
var origin_col: int = 0
var origin_row: int = 0

var _segments: Array[WallSegment] = []
var _cell_x: PackedInt32Array = PackedInt32Array()
var _cell_y: PackedInt32Array = PackedInt32Array()

func setup(data: WallData) -> void:
	wall_data = data
	_create_pool()
	_update_all_segments()

func set_origin(col: int, row: int) -> void:
	origin_col = col
	origin_row = row
	_update_all_segments()

func move_origin(delta_col: int, delta_row: int) -> void:
	origin_col += delta_col
	origin_row += delta_row
	_update_all_segments()

func handle_click_global(global_pos: Vector2, owner_id: int) -> void:
	if wall_data == null:
		return
	if owner_id == 0:
		return
	if _segments.is_empty():
		return
	var local: Vector2 = to_local(global_pos)
	if local.x < 0.0 or local.y < 0.0:
		return
	var col: int = int(floor(local.x / segment_size))
	var row: int = int(floor(local.y / segment_size))
	if col < 0 or col >= visible_cols or row < 0 or row >= visible_rows:
		return
	var world_x: int = origin_col + col
	var world_y: int = origin_row + row
	var ok: bool = wall_data.buy_cell(side_id, world_x, world_y, owner_id)
	if not ok:
		return
	var count: int = _segments.size()
	for i in count:
		if i >= _cell_x.size() or i >= _cell_y.size():
			break
		if _cell_x[i] == world_x and _cell_y[i] == world_y:
			var seg: WallSegment = _segments[i]
			if seg != null:
				seg.apply_state(world_x, world_y)
			break

func _create_pool() -> void:
	if wall_data == null:
		return
	if segment_scene == null:
		return
	if not _segments.is_empty():
		return
	var count: int = visible_cols * visible_rows
	_segments.clear()
	_segments.resize(count)
	_cell_x = PackedInt32Array()
	_cell_x.resize(count)
	_cell_y = PackedInt32Array()
	_cell_y.resize(count)
	var idx: int = 0
	for _row in visible_rows:
		for _col in visible_cols:
			var inst := segment_scene.instantiate()
			var seg: WallSegment = inst as WallSegment
			if seg == null:
				continue
			add_child(seg)
			seg.position = Vector2.ZERO
			seg.setup(side_id, wall_data)
			_segments[idx] = seg
			_cell_x[idx] = 0
			_cell_y[idx] = 0
			idx += 1

func _update_all_segments() -> void:
	if wall_data == null:
		return
	if _segments.is_empty():
		return
	var idx: int = 0
	var total: int = _segments.size()
	for row in visible_rows:
		for col in visible_cols:
			if idx >= total:
				return
			var seg: WallSegment = _segments[idx]
			if seg == null:
				idx += 1
				continue
			var world_x: int = origin_col + col
			var world_y: int = origin_row + row
			_cell_x[idx] = world_x
			_cell_y[idx] = world_y
			var local_pos := Vector2(
				float(col) * segment_size + segment_size * 0.5,
				float(row) * segment_size + segment_size * 0.5
			)
			seg.position = local_pos
			seg.apply_state(world_x, world_y)
			idx += 1

