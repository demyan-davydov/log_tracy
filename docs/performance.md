# Performance baseline

Reference numbers of `master` to compare a change against. Measure the change and `master` on
the same machine and log, one right after the other: the absolute numbers depend on both.

## How to measure

`node scripts/build.mjs bench <log> failed value` does all of the below for a branch against
`master` in one command (`docs/building.md`, "Measuring"); by hand:

`scripts/utils/bench_rows.d` loads a log, then fetches every row of the main view the way the table does
when it scrolls. It does this without a search and with each search given on the command line,
and it also fetches the rows of the search view. After each step it prints the memory of the
process. It builds against older checkouts too, so the same file measures `master` (copy it into
a `master` worktree) and a branch:

```sh
ldc2 -O3 -release -enable-inlining -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
    scripts/utils/bench_rows.d -of=/tmp/bench_rows
/tmp/bench_rows <log> failed value
```

- Each fetch figure is the best of 5 passes over all the rows, in ns per row. The first load reads
  the file from disk; later runs find it in the page cache. Run the benchmark three times and
  take the steady numbers.
- **Footprint** is what Activity Monitor shows: the memory of the process itself, without the
  clean pages of the mapped log. **Resident** includes those pages: about the size of the file
  once every row was read.
- The script and Sciter are not measured: this is the backend's part of a row only.
- `scripts/utils/bench_index.d` measures how the indexes build (offset, filter, search) in more detail.

## master at 86a26ac (2026-11-09)

- **Machine:** Apple M1 Pro, 10 cores, 32 GB, macOS; LDC 1.43.0, release build.
- **Log:** a DLT recording of a RichOS ECU, 481 745 787 bytes, 2 315 001 records (SHA-256
  starts with `5d040061a51877cd`). It is not in the repository; any log of a similar size and
  kind will do, as long as both sides are measured on the same one.
- **Searches:** `failed` matches 106 442 records (4.6 %); `value` matches 183 462 records
  (7.9 %).

| Step | Time | Footprint | Resident |
|---|---|---|---|
| start | | 1.3 MB | 2.7 MB |
| load (offset index) | 577 ms cold, 72 ms cached | 19.3 MB | 480 MB |
| search `failed` | 83–87 ms | 23.2 MB | 484 MB |
| search `value` (after `failed`) | 81–85 ms | 27.0 MB | 488 MB |

| Rows fetched | ns per row |
|---|---|
| main view, no search | 183 |
| main view, search `failed` | 183–184 |
| main view, search `value` | 183–184 |
| search view of `failed`, with the fragments of the chips | 132–133 |
| search view of `value`, with the fragments of the chips | 305–307 |

The footprint stays the same after the rows are fetched: fetching allocates nothing that stays. The
fragments of the chips are allocated by the GC, which reuses that memory.

## Indexes built by passes: `live-results` against master at 8947570 (2026-11-10)

`LogIndex` builds its indexes by passes over ranges since `live-results`
(`docs/stories/live-results.md`). A stage that runs alone (a filter or a search over a loaded
file) is still one scan, and costs the same:

```sh
node scripts/build.mjs bench --bench index --against master
```

- **Machine:** Apple M1 Pro, 10 cores, macOS; LDC 1.43.0, release build.
- **Log:** the one the generator writes (DLT, 256 MB, seed 1), query `error`; median (spread)
  of 3 runs a side, by turns, each number the best of its rounds.

| Step | master | `live-results` | Difference |
|---|---|---|---|
| offset index | 41.7 ms (40.3–50.3) | 41.8 ms (41.6–51.9) | +0.2 %, noise |
| filter | 61.8 ms (59–66.1) | 60.8 ms (60.7–61.1) | −1.6 %, noise |
| search | 61.5 ms (60.8–61.9) | 60.2 ms (60–61.3) | −2.1 %, noise |

Not measured by a benchmark: stages that follow each other (a filter or a search running with
the load, a search with a filter), where a stage takes `LogIndex.followRecords` records at a
time. In the app (debug build, the 1 GB log of the generator, 8.9 M records): a search after
the load ~1.5 s (~1.6 s before), a filter ~1.15 s (~1.25 s before), a search started at a third
of the load ends with it, ~2.3 s after it was asked for. See `docs/backlog.md` for what is
left to measure.

## Joined parts of DLT messages: `joined-parts` against master at 7063709 (2026-11-11)

The offset index asks every record of a DLT log whether it is a numbered part of a message
(`docs/stories/joined-parts.md`). A log without parts pays for the question only:

```sh
node scripts/build.mjs bench <log> --bench index --against master
```

- **Machine:** Apple M1 Pro, 10 cores, macOS; LDC 1.43.0, release build.
- **Logs:** written by the generator, 256 MB, seed 1, no parts; query `error`; median (spread)
  of 3 runs a side, by turns, each number the best of its rounds.

