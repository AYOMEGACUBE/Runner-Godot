# 3301 RELEASE CHECKLIST (final_release)

**Актуально:** 2026-04-15.

## Runtime Critical

- [ ] `MainMenu -> Level -> GameOver -> CubeView` проходит без runtime ошибок.
- [ ] Старт с большим `user://wall_segments.json` (много сегментов): нет секундного фриза; логи `[PERF] json_parse_ms` / `[LOAD] … total_ms` (см. **`3301_WALL_RENDERING_AND_STREAMING.md`**).
- [ ] Покупка одиночного сегмента: списание, ownership, sync_status переходы.
- [ ] Batch-покупка сегментов: атомарность (нет частичных применений).
- [ ] Pull после внешних изменений корректно merge-ит ownership.
- [ ] Сетевой сбой в RTDB не приводит к крашу и потере локальных данных.

## Sync Channel

- [ ] RTDB используется как primary для wallet + ownership.
- [ ] После успешного push `pending -> synced` фиксируется локально.

## UX / Tech Debt

- [ ] В runtime нет принудительных debug-веток (instant death и т.п.).
- [ ] UI обновляется без лишнего per-frame polling в не-геймплейных сценах.
- [ ] Битые сцены/ассеты не используются в пользовательском маршруте.
- [ ] Временные pre-release флаги выключены/удалены:
  - `PathLegStream.trace_chunk_selection=true` (если не нужен в релизном логе),
  - `[3301_temp_pre_release].wallet_boost_enabled`.

## Test Gate

- [ ] `3301_/3301_test/segment_purchase_tests.gd`
- [ ] `3301_/3301_test/platform_purchase_tests.gd`
- [ ] `3301_/3301_test/sync_merge_tests.gd`
- [ ] `3301_/3301_test/test_economy.gd`
- [ ] smoke чеклист из `3301_TEST_PLAN.md`

## Android Release Candidate

- [ ] Сборка release apk/aab проходит.
- [ ] smoke на устройстве (авторизация, run-loop, покупки, возвраты сцен).
- [ ] логи не содержат critical `push_error` в релизном сценарии.
