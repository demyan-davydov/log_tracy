# Performance baseline

Reference numbers of `master` to compare a change against. Measure the change and `master` on
the same machine and log, one right after the other: the absolute numbers depend on both.

## How to measure

`node scripts/build.mjs bench <log> failed value` does all of the below for a branch against
`master` in one command (`docs/building.md`, "Measuring"); by hand:

`scripts/bench_rows.d` loads a log, then fetches every row of the main view the way the table does
when it scrolls. It does this without a search and with each search given on the command line,
and it also fetches the rows of the search view. After each step it prints the memory of the
process. It builds against older checkouts too, so the same file measures `master` (copy it into
a `master` worktree) and a branch:

```sh
ldc2 -O3 -release -enable-inlining -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
    scripts/bench_rows.d -of=/tmp/bench_rows
/tmp/bench_rows <log> failed value
```

- Each fetch figure is the best of 5 passes over all the rows, in ns per row. The first load reads
  the file from disk; later runs find it in the page cache. Run the benchmark three times and
  take the steady numbers.
- **Footprint** is what Activity Monitor shows: the memory of the process itself, without the
  clean pages of the mapped log. **Resident** includes those pages: about the size of the file
  once every row was read.
- The script and Sciter are not measured: this is the backend's part of a row only.
- `scripts/bench_index.d` measures how the indexes build (offset, filter, search) in more detail.

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

## Jumps in the log table: `scroll-window` (2026-11-11)

A far jump (`vlist.navigateTo(n)` and the layout of its rows) in a table ~484 px high, debug
build, Apple M1 Pro; how it was measured: `docs/experiments/2026-11-11-scroll-window.md`.

| Jump | master (window 160) | `scroll-window` (window by height) |
|---|---|---|
| far row, log of 4.5 M records | ~150 ms | ~35–45 ms |
| End, log of 85 M records | ~240 ms (483 rows) | ~38 ms |

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
