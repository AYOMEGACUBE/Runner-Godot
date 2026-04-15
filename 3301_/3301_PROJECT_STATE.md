# 3301 PROJECT STATE (AS-IS)

**Актуально:** 2026-04-15. Только факты текущего репозитория; планы — в `3301_TODO_LIST.md`. Детали стены (потоки, JSON, кэш): **`3301_WALL_RENDERING_AND_STREAMING.md`**.

## Документация

- Вся техническая документация и правила ассистента — **только в** `res://3301_/` с префиксом **`3301_`** (правила: `3301_rules_*.mdc`); индекс — **`3301_README.md`**.

## Конфигурация

- **Движок:** Godot 4.5, `Forward Plus` (`project.godot` → `config/features`).
- **Имя проекта:** `EndlessRunnerAYO`.
- **Главная сцена:** `res://scenes/main_menu/MainMenu.tscn` (через UID в `project.godot`).
- **2D:** `rendering/2d/snap/snap_2d_transforms_to_pixel=true`.
- **Растяжение окна:** `canvas_items`, aspect `expand`.
- **Временные pre-release настройки (`project.godot`):**
  - `[3301_temp_pre_release] wallet_boost_enabled=true`
  - `[3301_temp_pre_release] wallet_boost_amount=1000000`
  - Используются только для ручного QA покупок до релиза.

## Autoload

| Узел | Путь скрипта |
|------|----------------|
| `GameState` | `res://GameState.gd` |
| `AuthService` | `res://scripts/auth/AuthService.gd` |
| `FileLogger` | `res://scripts/Logger.gd` |
| `SideManager` | `res://scripts/branding/SideManager.gd` |
| `SeedManager` | `res://scripts/seed/SeedManager.gd` |
| `DataManager` | `res://scripts/DataManager.gd` |
| `EconomyManager` | `res://autoload/EconomyManager.gd` |
| `SegmentManager` | `res://managers/SegmentManager.gd` |
| `UIManager` | `res://managers/UIManager.gd` |
| `PurchaseManager` | `res://scripts/purchase/PurchaseManager.gd` |
| `EconomyRemoteSync` | `res://scripts/sync/EconomyRemoteSync.gd` |
| `OwnershipRemoteSync` | `res://scripts/sync/OwnershipRemoteSync.gd` |

Имя **`Logger`** в коде Godot зарезервировано нативным классом; глобальный логгер проекта — **`FileLogger`**. Вызовы: `FileLogger.log(...)`, узлы вроде HUD используют `get_node_or_null("/root/FileLogger")` при необходимости.

Основной runtime sync — RTDB (`EconomyRemoteSync` + `OwnershipRemoteSync`).

## Известные расхождения (код vs старые контракты)

- Контракты `WallData` и purchase-потока приведены к API с атомарным батчем (`buy_sides_atomic`) и merge-сериализацией (`to_dict`/`merge_from_dict`).
- Google Auth через REST сохраняет `email` и (если доступно) `displayName` в `GameState.auth_display_name`. UI-строка статуса предпочитает `displayName`, иначе показывает `email`. Игровое имя (persisted `nickname`) пока не привязано автоматически к `displayName` без отдельной миграции профиля.
- В `CubeView` кнопка покупки сегментов переименована в «Купить сторону сегмента».
- `OwnershipRemoteSync` эмитит event-driven сигнал `ownership_updated` после push/pull merge; UI может обновляться без polling ownership.
- `PurchaseManager.buy_platforms(...)` поддерживает `platform_size`, `height_level (1..7)`, `jump_image_up/down` metadata и детерминированные slot-id (`h<level>_slot_<n>`).
- `PlatformPurchaseDialog` поддерживает: тип/размер/высоту 1..7, основное+доп. изображение, preview и индикатор доступности/очереди.
- Экономика платформ по дням (новый базовый контракт): `small` L1=100 coin/день, `medium` L1=200, `large` L1=300; каждый следующий `height_level` добавляет +100 coin/день (до L7).
- `CubeView` показывает явный статус sync (`idle/pending/synced/conflict/failed`) и конфликты ownership после merge.
- `BulkPurchaseDialog` поддерживает явный выбор стороны сегмента (`front/back/left/right/top/bottom`) перед подтверждением покупки.

