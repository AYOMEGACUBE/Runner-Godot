# EndlessRunnerAYO (Pulse Runner / BLACKOUT 3301)

Вертикальный **endless runner** на **Godot 4.5** (Forward Plus): забег вверх по платформам, фоновая **стена-мегакуб**, мета-игра (чемпионы, профиль), покупка **сегментов стены** и **платформ**, синхронизация ownership/кошелька через **Firebase RTDB** (`EconomyRemoteSync` + `OwnershipRemoteSync`). Концептуальная спецификация: **`3301_концептуально-архитектурное ТЗ.txt`**.

## Быстрый старт

- Открыть проект в Godot 4.5+, главная сцена задаётся в `project.godot` (`MainMenu`).
- Правила платформ и мира: `DATA/PulseRunnerData/rules/platform_rules.json`.
- Библиотека путей (режим по умолчанию на уровне): `DATA/PulseRunnerData/path_library_50.json` — если файла нет или в нём не 50 моделей, `PathLibrary` собирает детерминированный набор по встроенному seed.
- **Чанки для стриминга** (отдельный режим): `DATA/PulseRunnerData/chunks/*.json` — используются только при **`Level.use_path_leg_streaming == true`** и узле **`PathManager`** (`PathLegStream` в `level.tscn`). См. `3301_PROJECT_STATE.md`, `3301_SCENE_TREE.md`.

## Документация (индекс)

Вся техническая документация лежит **только в** `res://3301_/` и именуется с префиксом **`3301_`**. Краткий локальный вход — **`3301_ROOT_README.md`**.

| Файл | Содержание |
|------|------------|
| `3301_README.md` | Этот файл — индекс и быстрый старт |
| `3301_PROJECT_STATE.md` | Актуальное состояние кода и конфигурации (AS-IS) |
| `3301_PULSE_RUNNER_ARCHITECTURE.md` | Архитектура подсистем |
| `3301_GLOSSARY.md` | Термины |
| `3301_PATHMODEL_LIBRARY.md` | PathModel / PathLibrary / PathSelector / bake; стриминг чанков |
| `3301_DATA_MODELS.md` | Модели данных (стена, платформы, PathModel, чанки, GameState) |
| `3301_WALL_RENDERING_AND_STREAMING.md` | Стена: async JSON (`WallData`), thread-текстуры, кэш, лимиты (`WallRenderer`) |
| `3301_SYNC_PROTOCOL.md` | Синхронизация покупок |
| `3301_PURCHASE_FLOW.md` | UX-потоки покупок в CubeView |
| `3301_SCENE_TREE.md` | Дерево основных сцен |
| `3301_TEST_PLAN.md` | Тесты и smoke-чеклист |
| `3301_TODO_LIST.md` | Открытые задачи |
| `3301_RELEASE_TRUTH_BASELINE.md` | Релизный baseline: scope lock, truth matrix, go/no-go |
| `3301_RELEASE_CHECKLIST.md` | Финальный QA checklist для final_release |
| `3301_TECH_AUDIT_MVP_PLAN.md` | One-pass техаудит, приоритеты и поэтапный MVP roadmap |
| `3301_RISKS_AND_LIMITATIONS.md` | Риски, ограничения, заметки аудита |
| `3301_REVENUE_CALCULATION.md` | Расчёты экономики (если используется) |
| `3301_PLATFORM_LAYOUT_SPEC_FOR_LLM.txt` | Нейтральное ТЗ для ИИ: карта платформ и встраивание в `path_library_50.json` / чанки |
| `3301_ADDON_ANDROID_GOOGLE_SIGNIN.md` | Заготовка Android Google Sign-In / Firebase id_token (аддон `addons/android_google_signin`) |
| `3301_концептуально-архитектурное ТЗ.txt` | Исходное ТЗ 3301 |
| `3301_rules_ai_workspace_policy.mdc` | Правила ассистента: корень-only, префиксы, запрет на удаление без явной команды |
| `3301_rules_godot_cli_path.mdc` | Правило: полный путь к Godot CLI (Windows) |

