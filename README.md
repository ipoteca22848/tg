# tg — неофициальная сборка Telegram Desktop

База — полный открытый клиент **Telegram Desktop v7.4.4**, точный commit
в `upstream.json`. Патч добавляет в «О программе» надпись
«Скопировано из открытого исходного кода Telegram Desktop. Неофициальная сборка».
Авторство и лицензия сохраняются.

**EXE пока не собран.** Здесь Linux; официальный Windows toolchain требует
Windows, MSVC и Windows SDK. Это клиент Telegram Desktop, а не копия
серверов Telegram или объединение всех функций мобильных приложений.

## Подготовка

Нужны Git и Python 3.11+. Из корня проекта:

```console
python scripts/build.py --prepare-only
```

Исходники и закреплённые подмодули загружаются в `.build/tdesktop`.
Повторный запуск не сбрасывает чужие изменения. Несовпадение ревизии или
конфликт патча останавливают подготовку. Для проверки только патча можно
добавить `--no-submodules`; это не полная подготовка.

## Сборка Windows x64

Следовать `docs/building-win.md` в подготовленных исходниках: Visual Studio
2026, C++ Build Tools **14.44**, Windows SDK **10.0.26100.0**, Git, Python,
CMake, Ninja в PATH. Открыть x64 Native Tools Command Prompt с
`-vcvars_ver=14.44`. Рекомендуется короткий путь без пробелов, например `D:\tg`.
Первая сборка Qt, WebRTC, FFmpeg и других зависимостей может занять часы.

Получить собственные API credentials:
https://core.telegram.org/api/obtaining_api_id . Передать `TDESKTOP_API_ID`
и `TDESKTOP_API_HASH` через окружение машины сборки. Не присылать значения
в чат и не сохранять в репозитории.

```console
cd /d D:\tg
python scripts/build.py --jobs 4
```

Для проверки только компиляции без собственных API credentials:

```console
python scripts/build.py --test-api --jobs 4
```

Тестовые credentials upstream ограничены, не подходят для распространения
или полноценной проверки входа. Такой архив явно помечается `test-api`.

Результат: `.build/tdesktop/out/Debug/Telegram.exe` и архив
`dist/tg-unofficial-windows-x64-debug-*.zip` с EXE, лицензией и SHA-256.
Сборка Debug, LTO выключено. Официальное автообновление отключено, чтобы
не потерять изменения. Формат EXE проверяется скриптом; запуск и функции
проверяются отдельно по [плану приёмки](docs/validation.md).
Архив не содержит аккаунтов, tdata, CMake cache и PDB.

Windows-сборка и запуск скрипта на Windows ещё не проверены.
Для распространения выполнить [требования лицензии](NOTICE.md), включая
предоставление соответствующего исходного кода. Публичного релиза нет.

## GitHub Actions

Подготовлен ручной workflow `.github/workflows/windows.yml`.
После отправки файлов в GitHub открыть Actions → Windows x64 unofficial client
→ Run workflow. Для своей API-пары добавить repository secrets
`TDESKTOP_API_ID` и `TDESKTOP_API_HASH`, затем выключить `test_api` при запуске.
Для проверки компиляции можно оставить `test_api` включённым.
После успешной сборки скачать артефакт `tg-windows-x64-debug`.
Workflow ещё не запускался; совместимость runner и лимиты первой сборки
нужно проверить. Публикации релиза и автоматического запуска при push нет.

Проверки инструментов сборки (не самого клиента):

```console
python -m unittest discover -s tests -v
```
