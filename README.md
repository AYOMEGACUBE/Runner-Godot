# EndlessRunnerAYO (Pulse Runner / BLACKOUT 3301)

Вертикальный **endless runner** на **Godot 4.5** (Forward Plus): забег вверх по платформам, фоновая **стена-мегакуб**, мета-игра (чемпионы, профиль), покупка **сегментов стены** и **платформ**, синхронизация через **git-транспорт** (`BlackoutSync`). Концептуальная спецификация: **`3301_концептуально-архитектурное ТЗ.txt`**.

## Быстрый старт

- Открыть проект в Godot 4.5+, главная сцена задаётся в `project.godot` (`MainMenu`).
- Правила платформ и мира: `DATA/PulseRunnerData/rules/platform_rules.json`.
- Библиотека путей (опционально): `DATA/PulseRunnerData/path_library_50.json` — если файла нет или в нём не 50 моделей, `PathLibrary` собирает детерминированный набор по встроенному seed.

## Документация (индекс)

| Файл | Содержание |
|------|------------|
| `3301_PROJECT_STATE.md` | Актуальное состояние кода и конфигурации (AS-IS) |
| `3301_PULSE_RUNNER_ARCHITECTURE.md` | Архитектура подсистем |
| `3301_GLOSSARY.md` | Термины |
| `3301_PATHMODEL_LIBRARY.md` | PathModel / PathLibrary / PathSelector / bake |
| `3301_DATA_MODELS.md` | Модели данных (стена, платформы, PathModel, GameState) |
| `3301_SYNC_PROTOCOL.md` | Синхронизация покупок |
| `3301_PURCHASE_FLOW.md` | UX-потоки покупок в CubeView |
| `3301_SCENE_TREE.md` | Дерево основных сцен |
| `3301_TEST_PLAN.md` | Тесты и smoke-чеклист |
| `3301_TODO_LIST.md` | Открытые задачи |
| `3301_RISKS_AND_LIMITATIONS.md` | Риски, ограничения, заметки аудита |
| `DATA/PulseRunnerData/paths/DEEPSEEK_ASSIGNMENT_PATH_LIBRARY.txt` | Шаблон задания на генерацию JSON библиотеки путей |
| `3301_концептуально-архитектурное ТЗ.txt` | Исходное ТЗ 3301 |

## Autoload (`project.godot`)

| Имя | Скрипт |
|-----|--------|
| `GameState` | `GameState.gd` |
| `FileLogger` | `scripts/Logger.gd` (лог в `res://3301_LOG.txt` при запуске из редактора, иначе fallback `user://`) |
| `SideManager` | `scripts/branding/SideManager.gd` |
| `SeedManager` | `scripts/seed/SeedManager.gd` |
| `DataManager` | `scripts/DataManager.gd` |

`BlackoutSync` — **не** singleton; используется из `CubeView` и связанных потоков как класс/инстанс.

## Ключевые сцены

- `MainMenu.tscn` — вход, переход в забег / CubeView / профиль / чемпионы.
- `level.tscn` — `Level.gd`, пул платформ, `PathModel` bake, игрок, стена, HUD.
- `GameOver.tscn` — итог забега.
- `CubeView.tscn` — мегакуб, покупки, sync.

## Игровое ядро (кратко)

- **Физика и прыжок:** `scripts/config/PhysicsConfig.gd` (единый источник для Player и валидации пути).
- **Путь:** `PathSelector` выбирает модель (RNG-поток `"path"` от `SeedManager`), `PathModel.bake_from_steps` строит слоты платформ с учётом `platform_rules.json` (досягаемость, span по ширине мира, overlap, лимиты слотов).
- **Стена:** `wall/wall.gd`, `WallRenderer.gd`, данные `WallData.gd` → `user://wall_segments.json`.

## Данные PulseRunnerData

- Ресурс: `res://DATA/PulseRunnerData/…`
- Рантайм-копии: `user://DATA/PulseRunnerData/…`
- Remote-источник конфигурируется в `DataManager.gd` (GitHub `PulseRunnerData`).

---

*Обновление документации: 2026-04-02.*
