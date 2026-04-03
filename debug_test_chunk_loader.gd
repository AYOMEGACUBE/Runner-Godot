# debug_test_chunk_loader.gd
# Минимальная проверка ChunkRegistry + смоук LegBuilder (без сцены).
# Запуск из корня проекта (подставьте путь к Godot 4.5):
#   godot --path "D:/YandexDisk/Projects/Runner/Godot" --headless -s res://debug_test_chunk_loader.gd
extends SceneTree

func _init() -> void:
	_run()
	quit(0)


func _run() -> void:
	print("=== debug_test_chunk_loader: ChunkRegistry ===")
	var cr: ChunkRegistry = ChunkRegistry.new()
	cr.debug_load = true
	cr.reload()
	var n: int = cr.size()
	# В API нет get_available_chunks(); эквивалент — size() и get_sorted_model_ids().
	print("Доступно моделей (чанков): %d" % n)
	print("model_ids: %s" % str(cr.get_sorted_model_ids()))
	if n == 0:
		push_warning("ChunkRegistry пуст после reload — проверьте res://DATA/PulseRunnerData/chunks/, JSON, поля platforms/model_id.")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var scaler := DifficultyScaler.new()
	var lb := LegBuilder.new(cr, scaler)
	lb.jump_reach_fraction = 0.8
	lb.safe_margin_x = 32.0
	lb.trace_chunk_selection = false
	var built: Array = lb.build_leg(Vector2(200.0, 800.0), 1, 3, rng)
	print("Смоук LegBuilder (3 чанка, dir=+1): словарей в колене = %d" % built.size())
