extends RefCounted
class_name PhysicsConfig

## Единый источник физики прыжка (Player, PathModel, тесты). PathModel не дублирует формулы.
## При GRAVITY/JUMP_VELOCITY/MOVE_SPEED ниже: макс. высота прыжка ≈230 px, макс. горизонталь ≈336 px (см. calculate_jump_metrics).

const GRAVITY: float = 2000.0
const JUMP_VELOCITY: float = -960.0
const MOVE_SPEED: float = 350.0

static var max_jump_height: float = 0.0
static var max_jump_distance: float = 0.0

static func calculate_jump_metrics() -> void:
	var g: float = GRAVITY
	var vj: float = JUMP_VELOCITY
	var vx: float = MOVE_SPEED
	if abs(g) < 0.0001:
		max_jump_height = 0.0
		max_jump_distance = 0.0
		return
	var t_up: float = -vj / g
	max_jump_height = (vj * vj) / (2.0 * g)
	var t_flight: float = 2.0 * t_up
	max_jump_distance = abs(vx) * t_flight

## Горизонтальная досягаемость между двумя линиями «поверхности» (Y поверхности платформы).
static func horizontal_reach_surface_to_surface(delta_surface_y: float) -> float:
	var disc: float = JUMP_VELOCITY * JUMP_VELOCITY + 2.0 * GRAVITY * delta_surface_y
	if disc < 0.0:
		return 0.0
	var t: float = (-JUMP_VELOCITY + sqrt(disc)) / GRAVITY
	return abs(MOVE_SPEED) * t
