class_name CubeMath
extends RefCounted
## Математика мега-куба: нормали, UV на грани, сетка 2D → (u,v). Godot 4.x

const WorldSegmentGrid = preload("res://scripts/config/WorldSegmentGrid.gd")
const SEGMENTS_PER_SIDE: int = WorldSegmentGrid.SEGMENTS_PER_FACE_AXIS
const CELLS_PER_FACE: int = SEGMENTS_PER_SIDE * SEGMENTS_PER_SIDE


static func grid_xy_to_uv(seg_x: int, seg_y: int) -> Vector2i:
	var half: int = SEGMENTS_PER_SIDE / 2
	var u: int = clampi(seg_x + half, 0, SEGMENTS_PER_SIDE - 1)
	var v: int = clampi(seg_y + half, 0, SEGMENTS_PER_SIDE - 1)
	return Vector2i(u, v)


static func calculate_segment_id(face_global: int, u: int, v: int) -> int:
	return face_global * CELLS_PER_FACE + u * SEGMENTS_PER_SIDE + v


static func calculate_face_id(face_global: int, u: int, v: int, side_external: int) -> int:
	var seg_id: int = calculate_segment_id(face_global, u, v)
	var side_internal: int = clampi(side_external - 1, 0, 5)
	return (seg_id << 3) | side_internal


static func normal_to_face_global(n: Vector3) -> int:
	var a: Vector3 = n.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0 if n.x > 0.0 else 1
	if a.y >= a.z:
		return 2 if n.y > 0.0 else 3
	return 4 if n.z > 0.0 else 5


static func point_on_cube_face_to_uv01(p: Vector3, face_global: int) -> Vector2:
	var x: float = p.x
	var y: float = p.y
	var z: float = p.z
	match face_global:
		0:
			return Vector2(-z + 0.5, y + 0.5)
		1:
			return Vector2(z + 0.5, y + 0.5)
		2:
			return Vector2(x + 0.5, -z + 0.5)
		3:
			return Vector2(x + 0.5, z + 0.5)
		4:
			return Vector2(x + 0.5, y + 0.5)
		5:
			return Vector2(-x + 0.5, y + 0.5)
		_:
			return Vector2.ZERO


static func uv01_to_cell_indices(uv01: Vector2) -> Vector2i:
	var gx: int = clampi(int(floor(uv01.x * float(SEGMENTS_PER_SIDE))), 0, SEGMENTS_PER_SIDE - 1)
	var gy: int = clampi(int(floor(uv01.y * float(SEGMENTS_PER_SIDE))), 0, SEGMENTS_PER_SIDE - 1)
	return Vector2i(gx, gy)


static func hit_to_face_and_uv_cells(hit_point: Vector3, hit_normal: Vector3) -> Dictionary:
	var fg: int = normal_to_face_global(hit_normal.normalized())
	var uv01: Vector2 = point_on_cube_face_to_uv01(hit_point, fg)
	uv01.x = clampf(uv01.x, 0.0, 1.0)
	uv01.y = clampf(uv01.y, 0.0, 1.0)
	var cell: Vector2i = uv01_to_cell_indices(uv01)
	return {"face_global": fg, "u": cell.x, "v": cell.y}
