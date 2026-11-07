# Порядок в сборке

Ветка: `build`.

Сборка держалась на нескольких разрозненных скриптах: bundle-скрипт на каждую ОС (sh и bat),
проверка компиляции под Windows, тесты под Windows, плюс ручные шаги (положить библиотеку
Sciter рядом с программой и тестами, подписать ее на маке). Программа собиралась в корень
проекта, debug и release перетирали друг друга, бандлы тоже ложились в корень. Bundle-скрипты
вызывали `dub` без `--compiler=ldc2`. Библиотеки Sciter лежали в `libs/` вне git.

## Решение

- Библиотеки Sciter (`libs/`, 134 МБ на все платформы) хранятся в git через LFS:
  `.gitattributes` отдает LFS файлы `.dylib`, `.so`, `.dll` в `libs/`. Версия Sciter записана
  в `libs/VERSION`: биндинг `source/sciter/capi` привязан к API конкретной версии.
- `dub.selections.json` теперь в git: для программы версии зависимостей фиксируются, чтобы
  сборка повторялась.
- Раскладку сборок делает сам dub (`dub.sdl`): `targetPath "build/$PLATFORM-$ARCH-$BUILD_TYPE"`
  кладет каждую сборку в свою папку (`osx-aarch64-debug`, `linux-x86_64-release`,
  `osx-aarch64-unittest` для `dub test`), а `copyFiles` по платформе и архитектуре кладет рядом
  библиотеку Sciter. Поэтому и голые `dub build` / `dub test` работают без ручного копирования
  (в свежем worktree тоже), а у каждой сборки свой `settings.json`.
- Один скрипт на Node (`scripts/build.mjs`) вместо bundle-скриптов на sh и bat, проверки
  компиляции под Windows и тестов под Windows: Node уже нужен проекту (`node --test`,
  `i18n-extract.mjs`), и один скрипт работает одинаково на всех ОС. Команды:
  - `build` (по умолчанию): debug под архитектуру машины, `--release`, `--arch x64|arm64`.
    Параметр — архитектура, а не платформа: собрать программу для другой ОС нельзя (для Windows
    с мака нет линковки).
  - `test`: D-юниттесты (`dub test`) и JS-тесты (`node --test tests/js`) вместе.
  - `dist`: релизный дистрибутив в `build/dist/<macos|linux|windows>/`.
  - `check-windows`: компиляция приложения и юниттестов под Windows x64 без линковки (бывший
    `check-windows-compile.sh`).
  - Чистая часть (разбор команды, аргументы dub, `Info.plist`, desktop entry) проверяется
    `tests/js/build-script.test.mjs`.
- На маке `dist` собирает universal binary: две сборки (`--arch=x86_64`, `--arch=aarch64`),
  склеенные `lipo`. Для x86_64 линкеру нужен runtime ldc2 под x86_64: в ldc из Homebrew его нет
  (только arm64), он есть в официальном пакете LDC `osx-universal`. Без него скрипт говорит
  это прямо; `dist --arch arm64` собирает только под arm64. Debug всегда под одну архитектуру.
- Версия программы — файл `VERSION` в корне, `dist` подставляет ее в `Info.plist`.
- Подпись на маке: рядом с бандлом лежит `sign.command` (открывается из Finder в Терминале):
  снимает карантин и подписывает ad-hoc `libsciter.dylib`, потом бандл. `dist` подписывает им же.
  - Бандл собирается и подписывается во временной папке и копируется в `build/dist` через
    `ditto`: папка проекта в `Documents` синхронизируется iCloud, File Provider вешает
    `com.apple.FinderInfo` на новый `.app`, и codesign отказывается его подписывать
    («resource fork, Finder information, or similar detritus not allowed»). Подписанному
    бандлу этот атрибут уже не мешает.

## Решили не делать

- Скачивать Sciter скриптом вместо LFS: пока LFS устраивает.
- Документация по сборке, CI и проверка версии ldc2 — следующие шаги, в `docs/backlog.md`.
