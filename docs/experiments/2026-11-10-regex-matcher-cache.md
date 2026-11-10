# Кеш матчера `std.regex` при параллельном поиске

## Вопрос

Находка ревью параллельного скана (`docs/backlog.md`): `std.regex` хранит один движок на поток
(`matchOnceImpl`, `static cacheKey`). Пересоздается ли он на каждой записи, когда два
регулярных выражения проверяются по очереди, и упираются ли потоки скана в замок GC?

## Условия

- 2026-11-10, ветка `parallel-scan-review` от `master` `0a3bd5d`.
- Apple M1 Pro (8 производительных + 2 энергоэффективных ядра), macOS, LDC 1.43.0.
- Лог: `node scripts/build.mjs gen-log build/bench/1g.dlt --format dlt --size 1G` (seed 1,
  8 942 422 записи).
- Сборка и запуск, по 3 раунда поиска, берется медиана:

```sh
ldc2 -O3 -release -enable-inlining -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
    -I$HOME/.dub/packages/dxml/0.4.5/dxml/source scripts/bench_index.d -of=build/bench/bench_index
build/bench/bench_index build/bench/1g.dlt 'err\w+ \d' regex --threads=N --search-only
build/bench/bench_index build/bench/1g.dlt 'fail\w+ \d' regex --threads=N --search-only
build/bench/bench_index build/bench/1g.dlt 'err\w+ \d' regex --regex='fail\w+ \d' --threads=N --search-only
```

`--regex` добавляет чип-регулярку без учета регистра; запись, не совпавшая с первым чипом,
проверяется вторым.

## Данные

| Потоки пула | `err\w+ \d` (79 958) | `fail\w+ \d` | оба чипа (171 976) |
|-------------|----------------------|--------------|--------------------|
| 1           | 2075 мс              | 2127 мс      | 5925 мс            |
| 4           | 541 мс               | —            | 11 671 мс          |
| 9           | 283 мс               | 287 мс       | 14 554 мс          |

Ожидаемая цена двух чипов — сумма одиночных: ~4,2 с в один поток, ~0,57 с в девять.

## Результат

- В один поток два чипа на ~40% дороже суммы: пересоздание движка на каждой записи
  (`enforceMalloc` + `GC.addRange`, `GC.removeRange` + `free`).
- С потоками время **растет** (в 25 раз дольше ожидаемого на девяти): `GC.addRange` /
  `GC.removeRange` берут глобальный замок GC, и потоки стоят в нем.
- Разброс на 9 потоках большой (14,0–16,0 с): очередь за замком.

## Решение

Задуманное в бэклоге «матчер на выражение в блоке» Phobos не позволяет: движки
(`Matcher`, `rearm`, фабрики) объявлены `package(std.regex)`, а у `RegexMatch` нельзя сменить
вход. Варианты и выбор — в `docs/backlog.md` (раздел о параллельном скане).
