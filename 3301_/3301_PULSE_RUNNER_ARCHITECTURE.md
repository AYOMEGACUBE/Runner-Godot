# 3301 Архитектура Pulse Runner

**Актуально:** 2026-04-15 · Godot 4.5 (Forward Plus)

## Назначение

Верхнеуровневые подсистемы и границы ответственности. Детальный снимок репозитория — **`3301_PROJECT_STATE.md`**. Термины — **`3301_GLOSSARY.md`**.

## Поток выполнения

1. **`MainMenu.tscn`** — вход, выбор забега / CubeView / профиль / чемпионы.
2. **`level.tscn`** — игровой цикл: `Level`, `Player`, стена (`wall.tscn`), HUD; платформы либо из **PathLibrary** (пул), либо из **PathManager** (чанки), в зависимости от флага `use_path_leg_streaming`.
3. **`GameOver.tscn`** — итог забега, данные из `GameState`.
4. **`CubeView.tscn`** — мегакуб: выбор, покупки сегментов/платформ, вызовы sync; интеграция с **`PurchaseManager`** (autoload).

## Подсистемы

### Игровое ядро

- **`scripts/Level.gd`** — правила из `DataManager`, фиксированный `world_bounds`, спавн платформ:
  - **по умолчанию:** `PathSelector`, `PathModel` (bake или prebaked `platforms[]`), `PlatformPool`, очистка ниже игрока;
  - **стриминг:** делегирование **`PathManager`** (`PathLegStream`), пул и основной layout-путь отключены на этом забеге.
- **`scripts/Player.gd`** — движение, прыжок, смерть, регистрация забега.
- **`scripts/Platform.gd`** — размер, crumble, сигнал жизненного цикла; опциональный лог `_ready`.

### PathModel runtime (режим библиотеки)

- **`scripts/path/PathLibrary.gd`** — JSON `path_library_50.json` или детерминированная сборка 50 моделей.
- **`scripts/path/PathSelector.gd`** — выбор модели на забег (`SeedManager`, поток `"path"`), направление по X.
- **`scripts/path/PathModel.gd`** — сериализация, bake, валидация прыжка, span по ширине мира, анти-overlap.

### Стриминг чанков (опциональный режим)

- **`scripts/managers/PathManager.gd`** — колена, прогресс игрока, предзагрузка следующего колена, сигналы `leg_*`, `wall_top_reached`.
- **`scripts/path/ChunkRegistry.gd`** — `DirAccess` + `FileAccess` + `JSON.parse_string` по `res://DATA/PulseRunnerData/chunks/`.
- **`scripts/path/LegBuilder.gd`** — геометрия стыков чанков, валидация прыжка между чанками.
- **`scripts/path/PlatformSpawner.gd`** — инстанс `Platform.tscn` по слотам.
- **`scripts/path/DifficultyScaler.gd`** — crumble-вероятность по высоте, правила по `support_chain_indices`.
- **`scripts/managers/GameManager.gd`** — пример подключения сигналов PathManager (в типовой `level.tscn` может отсутствовать).

### Физика

- **`scripts/config/PhysicsConfig.gd`** — GRAVITY, JUMP_VELOCITY, MOVE_SPEED; досягаемость прыжка для Player и PathModel / LegBuilder (порядок величин: горизонталь ~336 px, высота ~230 px).

### Стена

- **`wall/wall.gd`** — видимая область, расписание обновлений, связь с камерой и диском.
- **`wall/WallRenderer.gd`** — `MultiMeshInstance2D` + `Sprite2D`; загрузка текстур в **отдельном потоке** (Image/resize), применение в main; приоритетные очереди, лимиты кадра, LRU и MB-cap кэша. См. **`3301_WALL_RENDERING_AND_STREAMING.md`**.
- **`wall/data/WallData.gd`** — `user://wall_segments.json`; покупки граней, merge; **асинхронная** загрузка большого JSON чанками (`load_state` / `load_completed`).

### Покупки и UX

- **`CubeView.gd`** — оркестрация выбора, диалогов, покупок, sync.
- **`CubeViewPurchaseService.gd`** — вынесенная orchestration-логика bulk-покупки сегментов (tx-результат + применение визуалов).
- **`scripts/purchase/PurchaseManager.gd`** (autoload) — списание монет, коммиты покупок стены/платформ, сигналы для UI.
- Диалоги: `BulkPurchaseDialog`, `PlatformPurchaseDialog`, и др.
- **`scripts/platform/PlatformDataStore.gd`** — `user://platforms.json`.

### Синхронизация

- **RTDB sync:** ownership и кошелёк синхронизируются через `OwnershipRemoteSync` / `EconomyRemoteSync` (autoload) и `GameState`.

### Брендинг

- **`scripts/branding/BrandConfig.gd`**, **`SideManager.gd`**, **`BrandMaterialLibrary.gd`** — сторона мегакуба → material key / визуал.

### Данные

- **`scripts/DataManager.gd`** autoload — загрузка PulseRunnerData (rules, paths, …) с `res://` и `user://`.

### Отладка

- **`scripts/debug/RunDebugOverlay.gd`** — опционально из `Level` (`show_run_debug_overlay`).
- **`debug_test_chunk_loader.gd`** — headless-проверка `ChunkRegistry` (не сцена).

## Autoload (факт из `project.godot`)

- `GameState`, `FileLogger`, `SideManager`, `SeedManager`, `DataManager`, `EconomyManager`, `SegmentManager`, `UIManager`, `PurchaseManager`.

## Принципы

- Генерация платформ **data-driven**: библиотека PathModel + `platform_rules.json`, bake с валидацией; **либо** стриминг из JSON-чанков при явном флаге уровня.
- Стена ограничивает нагрузку видимой областью, инкрементальными обновлениями спрайтов и стримингом загрузки текстур/JSON (см. **`3301_WALL_RENDERING_AND_STREAMING.md`**).
- Покупки — атомарная запись локальных моделей до/после sync (см. `3301_PURCHASE_FLOW.md`).
- Merge sync — first-buyer по timestamp (см. `3301_SYNC_PROTOCOL.md`).
