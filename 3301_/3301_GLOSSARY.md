# 3301 GLOSSARY

**Актуально:** 2026-04-15.

- **Corridor** — активная полоса (`min_x`, `max_x`, `min_y`, `max_y`) для размещения платформ; смещается вверх по мере подъёма игрока.
- **Path-step** — элемент `PathModel.steps[]`: `x_gap`, `y_delta`, `wave_id`, `decoy_count`, опционально **`size`**: `small` | `medium` | `large`.
- **Path slot** — элемент `PathModel.platforms[]` после bake: центр `x`, `y`, `segments`, `vanish`.
- **Chunk (JSON)** — файл или объект в `DATA/PulseRunnerData/chunks/*.json`: обычно `model_id`, `platforms[]`, `support_chain_indices`, опционально `steps[]` (часто пустой); загружается `ChunkRegistry` для режима **PathManager**.
- **Leg (колено)** — участок уровня, собранный из нескольких чанков подряд в **PathManager**; смена колена по прогрессу игрока по X и handoff.
- **Z-trajectory / зигзаг** — смена направления по X при смене `wave_id` между шагами в bake.
- **Fallback** — при неудаче `validate_full` после smooth: снимок модели или `PathModel.create_minimal_safe`.
- **Segment** — ячейка стены, `segment_id = "x_y"`.
- **Face** — грань сегмента (`front` / `back` / …) с ownership и контентом.
- **Brand / Side** — бренд и сторона мегакуба; материал через `SideManager` / `BrandMaterialLibrary`.
- **Sync** — синхронизация кошелька/ownership через primary канал (**Firebase RTDB**: `EconomyRemoteSync` + `OwnershipRemoteSync`).
- **Purchase flow** — последовательность в `CubeView` (см. `3301_PURCHASE_FLOW.md`); списание/валидация часто через autoload **`PurchaseManager`**.
- **PathModel** — модель траектории (шаги + метаданные + опционально готовые `platforms[]`).
- **PathLibrary** — массив моделей: файл `path_library_50.json` или детерминированная генерация.
- **PathSelector** — выбор активной модели на забег (режим без стриминга).
- **ChunkRegistry** — сканирование папки чанков, индекс `model_id` → шаблон словаря.
- **LegBuilder** — сборка колена из чанков (стыки, зеркало по X, валидация прыжка между чанками).
- **PathManager** — узел-сцена: стриминг колен, `DifficultyScaler`, вызов `PlatformSpawner`.
- **PlatformSpawner** — инстанс `Platform.tscn` по слотам из словарей чанков.
- **use_path_leg_streaming** — экспорт в `Level.gd`: включает **PathManager** вместо пула + PathLibrary на этом забеге.
- **FileLogger** — autoload-узел для записи лога (`FileLogger.log`); не путать с нативным классом Godot `Logger`.
- **WallData** — данные сегментов стены; асинхронная загрузка `user://wall_segments.json` (см. `3301_WALL_RENDERING_AND_STREAMING.md`).
- **WallRenderer** — рендер стены: MultiMesh + Sprite2D; поток для `Image.load`/resize; кэш текстур с LRU и лимитом памяти.
- **Wall texture stream** — очереди main↔thread, приоритет по дистанции до камеры, backpressure `MAX_ACTIVE_LOADING`.
- **PlatformDataStore** — данные покупок платформ.
- **Atomic write** — батч изменений «всё или ничьё».
- **First-buyer policy** — при конфликте приоритет более раннего `purchase_timestamp`.
- **Sync status** — `pending`, `synced`, `conflict`, `failed` (и др. по коду).
