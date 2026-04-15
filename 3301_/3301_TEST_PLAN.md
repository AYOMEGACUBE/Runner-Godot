# 3301 TEST_PLAN

**Актуально:** 2026-04-15.

## Производительность стены / большие save

- Ручной регресс: старт с большим `user://wall_segments.json` (10k+ сегментов) — отсутствие длинного фриза первого кадра; логи `[PERF] json_parse_ms`, `[LOAD] … total_ms`. См. **`3301_WALL_RENDERING_AND_STREAMING.md`**.

## Уровни тестирования

- **Юнит/логика** (скрипты в `res://3301_/3301_test/`).
- **Smoke-тесты** (запуск сцен и ключевые UX-переходы).
- **Интеграционные sync-тесты** (merge и переходы статусов).

## Наличие автотестов в проекте

- `3301_/3301_test/platform_generation_tests.gd`
- `3301_/3301_test/path_model_tests.gd`
- `3301_/3301_test/determinism_run_tests.gd`
- `3301_/3301_test/test_economy.gd`
- `3301_/3301_test/platform_purchase_flow.gd`
- `3301_/3301_test/platform_purchase_tests.gd`
- `3301_/3301_test/purchase_sync_level_visibility_tests.gd`
- `3301_/3301_test/reachability_regression_suite.gd`
- `3301_/3301_test/segment_purchase_race_condition.gd`
- `3301_/3301_test/segment_purchase_tests.gd`
- `3301_/3301_test/sync_merge_tests.gd`
- `3301_/3301_test/wall_visible_area_tests.gd`
- `3301_/3301_test/camera_jitter_tests.gd`
 
Примечание: исторический каталог `tests/` удалён/устарел; актуальные автотесты живут в `res://3301_/3301_test/`.

## Headless / утилиты

- `debug_test_chunk_loader.gd` — запуск из CLI: `godot --path "<проект>" --headless -s res://debug_test_chunk_loader.gd` (проверка `ChunkRegistry` и смоук `LegBuilder`).
- `3301_smoke_suite.gd` — запуск из CLI: `godot --path "<проект>" --headless -s res://3301_/3301_test/3301_smoke_suite.gd` (smoke загрузки ключевых сцен).
- `smoke_boot_mainmenu.gd` — быстрый headless boot `MainMenu` (см. `res://3301_/3301_test/smoke_boot_mainmenu.gd`).

## Smoke-чеклист

1. Запустить `MainMenu.tscn`.
2. Начать забег и убедиться, что `level.tscn` загружается и платформы генерируются (при необходимости отдельно проверить сценарий с **`use_path_leg_streaming`** в инспекторе `Level`).
3. Проверить прыжок, движение камеры и обновление HUD.
4. Открыть `CubeView.tscn` и проверить:
   - выбор сегментов и покупку батчем;
   - выбор платформ на мини-карте и диалог покупки платформ.
5. Вернуться в меню и повторно открыть режимы, проверив сохранённое состояние.

## План sync e2e

1. Подготовить два клиента с одним RTDB-проектом и разными локальными `user://` состояниями.
2. Клиент A выполняет покупку и push ownership в RTDB.
3. Клиент B выполняет pull ownership и получает merged-состояние.
4. Создать преднамеренный конфликт ownership и проверить:
   - first-buyer policy сохраняет корректного победителя;
   - проигравшая запись получает `conflict`;
   - структура данных не повреждается и не содержит частичных батчей.

## Критерии приёмки

- Сцены запускаются без runtime-ошибок.
- Атомарные покупки не дают частичных применений.
- Статусы sync переходят корректно (`pending -> synced` либо `failed/conflict`).
- Merge-результат детерминирован при одинаковом порядке timestamp.

## Последний прогон (локально, headless)

- Полный набор `res://3301_/3301_test/*.gd` (кроме `tools_*`) прошёл без `SCRIPT ERROR` и без `[TEST] FAIL`.
