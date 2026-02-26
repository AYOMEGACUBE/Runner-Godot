extends RefCounted
class_name PathModel

var model_id: int = 0
var trend_degrees: float = 2.0
var steps: Array[Dictionary] = []

func to_dict() -> Dictionary:
	return {
		"model_id": model_id,
		"trend_degrees": trend_degrees,
		"steps": steps,
	}

static func from_dict(data: Dictionary) -> PathModel:
	var m: PathModel = PathModel.new()
	m.model_id = int(data.get("model_id", 0))
	m.trend_degrees = float(data.get("trend_degrees", 2.0))
	var src_steps: Array = data.get("steps", [])
	for raw_step in src_steps:
		if typeof(raw_step) != TYPE_DICTIONARY:
			continue
		m.steps.append({
			"x_gap": float(raw_step.get("x_gap", 180.0)),
			"y_delta": float(raw_step.get("y_delta", -12.0)),
			"wave_id": int(raw_step.get("wave_id", 0)),
			"decoy_count": int(raw_step.get("decoy_count", 1)),
		})
	return m