| Log | Step | master | `joined-parts` | Difference |
|---|---|---|---|---|
| `dlt` (2 235 643 records) | offset index | 41.8 ms (41.7–42.4) | 60.3 ms (59.6–62.9) | +44 %, ~8 ns a record |
| `dlt-v2` (2 017 236 records) | offset index | 46.8 ms (46.5–54.2) | 64.5 ms (64.4–64.9) | +38 %, ~9 ns a record |

The filter and the search don't change (within the noise). On a log of 1 GB the load takes
about 80 ms more.

## Frames of the painted table: `row-paint-d` before and after one pass a frame (2026-11-20)

`scripts/utils/bench_ptable.d` (`node scripts/test.mjs --module scripts/utils/bench_ptable.d`): a table of
1200×900 over a synthetic log of 200 000 rows, the log's columns, a measurer that walks the text
(no Sciter: the drawing of the text is not in it), 30 rows on the screen. A unittest build, not
optimized: only the comparison means something. The third round of 400 frames.

- **Machine:** Apple M1 Pro, macOS; LDC 1.43.0.

| Frame | before | after |
|---|---|---|
| a jump and a frame | 347 us | 347 us |
| the wheel's glide (`wheel`, `tick`, `paint`) | 240 us, 51 rows read | 229 us, 30 rows read |
| a scroll by pixels (`queueScroll`, `paint`) | 254 us, 31 rows read | 253 us, 31 rows read |
| the same rows drawn again (`repaint`, `paint`: a hover) | — | 155 us |
| two tables of one column host, A scrolled: a frame of A | 382 us, B reads 30 rows | 268 us, B reads none |

Before, every `prepare` of a frame began a pass, so a tick and the paint after it read the rows
twice, and the table that stood read and measured its rows on every frame of the other. A pass is
a frame now, and a table whose window did not move gives the column host what it measured last.

## A compact offset index: `compact-index` against master at 7ad63f9 (2026-11-23)

The offset index keeps 4 bytes a record instead of 8 (`CompactOffsets`, `domain/index/offset_index`):
a block of 4096 records keeps its first offset once, a record its distance from it.

```sh
node scripts/build.mjs bench --bench index --against master
node scripts/build.mjs bench --against master
```

- **Machine:** Apple M1 Pro, 10 cores, macOS; LDC 1.43.0, release build.
- **Log:** written by the generator, DLT, 256 MB, seed 1 (about 2.2 M records); median (spread)
  of 3 runs a side, by turns.

| Step | master | `compact-index` | Difference |
|---|---|---|---|
| offset index | 72 ms (62–73.2) | 64.4 ms (63.2–75.6) | noise |
| filter `error` | 58.4 ms (58.2–59.5) | 59.2 ms (58.4–59.8) | noise |
| search `error` | 59.4 ms (59.4–60) | 59.3 ms (59–59.4) | noise |
| main view, no search | 127.1 ns a row | 127.1 ns a row | noise |
| search `failed`, main view, rows only | 164.1 ns a row | 163.2 ns a row | -0.5 % |
| footprint after loading | 18.7 MB | 10.2 MB | -45.5 % |
| footprint after search `failed` | 23.2 MB | 14.7 MB | -36.6 % |

The extra read of a block's start costs nothing measurable. On a log of 85 M records the offset
index takes about 340 MB instead of about 680 MB (by the arithmetic: not measured on such a log).

The same on the real RichOS log of the first section (481 745 787 bytes, 2 315 001 records;
`bench <log> --bench index` and `bench <log>`, against master at 7ad63f9, 3 runs a side):

| Step | master | `compact-index` | Difference |
|---|---|---|---|
| offset index | 94.6 ms (94.5–95.8) | 96.3 ms (95.6–103.4) | noise |
| records loaded | 91.3 ms (91.2–104.3) | 93.7 ms (93.5–105.3) | noise |
| filter `error` | 113.1 ms (112–113.9) | 111.8 ms (111.6–114.5) | noise |
| search `error` | 112.1 ms (112–114.6) | 112.1 ms (112.1–113.8) | noise |
| main view, no search | 200.5 ns a row | 201.6 ns a row | noise |
| search `failed`, main view, rows only | 224.9 ns a row | 225.1 ns a row | noise |
| search view of `failed`, with fragments | 104.1 ns a row | 104.0 ns a row | noise |
| footprint after loading | 20.1 MB | 11.4 MB | -43.3 % |
| footprint after search `failed` | 23.1 MB | 14.5 MB | -37.2 % |
| footprint after search `value` | 23.5 MB | 14.8 MB | -37.0 % |
| resident after loading | 481.2 MB | 472.5 MB | -1.8 % |

8.7 MB less for 2.3 M records: 4 bytes a record, as expected. The resident memory holds the
pages of the mapped log, as big as the file, which the OS drops for free; the footprint is the
memory it can't.
