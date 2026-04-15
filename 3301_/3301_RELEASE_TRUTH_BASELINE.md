# 3301 RELEASE TRUTH BASELINE

**Дата:** 2026-04-07  
**Ветка релиза:** `final_release`

## Stage 0 Baseline

- Рабочая ветка релиза создана: `final_release`.
- Зафиксированы критичные модули восстановления состояния:
  - `GameState.gd` (profile/run/wallet/auth persistence),
  - `wall/data/WallData.gd` (`user://wall_segments.json`; загрузка файла асинхронная чанками — см. `3301_WALL_RENDERING_AND_STREAMING.md`),
  - `scripts/platform/PlatformDataStore.gd` (`user://platforms.json`).
- Baseline тестов:
  - список test scripts зафиксирован по каталогу `3301_/3301_test/`,
  - автоматический запуск CLI в текущей среде может требовать локально установленный Godot binary в PATH.

## Truth Matrix (Current Runner Scope)

| Подсистема | Статус | Комментарий |
|---|---|---|
| Run generation: PathLibrary | implemented | Режим по умолчанию в `Level.gd` |
| Run generation: PathManager chunks | implemented | Включается флагом `use_path_leg_streaming` |
| Wall/Cube purchases | partial | Функционал есть, доводится transaction-safe path |
| Economy wallet | implemented | `GameState.wallet_coins` + `EconomyRemoteSync` (RTDB) |
| Ownership sync (wall/platform) | partial -> target implemented | RTDB канал введен как основной через `OwnershipRemoteSync` |
| Auth (Firebase Google REST) | partial | Android-first; desktop dev flow ограничен |
| UI scenes (`MainMenu`, `Level`, `GameOver`, `Profile`, `Champions`) | implemented | Дорабатываются fail-path и refresh strategy |

## Release Scope Lock

- В релиз входят только текущие механики runner-контра.
- Механики вне текущего контура (фонарик/охрана/батареи/генератор/лифт) остаются вне релизного критического пути.
- Любая partial фича должна быть скрыта/ограничена в UX до прохождения acceptance.

## Go/No-Go Criteria

- Нет открытых critical-дефектов в run-loop, purchases, sync.
- Покупки сегментов проходят атомарно (без частичных применений).
- RTDB sync имеет recoverable fail-path и не ломает игру при сетевых ошибках.
- Документация соответствует фактическому runtime-контракту.
