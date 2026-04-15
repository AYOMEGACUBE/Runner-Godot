# 3301 PURCHASE_FLOW

**Актуально:** 2026-04-15.

## Назначение

Документ описывает поток покупки сегментов стены и платформ в `CubeView`.

**Autoload `PurchaseManager`** (`scripts/purchase/PurchaseManager.gd`) — списание монет, коммиты покупок, сигналы `purchase_succeeded` / `purchase_failed` / `coins_updated`; `CubeView` подписывается в `_ready`. Sync — через **RTDB** (`OwnershipRemoteSync` / `EconomyRemoteSync`).

## Поток покупки сегментов

1. Пользователь открывает `CubeView`.
2. Запускает выбор сегментов через `BulkPurchaseDialog`.
3. Выбирает `segment_id` на стене (клик/drag).
4. Выбирает сторону сегмента (`front/back/left/right/top/bottom`) в `BulkPurchaseDialog`.
5. При необходимости задаёт изображения и ссылки.
6. Подтверждает покупку.
7. `CubeView` вызывает `PurchaseManager.commit_bulk_wall_segment_purchase(...)`.
7. Перед атомарной записью используется best-effort race guard (проверка доступности в `OwnershipRemoteSync` по кэшированному remote snapshot).
8. Внутри выполняется `WallData.buy_sides_atomic(...)` ("all-or-nothing").
10. После успеха запускается `OwnershipRemoteSync.request_push_all()` (RTDB ownership).
11. При успехе:
   - применяются метаданные изображений/ссылок,
   - изображения сериализуются как payload (`image_payload_b64` + hash/ext) для межклиентского отображения,
   - обновляется визуал сегментов,
   - `sync_status` граней помечается `pending` и после успешного push становится `synced`,
   - клиенты получают event `ownership_updated` и обновляют UI/рендер стены в `CubeView` и в игровом `Level`.

## Поток покупки платформ

1. Пользователь нажимает `Купить платформы`.
2. Открывается `PlatformPurchaseDialog`.
3. Пользователь задаёт:
   - `platform_type` (`normal`/`crumbling`/`decoy`),
   - `platform_size` (`small`/`medium`/`large`),
   - `height_level` (1..7),
   - `quantity` (1–10),
   - опциональные: основное и дополнительное изображение платформы,
   - опциональную ссылку,
   - срок действия в днях (days), preview и индикатор доступности.
4. `PlatformPurchaseDialog` запрашивает доступность через `PurchaseManager.get_platform_availability(...)`.
5. Подтверждает покупку.
6. `CubeView` вызывает `PurchaseManager.buy_platforms(...)`.
7. `PurchaseManager`:
   - валидирует баланс и доступность слотов,
  - считает цену по дням: `total = daily_price(size, level) * days * quantity`,
  - где `daily_price = base_size + (level - 1) * 100`,
  - базовые цены L1: `small=100`, `medium=200`, `large=300` coin/день,
   - выполняет атомарный батч в `PlatformDataStore.buy_platforms_atomic(...)`,
   - назначает `platform_id` вида `h<level>_slot_<n>`,
   - дописывает `platform_size`, `height_level`, `height_world_y`, `jump_image_*`.
8. При успехе:
   - данные сохраняются в store,
   - изображения платформ сериализуются в payload (`image_payload_b64` / `jump_image_*_payload_b64`) и материализуются локально на клиентах после merge,
   - в рантайме `Level.gd` / `PlatformSpawner.gd` применяют купленные изображения/тип к соответствующим slot-id платформам,
   - выполняется `OwnershipRemoteSync.request_push_all()` (RTDB),
   - `sync_status` платформ переводится `pending -> synced` после успешного push.

## Диалоги, участвующие в потоке

- `BulkPurchaseDialog.tscn` / `.gd`
- `BulkImageUploadDialog.tscn` / `.gd`
- `PlatformPurchaseDialog.tscn` / `.gd`
- `PurchaseDialog.tscn` / `.gd` (совместимость с одиночным сценарием)
- `PurchaseModeDialog.tscn` / `.gd`

## Атомарность

- Батч сегментов применяется по принципу "всё или ничего".
- Батч платформ применяется по принципу "всё или ничего".
- При конфликте/ошибке валидации частичное применение батча не допускается.

## Связь с синхронизацией

- Оба потока используют RTDB sync (`OwnershipRemoteSync`), кошелёк — `EconomyRemoteSync`.
- Используются статусы: `pending`, `synced`, `conflict`, `failed`.
