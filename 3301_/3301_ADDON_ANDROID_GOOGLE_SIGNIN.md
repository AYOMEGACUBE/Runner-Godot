# 3301 — Android: нативный Google Sign-In (заготовка)

В Godot 4 на **Android** получение **Google ID token** для `AuthService.sign_in_with_google_id_token()` делается только нативным кодом (Java/Kotlin) или готовым плагином.

## Что уже есть в проекте

- `AuthService` (autoload) принимает **Google `id_token`** и обменивает его на Firebase через REST `signInWithIdp`.
- После успеха заполняются `GameState.player_uid`, `auth_token` (Firebase idToken), `firebase_refresh_token`, `auth_email`.

## Что нужно добавить для полноценного входа на устройстве

1. Зарегистрировать приложение **Android** в Firebase, добавить **SHA-1/256** ключа подписи, положить **`google-services.json`** в Gradle-проект экспорта.
2. Подключить плагин, который:
   - вызывает Google Sign-In / Credential Manager;
   - возвращает в GDScript строку **id_token**;
   - вызывает `AuthService.sign_in_with_google_id_token(id_token)`.

Варианты: собственный модуль `android/plugins/...` по документации Godot 4, либо сторонний плагин с поддержкой 4.x (проверять актуальность под вашу версию движка).

## Временная отладка без плагина

В редакторе / на ПК: кнопка **«Войти через Google»** открывает окно **ввода id_token вручную** (только `OS.is_debug_build()`), либо получите токен внешним OAuth-инструментом. Не использовать в релизе.

## Расположение аддона в репозитории

Исходники заготовки: `addons/android_google_signin/`.

*Проверено по составу репозитория: 2026-04-15.*
