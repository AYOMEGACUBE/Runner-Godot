# 3301 DATA_MODELS

**Актуально:** 2026-04-15.

## WallData (`wall/data/WallData.gd`)

- Файл хранения: `user://wall_segments.json`.
- **Загрузка с диска:** не блокирует главный поток на копировании тысяч сегментов за один кадр. `load_from_file()` запускает pipeline; прогресс — `load_state` (`LoadState`: `IDLE`, `READING_FILE`, `PARSING_JSON`, `LOADING_SEGMENTS`, `MATERIALIZING`, `DONE`, `FAILED`), `load_progress` 0..1; по завершении — сигнал **`load_completed(ok)`**. Узел обрабатывает шаги в своём `_process()` (`update_async()`). Чанки: **150** сегментов/кадр в словарь, **30** сегментов/кадр на materialize base64→файл. Подробности и логи `[PERF]` — **`3301_WALL_RENDERING_AND_STREAMING.md`**.
- Корневая модель:
  - `segments: Dictionary`.
- Модель сегмента:
  - `height: float`
  - `price: int`
  - `group_id: String`
  - `corporate_mode: bool`
  - `faces: Dictionary`
  - `first_owner: String`
  - `purchase_date: int`
- Модель грани (`face`):
  - `owner: String`
  - `image_id: String`
  - `image_path: String`
  - `image_payload_b64: String` (png payload для межклиентской доставки)
  - `image_sha256: String`
  - `image_ext: String`
  - `link: String`
  - `purchase_date: int`
  - `sync_status: String`.
- Операции:
  - `buy_side(...)` — одиночная покупка,
  - `buy_sides_atomic(...)` — атомарная батч-покупка,
  - `to_dict()` / `from_dict()` / `merge_from_dict(...)` — сериализация и merge для sync.

## PlatformData (`scripts/platform/PlatformDataStore.gd`)

- Файл хранения: `user://platforms.json`.
- Корневая модель:
  - `version: int`
  - `saved_at: int`
  - `platforms: Dictionary`.
- Запись платформы:
  - `platform_id: String`
  - `owner_uid: String | null`
  - `platform_type: String`
  - `platform_size: String` (`small|medium|large`, optional metadata)
  - `height_level: int` (1..7, optional metadata)
  - `height_world_y: int` (derived from level, optional metadata)
  - `image_path: String | null`
  - `image_payload_b64: String`
  - `image_sha256: String`
  - `image_ext: String`
  - `jump_image_up_path: String | null` (optional metadata)
  - `jump_image_up_payload_b64: String`
  - `jump_image_up_sha256: String`
  - `jump_image_up_ext: String`
  - `jump_image_down_path: String | null` (optional metadata)
  - `jump_image_down_payload_b64: String`
  - `jump_image_down_sha256: String`
  - `jump_image_down_ext: String`
  - `link: String | null`
  - `purchase_timestamp: int | null`
  - `expires_at_timestamp: int | null`
  - `version: int`
  - `sync_status: String`.

### Прайсинг платформ по дням

- Источник: `PurchaseManager.get_platform_daily_price(...)`.
- Формула: `daily_price = base_size + (height_level - 1) * 100`.
- Базовые цены (L1):
  - `small`: 100 coin/день
  - `medium`: 200 coin/день
  - `large`: 300 coin/день
- Для L7 соответственно: `small=700`, `medium=800`, `large=900`.
- Итог покупки: `total = daily_price * duration_days * quantity`.

### Height levels (platform purchase)

- `PLATFORM_HEIGHT_LEVELS = 7`
- `PLATFORM_LEVEL_HEIGHTS = [1000, 5000, 10000, 20000, 50000, 100000, 200000]`
- Slot id format for deterministic ownership: `h<level>_slot_<index>`

## PathModel (`scripts/path/PathModel.gd`)

- `model_id: int`
- `trend_degrees: float`
- `steps: Array[Dictionary]`
  - `x_gap: float`
  - `y_delta: float`
  - `wave_id: int`
  - `decoy_count: int`
  - `size: String` (опционально) — `small` | `medium` | `large`
- После **`bake_from_steps`**: `platforms: Array[Dictionary]` — `x`, `y`, `segments`, `vanish` (слоты для `Level`).

## Chunk JSON (файлы в `DATA/PulseRunnerData/chunks/`)

Используются **PathManager** / **ChunkRegistry** (и как эталон для ручного переноса в `path_library_50.json`).

- Файл: массив из одного объекта **или** один объект; парсер принимает оба варианта.
- Объект модели (минимум для попадания в реестр):
  - `model_id: int` (обязательно **≥ 0**)
  - `platforms: Array` — непустой; элементы — слоты с полями как в `3301_PLATFORM_LAYOUT_SPEC_FOR_LLM.txt` (`x`, `y`, `segments`, `vanish`, `kind`, `order`, `is_decoy`, …)
  - `support_chain_indices: Array` — индексы опорных платформ в `platforms` (нужны **LegBuilder** и **DifficultyScaler** для crumble по цепи)
  - `steps: Array` — часто `[]` для чисто предзаданной геометрии
  - прочие поля (`trend_degrees`, `bait_band` в слотах и т.д.) — по спецификации; рантайм чанков игнорирует неиспользуемые ключи при спавне

**Не** путать: запись в **`path_library_50.json`** — элемент того же духа, но живёт в одном массиве из до 50 моделей и выбирается **PathSelector**, а не сканером папки.

## GameState (`GameState.gd`)

- Профиль:
  - `nickname`, `player_uid`, `auth_provider`, `auth_token`.
- Игровое состояние:
  - `score`, `best_score`, `is_game_over`,
  - `max_height_reached`,
  - `last_run_score`, `last_run_max_height`, `has_finished_run`.
- Герой/аватар:
  - `selected_hero_id`, `use_custom_avatar`, пути кастомного аватара.
- Прогресс стены:
  - `active_wall_side`, `unlocked_sides`, `wall_breathing_enabled`.

## SegmentData (runtime-форма)

- Идентификатор: `segment_id = "x_y"`.
- Ключ стороны: `front/back/left/right/top/bottom`.
- Производные значения:
  - высота сегмента по индексу Y,
  - динамическая цена по формуле высоты.

## PlatformStore

- Реализация: `PlatformDataStore`.
- Функции:
  - получение/создание записи;
  - атомарная батч-покупка;
  - merge с удалённым состоянием;
  - массовое обновление sync-статусов.
