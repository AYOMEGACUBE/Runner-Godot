# 3301 SCENE_TREE

**Актуально:** 2026-04-15. Упрощённое дерево основных сцен; детали — в `.tscn` в редакторе. Autoload и флаги уровня — **`3301_PROJECT_STATE.md`**. Стена в `Level` / `CubeView`: `wall.tscn` + **`3301_WALL_RENDERING_AND_STREAMING.md`**.

## `res://scenes/main_menu/MainMenu.tscn`

- `MainMenu` (Control, `MainMenu.gd`)
  - `RootHBox`
    - `LeftPanel`
      - `TitleLabel`
      - `NicknameLabel`
      - `CoinsLabel`
      - `VBoxButtons`
        - `PlayButton`
        - `ChampionsButton`
        - `ProfileButton`
        - `CubeViewButton`
    - `RightPanel`
      - `AvatarPreview`
  - `WarnDialog`

## `res://scenes/level/Level.tscn`

- `Level` (Node2D, `scripts/scenes/level/Level.gd`)
  - `PathLegStream` (Node, `scripts/managers/PathManager.gd`) — стриминг «колен» из JSON-чанков (`DATA/PulseRunnerData/chunks/`); в сцене: `player_path` → `../Player`, `platforms_parent_path` → `../Platforms`, `auto_start = false` (старт из `Level` при включённом стриминге).
  - `Platforms` (Node2D) — сюда попадают платформы и в режиме `PathManager`, и в режиме пула `PlatformPool`.
  - `Wall` (instance `wall/wall.tscn`)
  - `Player` (CharacterBody2D, `scripts/Player.gd`)
    - `Camera2D`
    - `CollisionShape2D`
    - `AnimatedSprite2D`
    - `CustomAvatarSprite`
  - `HUDLayer` (CanvasLayer)
    - `HUD` (Control, `scripts/ui/HUD.gd`)
      - `VBoxContainer`
        - `NameLabel`
        - `ScoreLabel`
      - `BackButton`

### Генерация пути на уровне

| Режим | Условие | Источник траектории |
|--------|---------|---------------------|
| Стриминг чанков | `Level.use_path_leg_streaming == true` и узел по `path_leg_stream_node` — `PathManager` | `ChunkRegistry` → `LegBuilder` → `PlatformSpawner` |
| По умолчанию в скрипте | `use_path_leg_streaming == false` | `PathSelector` / `PathLibrary` (`path_library_50.json` и др.), пул платформ в `Platforms` |

В `level.tscn` флаг `use_path_leg_streaming` в файле не переопределён (берётся дефолт из `Level.gd`).

## `res://scenes/cube_view/CubeView.tscn`

- `CubeView` (Node2D, `scripts/scenes/cube_view/CubeView.gd`)
  - `Camera2D`
  - `GateLine`
  - `UILayer` (CanvasLayer)
    - `Panel`
      - `VBoxContainer`
        - `TitleLabel`
        - `BackButton`
        - `PurchaseSegmentButton`
    - `SelectionOverlay`
      - `VBox`
        - `HintLabel`
        - `NextButton`
        - `CancelSelectionButton`
    - `BulkSelectionOverlay`
      - `VBox`
        - `HintLabel`
        - `OKButton`
        - `CancelButton`
    - `MinimapPanel`
      - `MinimapLabel`
      - `MinimapViewport` (SubViewport)
        - `MinimapCamera`

## `res://scenes/game_over/GameOver.tscn`

- `GameOver` (CanvasLayer, `scripts/scenes/game_over/GameOver.gd`)
  - `GameOver#MobileScale` (`MobileUIScale.gd`)
  - `Panel`
    - `VBox`
      - `TitleLabel`
      - `HeightLabel`
      - `ScoreLabel`
      - `Buttons`
        - `ViewCubeButton`
        - `RestartButton`
        - `MainMenuButton`

## Другие сцены

- `res://scenes/profile/Profile.tscn`
- `res://scenes/champions/Champions.tscn`
- `res://scenes/loading/LoadingLevel.tscn` — в сцене указан `res://LoadingLevel.gd`; файла скрипта в репозитории нет (сцена битая, на главный поток не влияет, пока сцена нигде не грузится).

## Диалоговые сцены (`res://scenes/dialogs/`)

- `BulkPurchaseDialog.tscn`
- `BulkImageUploadDialog.tscn`
- `PlatformPurchaseDialog.tscn`
- `PurchaseDialog.tscn`
- `PurchaseModeDialog.tscn`

## Отладка чанков (не сцена)

- `debug_test_chunk_loader.gd` — headless-проверка `ChunkRegistry` / смоук `LegBuilder` (см. комментарий в файле).