### Правила Cursor для ассистента

- Расположение: **только** `res://3301_/` (папка `3301_` рядом с `project.godot`), см. **`3301_rules_ai_workspace_policy.mdc`**.
- Именование файлов правил: префикс **`3301_rules_`** (например `3301_rules_godot_cli_path.mdc`).
- Политика: техдоки **`3301_*`** и правила **`3301_rules_*.mdc`** не хранятся в подпапках; подробности и про Cursor — в **`3301_rules_ai_workspace_policy.mdc`**.

## Autoload (`project.godot`)

| Имя | Скрипт |
|-----|--------|
| `GameState` | `GameState.gd` |
| `AuthService` | `scripts/auth/AuthService.gd` |
| `FileLogger` | `scripts/Logger.gd` (лог в `res://3301_/3301_LOG.txt` при запуске из редактора, иначе fallback `user://`) |
| `SideManager` | `scripts/branding/SideManager.gd` |
| `SeedManager` | `scripts/seed/SeedManager.gd` |
| `DataManager` | `scripts/DataManager.gd` |
| `EconomyManager` | `autoload/EconomyManager.gd` |
| `SegmentManager` | `managers/SegmentManager.gd` |
| `UIManager` | `managers/UIManager.gd` |
| `PurchaseManager` | `scripts/purchase/PurchaseManager.gd` |
| `EconomyRemoteSync` | `scripts/sync/EconomyRemoteSync.gd` |
| `OwnershipRemoteSync` | `scripts/sync/OwnershipRemoteSync.gd` |

## Ключевые сцены

- `res://scenes/main_menu/MainMenu.tscn` — вход, переход в забег / CubeView / профиль / чемпионы.
- `res://scenes/level/Level.tscn` — `scripts/scenes/level/Level.gd`, стриминг через `PathLegStream` (`PathManager`), игрок, стена, HUD.
- `res://scenes/game_over/GameOver.tscn` — итог забега.
- `res://scenes/cube_view/CubeView.tscn` — мегакуб, покупки, sync; подписки на сигналы **`PurchaseManager`**.

## Игровое ядро (кратко)

- **Физика и прыжок:** `scripts/config/PhysicsConfig.gd` (единый источник для Player и валидации пути).
- **Путь (по умолчанию):** `PathSelector` выбирает модель (RNG-поток `"path"` от `SeedManager`), `PathModel.bake_from_steps` строит слоты платформ с учётом `platform_rules.json` (досягаемость, span по ширине мира, overlap, лимиты слотов).
- **Путь (стриминг):** `PathManager` + `ChunkRegistry` + `LegBuilder` + `PlatformSpawner`; RNG-поток `"path_legs"`.
- **Стена:** `wall/wall.gd`, `WallRenderer.gd` (MultiMesh + Sprite2D, поток загрузки текстур, LRU/MB cap), `WallData.gd` → `user://wall_segments.json` (асинхронная загрузка чанками). Подробно: **`3301_WALL_RENDERING_AND_STREAMING.md`**.

## Данные PulseRunnerData

- Эталонные чанки пути (`model_id` 0–5 и др.): `DATA/PulseRunnerData/chunks/ideal_chunk_model_*.json` — исходники для правок и для режима **PathManager**.
- В обычном забеге без стриминга используется **`path_library_50.json`** (синхронизируйте запись модели вручную при изменении только файла чанка, если нужен тот же контент в библиотеке).
- Ресурс: `res://DATA/PulseRunnerData/…`
- Рантайм-копии: `user://DATA/PulseRunnerData/…`
- Remote-источник конфигурируется в `DataManager.gd` (GitHub `PulseRunnerData`).

## Firebase

- URL Realtime Database, регион и заметки по Rules — в **`3301_PROJECT_STATE.md`** (раздел «Firebase (Realtime Database)»).

## Отладка чанков

- `debug_test_chunk_loader.gd` — headless-проверка `ChunkRegistry` (см. комментарий в файле).

---

*Обновление документации: 2026-04-15.*