## Сцены рантайма

- **Основные:** `res://scenes/main_menu/MainMenu.tscn`, `res://scenes/level/Level.tscn`, `res://scenes/cube_view/CubeView.tscn`, `res://scenes/game_over/GameOver.tscn`.
- **Дополнительно:** `res://scenes/profile/Profile.tscn`, `res://scenes/champions/Champions.tscn`, `res://scenes/loading/LoadingLevel.tscn` (ассет присутствует, в основном пользовательском маршруте не используется).
- **Диалоги:** `res://scenes/dialogs/*.tscn` (`BulkPurchaseDialog`, `BulkImageUploadDialog`, `PlatformPurchaseDialog`, `PurchaseDialog`, `PurchaseModeDialog`).

## Уровень (`scripts/scenes/level/Level.gd`)

### Режим по умолчанию (`use_path_leg_streaming == false`)

- Генерация платформ из **выпеченного** `PathModel.platforms[]` (не пошаговый спавн из `next_step()` в каждом кадре).
- `PathSelector.initialize()` → загрузка библиотеки → выбор модели на забег.
- `PathModel.bake_from_steps(rules, world_bounds, ...)` — слоты с `x`, `y`, `segments`, `vanish`.
- Пул: `scripts/pool/PlatformPool.gd`.
- Мир для пути: один `world_bounds` на забег (`_setup_world_bounds`): высота — ось грани куба (153 600 px), ширина `world_right−world_left` (при align по грани — тоже 153 600 px). Нижняя грань по Y от позиции игрока + `world_bounds_pad_below_player`.
- Платформы: обычная; осыпающаяся (`vanish` → `is_crumbling`); decoy / `fake_visual_only` (без коллизии); ширина small / medium / large → 64×64, 128×64, 256×64 px.

### Режим стриминга чанков (`use_path_leg_streaming == true`)

- Узел **`PathLegStream`** в `level.tscn` (`scripts/managers/PathManager.gd`): колена из JSON в `DATA/PulseRunnerData/chunks/`, сборка через **`ChunkRegistry`** → **`LegBuilder`** → **`PlatformSpawner`** (инстанс `Platform.tscn`). Старт: `Level` выставляет `first_leg_anchor` и вызывает `start_streaming()` отложенно. В сцене по умолчанию флаг у `Level` **не** включён — без него чанки в рантайме **не** используются.
- В `scenes/level/Level.tscn` временно включён `PathLegStream.trace_chunk_selection=true`; `LegBuilder` пишет трассу выбора чанков (`[PathManager][chunks] ... model_id=...`) в `FileLogger` / `3301_LOG.txt`.
- Вспомогательная проверка: `debug_test_chunk_loader.gd` (headless, см. комментарий в файле).
- Опциональный оркестратор-пример: `scripts/managers/GameManager.gd` (в типовой `level.tscn` **не** подключён).

- **`PathLevelGenerator` / `PathLevelGenerator.gd` в репозитории нет** — удалён; старые документы, ссылающиеся на него, устарели.

## PathModel / библиотека

- Эталонные JSON-чанки (редактирование шаблонов): `DATA/PulseRunnerData/chunks/ideal_chunk_model_*.json` (`model_id` 0–5 и др.). Режим **без** стриминга загружает библиотеку из `path_library_50.json` — при правке только чанков обновляйте соответствующий элемент массива там, если нужно поведение в забеге.
- `PathLibrary.gd`: путь к JSON `res://DATA/PulseRunnerData/path_library_50.json`. Если файл отсутствует или пустой после парсинга — детерминированная генерация **50** моделей (встроенный seed `3301`). Если в JSON **меньше 50** моделей — используются загруженные; в консоль — `push_warning`.
- `PathSelector.gd`: `SeedManager.get_rng_for("path")` для индекса модели; направление по X от `global_seed` и `model_id`.
- `PathModel.gd`: шаги с полями `x_gap`, `y_delta`, `wave_id`, `decoy_count`, опционально **`size`**: `small` | `medium` | `large`. Валидация прыжка, проверка пересечений AABB, `resolve_platform_overlaps`, лимиты bake из `platform_rules.json` (`path_bake_max_slots`, `path_bake_max_iterations`, `path_min_horizontal_span_ratio`, `jump_reach_max_fraction`, и т.д.). Если в записи библиотеки заданы **`platforms[]`** (и при необходимости **`support_chain_indices`**), уровень может использовать предзаданную геометрию вместо bake (см. `Level.gd`, `3301_PLATFORM_LAYOUT_SPEC_FOR_LLM.txt`).

