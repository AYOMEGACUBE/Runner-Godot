# 3301 Стена: рендеринг, потоки, JSON, кэш

**Актуально:** 2026-04-15. Описывает текущую реализацию в `wall/WallRenderer.gd` и `wall/data/WallData.gd`. Формат `user://wall_segments.json` и публичные API (`set_face_image`, `get_face_image_path`, `buy_sides_atomic`, …) **не менялись**.

## Назначение

- **Геометрия:** `MultiMeshInstance2D` — батч-ячейки стены.
- **Текстуры:** `Sprite2D` поверх (по одному на видимый сегмент с картинкой).
- **Данные:** `WallData` → `user://wall_segments.json`; файлы картинок → `user://wall_images/`.

## WallData — асинхронная загрузка JSON

**Проблема, которую сняли:** однокадровый `get_as_text()` + `JSON.parse_string()` + копирование всех сегментов давали заметный фриз при ~13k+ сегментах.

**Как сейчас:**

1. `load_from_file()` **не блокирует** надолго: открывает файл, читает текст в строку (короткий I/O), выставляет состояние и возвращает управление.
2. Узел `WallData` в `_process()` вызывает `update_async()` пока `load_state` не станет `DONE` или `FAILED`.
3. **State machine** (`enum LoadState`): `IDLE` → `READING_FILE` → `PARSING_JSON` → `LOADING_SEGMENTS` → `MATERIALIZING` → `DONE` / `FAILED`.
4. **Пошагово:**
   - один кадр: парсинг JSON (`JSON.parse_string`) — всё ещё O(n) по размеру файла, но **один** вызов на весь файл;
   - затем **150 сегментов за кадр** (`SEGMENTS_PER_FRAME_LOAD`) — копирование в `segments` из распарсенного словаря;
   - затем **30 сегментов за кадр** (`MATERIALIZE_PER_FRAME`) — `_materialize_face_image_payload` для base64→файл при необходимости.
5. Сигнал **`load_completed(ok: bool)`** — UI/логика могут дождаться готовности данных.
6. Публичное поле **`load_state`**, **`load_progress`** (0..1).

**Логи:** `[PERF] json_parse_ms=… segments_total=…`, затем `[LOAD] Loaded items: … segments=… total_ms=…`.

**Важно:** до завершения `MATERIALIZING` часть `image_path` у граней может ещё дозаполняться; рендерер не должен предполагать «всё готово» в первом кадре без проверки `load_state`.

## WallRenderer — поток загрузки изображений

**Поток (Thread):** только `Image.load` / чтение байтов / `Image.resize(48,48)` — без `Node`, без `ImageTexture`.

**Главный поток:** `ImageTexture.create_from_image`, запись в кэш, привязка к `Sprite2D`.

### Синхронизация

| Ресурс | Доступ |
|--------|--------|
| `_thread_queue`, `_thread_queued_paths`, `_active_loading_count` | только под `_thread_mutex` |
| `_thread_results` | `_results_mutex` (producer: thread, consumer: main) |
| `_texture_cache`, `_texture_cache_order`, `_texture_last_used` | только **main thread** (`_cache_get` / `_cache_set` / `_cache_evict`) |

**Semaphore:** `post()` вызывается только если после постановки задачи очередь потока **не пуста** (нет лишних пробуждений).

**Backpressure:** новая задача в поток уходит только если `_active_loading_count < MAX_ACTIVE_LOADING` (8).

### Очереди и лимиты (константы в коде)

