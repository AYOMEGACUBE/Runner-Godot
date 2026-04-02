extends RefCounted
class_name WorldSegmentGrid
## Единая сетка мега-куба / стены: совпадает с `wall.gd`, `WallRenderer`, `CubeMath.SEGMENTS_PER_SIDE`.
## Ось грани мега-куба: 3200×48 px. При `align_run_world_to_cube_face` раннер задаёт мир по X и по Y этой же величиной (квадрат грани).

const SEGMENT_SIZE_PX: int = 48
const SEGMENTS_PER_FACE_AXIS: int = 3200
const FACE_AXIS_PX: int = SEGMENTS_PER_FACE_AXIS * SEGMENT_SIZE_PX