## Правила платформ

- Файл: `DATA/PulseRunnerData/rules/platform_rules.json` (плюс зеркало в `user://` через `DataManager` при необходимости).
- Ключевые поля включают: `min_gap`, `max_gap`, `height_variation`, `vanish_chance`, `platform_sizes`, `min_edge_gap`, `vertical_gap`, `safe_margin_x`, параметры мира (`world_screens`, `use_fixed_world_width`, …), лимиты bake пути (см. выше).

## DataManager (`scripts/DataManager.gd`)

- Загрузка данных из `res://DATA/PulseRunnerData/…` с fallback/копией в `user://DATA/…`.
- Секции: rules, paths, balance, events, shop, localization, news (по фактической реализации скрипта).
- Remote base URL для обновлений — в коде `DataManager` (ветка `PulseRunnerData` на GitHub).

## Firebase (Realtime Database)

- **Проект в консоли:** `EndlessRunnerAYO` (идентификатор вида `endlessrunnerayo` в консоли).
- **Realtime Database — базовый URL (REST):**  
  `https://endlessrunnerayo-default-rtdb.europe-west1.firebasedatabase.app`
- **Регион инстанса БД:** `europe-west1` (Belgium).
- **REST API:** к базовому URL добавляется путь узла и суффикс **`.json`** (например чтение корня: `…/firebasedatabase.app/.json`). Подробности: [Firebase Realtime Database REST](https://firebase.google.com/docs/reference/rest/database).
- **Правила (Rules), состояние на момент документирования:** тестовый режим с ограничением по времени — чтение/запись разрешены, пока `now < 1777756800000` (в консоли помечено датой окончания теста, напр. **2026-05-03**). **Не** считать это безопасной конфигурацией для продакшена; для релиза — правила с проверкой `auth` и отдельный аудит.
- **Связка с Godot:** при старте главного меню (`MainMenu.gd`) по умолчанию выполняется проверка **GET** `…/.json` и опционально **PUT** в узел `debug/godot_rtdb_ping.json` (флаги в инспекторе у корня сцены: `firebase_rtdb_ping_on_ready`, `firebase_rtdb_base_url`, `firebase_rtdb_write_test_ping`). Результат пишется в лог (`FileLogger` / `3301_LOG.txt`). Для релиза пинг можно отключить.
- **Firebase Auth (Google) — первая итерация (Android-first по архитектуре, без нативного плагина в репозитории):**
  - Код: `scripts/auth/AuthService.gd` (autoload), `scripts/auth/FirebaseGoogleAuth.gd` (REST Identity Toolkit `signInWithIdp` + refresh `securetoken`), UI — `MainMenu.tscn` / `MainMenu.gd` (кнопки «Войти через Google», «Выйти», строка статуса).
  - **Конфиг с Web API Key** не коммитится: `AuthService` читает сначала `user://firebase_web_config.json`, иначе `res://config/firebase_web_config.json`. Для редактора удобно скопировать `config/firebase_web_config.example.json` → `config/firebase_web_config.json`, вставить **Web API key** из Firebase (Project settings). Значение-заглушка `PASTE_…` в файле считается «не настроено». В **`.gitignore`** — шаблон `**/firebase_web_config.json` (любая копия с ключом). В **`.cursorignore`** те же пути, чтобы не тянуть ключ в контекст Cursor. Если файл случайно уже закоммичен: `git rm --cached -- path` и коммит.
  - **Android:** получение Google **id_token** должно делаться нативным плагином / GDExtension; затем вызов `AuthService.sign_in_with_google_id_token(id_token)`. Заготовка и пояснения: `addons/android_google_signin/README.md`. **`google-services.json`** — только локально/CI, путь после экспорта Godot — стандартный модуль Android (см. доку Godot 4 Android export).
  - **Windows / редактор:** полноценный Google Sign-In не реализован; в **отладочной** сборке (`OS.is_debug_build()`) доступно окно ввода **id_token** (только для ручной проверки REST). Релиз на ПК без отдельного OAuth в браузере — вне текущей итерации.
  - После входа: `GameState.player_uid`, `auth_email`, `auth_token` (Firebase idToken), `firebase_refresh_token`, `auth_provider = "google"` — сохраняются через `GameState.save_scores()`. При старте `AuthService` пытается **refresh** по сохранённому refresh-токену. Тестовая запись в RTDB: `users/<uid>/auth_heartbeat.json` с query **`?auth=<idToken>`** (успех при rules с `auth.uid == uid`).
  - **Черновик Rules (прод):** например  
    `{ "rules": { "users": { "$uid": { ".read": "$uid === auth.uid", ".write": "$uid === auth.uid" } } } }`  
    — плюс запрет записи в `debug/` для клиентов; тестовые открытые rules заменить до релиза.

## Игрок и камера

- `scripts/Player.gd`; сцена `level.tscn`: `Player` + `Camera2D` (типичный zoom `1.2`).
- Константы физики дублируются в `PhysicsConfig` для согласованности с PathModel.

## Платформа (`scripts/Platform.gd`)

- `@export var debug_log_ready: bool = false` — лог `[PLATFORM_READY]` в файл только при включении (снижение I/O при пуле).

## Стена

- `wall/wall.gd` — видимая область по камере, debounce перезагрузки с диска/sync, вызовы `WallRenderer.update_visible_area` / `update_segment`.
- `wall/WallRenderer.gd` — `MultiMeshInstance2D` (геометрия) + слой `Sprite2D` для текстур; **Thread** + `Semaphore` + приоритетные очереди для `Image.load`/resize; главный поток создаёт `ImageTexture` и обновляет спрайты; LRU + лимит **~120 MB** оценочно + idle-unload; инкрементальный обход спрайтов (`MAX_SPRITE_UPDATES_PER_FRAME`). Полное описание констант и состояний — **`3301_WALL_RENDERING_AND_STREAMING.md`**.
- `wall/data/WallData.gd` — `user://wall_segments.json`; загрузка **асинхронная** (`load_state`, `load_completed`, чанки по 150 сегментов/кадр + materialize по 30); `load_from_file()` не держит кадр на полном копировании 13k+ сегментов.

## Логирование (`scripts/Logger.gd`, autoload `FileLogger`)

- Приоритет записи: `res://3301_LOG.txt`; если недоступно (экспорт) — `user://3301_LOG.txt`.
- Строки с таймстампом; периодический `flush` (~2 с) в `_process`, плюс flush при старте/выходе.
- **Не** дублирует обязательно `res://DATA/logs/` (старые описания с несколькими путями не соответствуют текущему коду).

## Тесты (`3301_/3301_test/`)

- Набор автотестов и smoke-скриптов хранится в `res://3301_/3301_test/` (исторический каталог `tests/` удалён/устарел).
- Основные: `path_model_tests.gd`, `determinism_run_tests.gd`, `platform_generation_tests.gd`, `sync_merge_tests.gd`, `wall_visible_area_tests.gd`, `camera_jitter_tests.gd`, `test_economy.gd`, тесты покупок платформ/сегментов — см. `3301_TEST_PLAN.md`.

## Файл лога в репозитории

- В корне может быть **`3301_LOG.txt`** с краткой шапкой: при запуске из редактора **FileLogger** дописывает маркер `=== NEW SESSION ===` и сообщения; файл растёт от забега к забегу.

## Удалённые артефакты (не восстанавливать)

- Дампы `3301_CODE.txt`, `3301_TREE.txt` удалены как дубликаты репозитория / дерева сцен.
