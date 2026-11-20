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

## Text of the painted table: line layouts against word runs, in the app (2026-11-20)

Three release builds with the debug channel (`node scripts/build.mjs --release --debug-channel`), one fresh process
per log, the same `settings.json` and window (1463×1059, light theme, font 100 %, search panel 374 dip):

- **old**: `row-paint-d-review` at `df74ca0`: one Sciter layout per line, a match, the selection and the caret placed by
  measuring the start of the line up to them; the widths and layouts limited by count only.
- **runs**: `row-paint-d-word-runs` at `2c772f8`: a line cut into runs (a word and the spaces after it,
  `ptable_text/runs`), each its own layout, only the visible ones drawn; places summed from the widths of the runs.
- **runs + generations**: the same with both Sciter caches on `ui/sciter_table/generations` (two generations bounded by
  count: the widths 300 000, the layouts 6000).

Driven by `scripts/utils/app.mjs eval` through `logTableCall`: `scrollBy(px, 1)`, `jump(row, 1)` and `pan` force a
frame each. **draw** is the table's own paint (`stats`: `medianUs`, `p90Us`, `maxUs`); the whole forced update is
held to the display's refresh (~8.3 ms at 120 Hz), so of it only the slow frames above that say something. **made**:
layouts made during the step (`textsMade`). Memory: `ps` RSS and `footprint`'s `phys_footprint` after the step.

- **Machine:** Apple M1 Pro, 32 GB, macOS 27.2; LDC 1.43.0; Sciter 6.0.5.5.
- **Logs:** the user's `Case2.dlt` (45 MB DLT, not in the repository) with the filter set `speech.dlf` on (4 889 rows) and a
  search of four chips (`apiData`, `c4a94898-6769-4257-a860-3ecdf93b0af7`, `SILENT_DIALOG_CONTINUATION`,
  `handle (stream10`; 232 rows found); `test_data/exotic/logcat-threadtime-long-payload-many-words.log` and
  `...-one-word.log` (`test_data/_make/make-text-samples.mjs`: 120 records, 40 of ~60 KB payload), a search of
  `timeout` and `0xDEADBEEF` (near the end of the long payloads).

Times in ms: draw median / p90 / max, one run of each. runs + generations equals runs within the noise (the same layouts
made; no working set here reaches the old limit of 100 000 widths), at most ~3 % slower at the right end of the long lines.

| Scenario | old | runs | runs + generations | made old / runs / + generations |
|---|---|---|---|---|
| Case2, search table, wrapped, 300 × 150 px | 1.2 / 1.9 / 2.9 | 1.6 / 2.6 / 3.4 | 1.6 / 2.6 / 3.5 | 1358 / 1379 / 1379 |
| Case2, main table, wrapped, 300 × 200 px | 2.4 / 3.0 / 3.7 | 3.0 / 4.3 / 13.1 | 3.0 / 4.4 / 13.9 | 5332 / 6247 / 6247 |
| Case2, search table, single line, 200 × 60 px | 1.0 / 1.9 / **394** | 0.9 / 1.6 / 62 | 1.0 / 1.7 / 65 | 309 / 294 / 294 |
| Case2, main table, single line, 300 × 200 px | 3.3 / 4.3 / **296** | 3.4 / 4.5 / 49 | 3.6 / 4.8 / 48 | 5749 / 7315 / 7315 |
| many words, wrapped, from row 10, 400 × 300 px | 3.0 / 3.4 / 40 | **7.7 / 9.0** / 24 | **7.8 / 9.1** / 25 | 6984 / 31432 / 31432 |
| many words, single line, right end, rows ±20 px × 120 | 19.6 / 114 / 223 | 33.2 / 58.6 / 105 | 34.0 / 61.6 / 109 | 63 / 114 / 114 |
| many words, single line, right end, across ±40 px × 180 | 19.2 / 19.5 / 19.8 | **32.6 / 33.6** / 38 | **33.6 / 34.2** / 36 | 0 / 189 / 189 |
| one word, wrapped, from row 10, 400 × 300 px | 2.1 / 2.4 / 29 | 3.5 / 3.7 / 29 | 3.4 / 3.7 / 32 | 7011 / 7012 / 7012 |
| one word, single line, right end, rows ±20 px × 120 | **65.6 / 104 / 194** | 14.9 / 37.7 / 68 | 15.4 / 38.4 / 68 | 63 / 46 / 46 |
| one word, single line, right end, across ±40 px × 180 | **65.0** / 65.4 / 69 | 14.4 / 14.7 / 15 | 14.7 / 15.0 / 15 | 0 / 6 / 6 |

