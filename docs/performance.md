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
