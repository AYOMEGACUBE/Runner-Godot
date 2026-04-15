# 3301 SYNC_PROTOCOL

**Актуально:** 2026-04-15.

**Примечание:** релизный runtime sync ownership выполняется через RTDB (`EconomyRemoteSync` + `OwnershipRemoteSync`).

## Релизный источник истины (Primary)

- **Primary sync channel:** Firebase Realtime Database.
- **Секции:**
  - `users/<uid>/wallet` — кошелёк (`EconomyRemoteSync`),
  - `users/<uid>/ownership` — сегменты стены и платформы (`OwnershipRemoteSync`).
- **Fail-safe:** локальные `user://` данные остаются source-of-recovery при сетевом сбое; push/pull выполняется с retry по пользовательским действиям/логину.
- **Изображения покупок:** передаются в ownership как payload (`*_payload_b64`, `*_sha256`, `*_ext`) и материализуются у каждого клиента в `user://wall_images` / `user://platform_images`.

## Назначение

Протокол синхронизации данных покупок сегментов и платформ.

## Файлы данных

- Локальные (`user://`):
  - `user://wall_segments.json` (чтение в рантайме через `WallData.load_from_file()` + поэтапное наполнение `segments` — без длинного блокирования кадра; см. **`3301_WALL_RENDERING_AND_STREAMING.md`**)
  - `user://platforms.json`
- Транспортные (в рабочем дереве репозитория):
  - `wall_segments.json`
  - `platforms.json`

## Точки входа рантайма

- Push: `OwnershipRemoteSync.request_push_all()`
- Pull/Merge: `OwnershipRemoteSync.pull_ownership_then_merge()`
- Подписка UI: сигнал `OwnershipRemoteSync.ownership_updated(wall_changed, platform_changed)`

## Последовательность push (RTDB)

1. Сериализация локального ownership (`wall.to_dict()`, `platform_store.to_dict()`).
2. HTTP `PUT` в `users/<uid>/ownership.json?auth=<idToken>`.
3. После 2xx:
   - локальные `pending` записи текущего owner переводятся в `synced`,
   - эмитится `ownership_updated(true, true)`.

## Последовательность pull + merge (RTDB)

1. HTTP `GET` из `users/<uid>/ownership.json?auth=<idToken>`.
2. Сохранение remote snapshot в кэше sync-сервиса.
3. Слияние:
   - `WallData.merge_from_dict(remote_wall)`
   - `PlatformDataStore.merge_from_dict(remote_platforms)`
4. При изменениях локальные `user://` файлы сохраняются.
5. Эмитится `ownership_updated(wall_changed, platform_changed)`.

## Политика конфликтов и race checks

- Основное правило: first-buyer policy (более ранний timestamp покупки имеет приоритет).
- До локального коммита используется best-effort pre-check по кэшированному remote snapshot (first-come-first-served guard).
- Если ownership присутствует на обеих сторонах:
  - более ранний timestamp может заменить более поздний;
  - конфликтные записи маркируются `sync_status=conflict`.

## Модель статусов

- `pending` — операция запущена.
- `synced` — операция завершена успешно.
- `conflict` — обнаружен конфликт слияния.
- `failed` — ошибка транспорта RTDB.

## Требования к timestamp

- Временные метки покупки формируются через `Time.get_unix_time_from_system()`.
- Корректное локальное время повышает детерминизм разрешения конфликтов.

## Ограничения выполнения

- Для sync требуется валидный Firebase `idToken` и доступ к RTDB.
- Кэш remote snapshot не заменяет server-side transaction; это guard от stale local state, но не абсолютная блокировка гонки на уровне БД.