The first frame with found cells (a jump to a row not drawn yet, the whole forced update, median / max of 10 rows):

| Jump | old | runs | runs + generations |
|---|---|---|---|
| Case2, search table, wrapped | 8.0 / 11.9 | 8.2 / 16.4 | 8.2 / 12.9 |
| many words, wrapped, rows 10–46 | 8.2 / 8.3 | **18.3 / 20.0** (1490 layouts made, old 344) | **17.8 / 19.8** (1490) |
| many words, single line, right end, rows 10–46 | 31 / **226** | 53 / 93 | 56 / 93 |
| one word, single line, right end, rows 10–46 | **153 / 224** | 24 / 70 | 24 / 68 |

Memory, RSS / footprint in MB after the single-line steps (opened: 130–180):

| Log | old | runs | runs + generations |
|---|---|---|---|
| Case2 | 617 / 540 | 447 / 375 | 446 / 376 |
| many words | **1465 / 1551** | 316 / 320 | 316 / 319 |
| one word | 819 / **1289** | 472 / 392 | 468 / 389 |

What it says:

- **Runs remove the stalls and the memory of the long lines:** the old single-line view stopped for 0.3–0.4 s on
  Case2 and up to 0.23 s on the long payloads, and took up to 1.5 GB (a layout of a whole 60 KB line, and its
  prefixes measured); runs stay under 0.1 s and 0.5 GB.
- **Runs cost more where lines have many short words:** the wrapped view of the many-words log draws 2.5 times
  longer (7.7 against 3.0 ms; 31 432 layouts made against 6 984: a layout per word) and its first frame with found
  cells takes 18 ms instead of 8.
- **At the right end of long lines of many words a frame of runs is 33 ms against 19.** A `sample` of it: of 1289
  samples of the paint, 1180 in `TextColumn.drawBack` itself, 554 in `Generations.find` (the widths of runs), 250 in
  `TextPattern.findLowered`: each frame sums the widths of every run from the start of the line to place the
  matches, and finds the matches in the whole line again. Laying out and drawing the text are a small part. The
  sums per line (docs/backlog.md, "текст рисуется словами") are what to do next there.
- **The two generations change nothing measurable here:** the same layouts made, the same frames and memory. They
  bound what the old `WidthCache` emptied whole and what moves grew past its limit in the old layout cache; these
  logs repeat their words, so the widths kept stay far under 100 000.

### Marks of long lines kept with the rows (2026-11-20)

**runs + marks**: the same as runs + generations, and a long line (1024 units or more) keeps a mark (a place, its x)
every `markEvery` runs in a memo of its cell (`ptable/cellmemo`), kept for the rows near the window in the ring of
`RowGeometry`'s size and let go with them. A frame walks from the last mark before what it looks for (the first run
seen, a match, a point of the mouse) instead of from the start of the line. Measured as above, the same day; times in
ms, draw median / p90 / max.

| Scenario | runs + generations | runs + marks, every 64 | every 16 | every run |
|---|---|---|---|---|
| many words, single line, right end, across ±40 px × 180 | 33.6 / 34.2 / 36 | **7.4 / 8.0 / 8.5** | 7.2 / 7.8 / 8.1 | 7.3 / 7.9 / 8.6 |
| many words, single line, right end, rows ±20 px × 120 | 34.0 / 61.6 / 109 | 8.2 / 37.5 / 78 | 8.1 / 36.8 / 79 | 7.6 / 36.6 / 79 |
| many words, single line, right end, jumps (median / max) | 55.7 / 92.6 | 15.7 / 66.9 | 15.1 / 67.0 | 15.1 / 67.9 |
| one word, single line, right end, across ±40 px × 180 | 14.7 / 15.0 / 15 | 8.2 / 8.6 / 9.0 | 6.5 / 6.8 / 7.2 | 5.9 / 6.1 / 6.3 |
| one word, single line, right end, rows ±20 px × 120 | 15.4 / 38.4 / 68 | 9.3 / 34.4 / 61 | 7.7 / 32.7 / 61 | 6.5 / 31.5 / 59 |
| one word, single line, right end, jumps (median / max) | 24.3 / 68.3 | 15.1 / 62.3 | 12.7 / 61.4 | 11.1 / 60.3 |
| many words, wrapped, from row 10, 400 × 300 px | 7.8 / 9.1 / 25 | 8.5 / 10.0 / 26 | 8.5 / 10.0 / 26 | 7.9 / 9.1 / 25 |
| Case2, main table, single line, 300 × 200 px | 3.6 / 4.8 / 48 | 3.5 / 4.8 / 47 | — | — |