| Константа | Значение | Назначение |
|-----------|----------|------------|
| `MAX_TEXTURE_LOADS_PER_FRAME_GAME` | 2 | Задач из main-очереди в поток за кадр (забег) |
| `MAX_TEXTURE_LOADS_PER_FRAME_VIEW` | 24 | То же в CubeView |
| `MAX_TEXTURE_QUEUE_LENGTH` | 500 | Потолок `_texture_load_queue` |
| `MAX_STREAM_QUEUE_SIZE` | 500 | Потолок приоритетной очереди потока |
| `MAX_ACTIVE_LOADING` | 8 | Одновременно «в полёте» до результата |
| `MAX_THREAD_TASKS_PER_ITER` | 4 | За одно пробуждение потока |
| `MAX_APPLY_PER_FRAME` | 8 | `ImageTexture.create_from_image` за кадр |
| `MAX_SPRITE_UPDATES_PER_FRAME` | 50 | Итерация по `_segment_ids` без полного прохода за кадр |
| `MAX_TEXTURES_IN_MEMORY` | 384 | Лимит по количеству записей в кэше |
| `MAX_TEXTURE_MEMORY_MB` | 120 | Оценка по `count × 48×48×4` байт |
| `UNLOAD_IDLE_SEC` | 30 | Выгрузка текстуры не у активных сегментов |
| `UNLOAD_CHECK_INTERVAL` | 5 | Период проверки выгрузки |

### Приоритет загрузки

Задача в поток: `{ path, key, priority }`. Приоритет: ближе к камере выше; видимый сегмент (`_segment_index`) получает бонус. При переполнении очереди вытесняется наименее приоритетная задача.

### Кэш (единый API)

- `_cache_get(path)` — hit + LRU touch + учёт статистики.
- `_cache_set(path, tex)` — запись + eviction по лимитам.
- `_cache_evict(path)` — удаление из словаря, порядка LRU и `last_used`.

Источник истины порядка: **`_texture_cache_order`**; `_texture_last_used` — вспомогательный для idle-unload.

### Инкрементальные проходы

- `_update_image_sprites()` сбрасывает курсор и делает первый chunk; далее **`_tick_sprite_update()`** в `_process()` добирает до `MAX_SPRITE_UPDATES_PER_FRAME` сегментов за кадр.
- После готовности текстуры из потока **`_apply_texture_to_segments_by_path`** может обойти все видимые инстансы с этим путём (обычно мало); при экстремальном числе инстансов узкое место остаётся на стороне Sprite2D.

## Resize изображений: два контекста

1. **Импорт при `set_face_image` / `_prepare_image_for_face` (WallData):** подготовка PNG 48×48 на диск (`user://wall_images/…`) для стабильного хранения и sync.
2. **Отображение (WallRenderer, thread):** при загрузке файла с диска гарантируется 48×48 перед созданием `ImageTexture` (если на диске уже 48×48 — resize фактически no-op).

## Отладка

- `WallRenderer.DEBUG_LOG = true` — раз в ~5 с строка `[PERF]` (кэш, очереди, active, MB, hit%, dropped, курсор спрайтов).
- Thread: `[THREAD] …` / `[MAIN] …` при `DEBUG_LOG`.

## Известные ограничения и следующий слой

- **Sprite2D overlay:** при тысячах видимых спрайтов узкое место — SceneTree и draw calls; streaming загрузки это не убирает. Следующий крупный шаг — батч-отрисовка (один `CanvasItem` / атлас / MultiMesh с UV), см. `3301_RISKS_AND_LIMITATIONS.md`.
- **JSON parse** всё ещё один проход по всей строке файла в одном кадре; разбито только **заполнение** `segments` и **materialize** по кадрам.

## Связанные файлы

| Файл | Роль |
|------|------|
| `wall/data/WallData.gd` | Модель, save/load async, merge, покупки |
| `wall/WallRenderer.gd` | MultiMesh, спрайты, thread loader, кэш |
| `wall/wall.gd` | Видимая область, связь с камерой, диск/sync debounce |
| `scripts/scenes/cube_view/CubeView.gd` | Покупки, камера, миникарта |

## См. также

- `3301_DATA_MODELS.md` — поля сегментов и граней.
- `3301_SYNC_PROTOCOL.md` — merge стены.
- `3301_PURCHASE_FLOW.md` — UX покупок.