Memory after the single-line steps (RSS / footprint, MB): many words 316 / 319 → 316 / 316 (every 64), 319 / 321
(every 16), 327 / 331 (every run); one word 468 / 389 → 465 / 376, 468 / 377, 468 / 388; Case2 446 / 376 → 446 / 372.

- **At the right end of long lines a frame is 4–5 times cheaper** and cheaper than the old line layouts too (19 ms
  with many words, 65 with one word). The first frame of a line not walked yet (rows scrolled in, a jump) still sums
  it from the start: the p90 and the maximum of those steps hardly move.
- **The spacing is an experiment:** the columns of 16 and of every run are builds made only to compare; the code marks
  every 64 runs. **Kept at 64** (the user's decision, 2026-11-20): the speed differs little, and the memory of the
  marks grows with their number: a mark is 16 bytes (a place and an x), so a line of 60 KB (~6000 runs) keeps ~1.5 KB
  of marks at 64 and ~96 KB at every run; the ring keeps up to four windows of rows, up to four long cells each.
- **The spacing of the marks matters little:** every 16 runs is a little faster than every 64 on the one-word log
  (its runs are long words cut at 256 units, each a long key of the width cache), every run a little more again,
  for ~10 MB more at the many-words log. The memory of the marks is within the noise at 64 and 16.
- **The rest of such a frame is the content of the rows:** a `sample` (every 64) has `TextPattern.findLowered` (593
  samples) and `copyUtf8toTu` (552) on top, then `TextCell.drawText` (173) and `TextColumn.drawBack` (155) themselves:
  each pass decodes the 60 KB payloads of the rows on the screen again and finds the search's matches in them again.
  The widths and the runs (`Generations.find` 13, `eachRun` 11) are gone from the top.

### Words and gaps as runs of their own (2026-11-20)

**runs + gaps**: runs + marks (every 64), and a run is a word or a gap (spaces, or tabs) instead of a word with the
spaces after it; the gaps are drawn too, a tab as a space; a long word is cut only between two characters. Measured as
above, the same day; draw median / p90 / max in ms.

| Scenario | runs + marks | runs + gaps | made |
|---|---|---|---|
| many words, single line, right end, across ±40 px × 180 | 7.4 / 8.0 / 8.5 | 8.3 / 8.8 / 9.4 | 189 / 169 |
| many words, single line, right end, rows ±20 px × 120 | 8.2 / 37.5 / 78 | 8.7 / 36.9 / 78 | 114 / 108 |
| many words, wrapped, from row 10, 400 × 300 px | 8.5 / 10.0 / 26 | 8.7 / 9.9 / 28 | 31 432 / 31 432 |
| many words, wrapped, first frame with found cells (median / max) | 17.8 / 20.3 | 19.7 / 21.7 | 1490 / 1490 |
| one word, single line, right end, across ±40 px × 180 | 8.2 / 8.6 / 9.0 | 8.4 / 8.7 / 9.1 | 6 / 6 |
| Case2, main table, single line, 300 × 200 px | 3.5 / 4.8 / 47 | 3.7 / 5.0 / 48 | 7315 / 7314 |
| Case2, main table, wrapped, 300 × 200 px | 3.0 / 4.4 / 16 | 3.1 / 4.5 / 16 | 6247 / 6251 |

Memory within the noise (many words 316 / 316 → 312 / 320 MB, Case2 446 / 372 → 445 / 368). The layouts made stay
the same (a gap of one space is one key for all the lines); a frame of many words costs ~10 % more, the drawing of the
gaps: twice the runs to draw, of which half put nothing on the screen.
