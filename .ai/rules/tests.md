# Test Rules

## Scope

Applies to every fix and feature, D and script alike.

## Tests First

- Write the test, run it and see it fail for the right reason, then change the code and show
  it passes. A test that never failed proves nothing.
- For new code start from a compiling stub so the test fails at run time, not at compile time.
- If a test can't fail before the change (a regression guard for a refactor), say so instead
  of claiming it failed.
- Report the failure before and the pass after.

## Running

- All tests: `node scripts/test.mjs` (= `build.mjs test`; D unittests, "N test(s) run, 0 failed.",
  the JS tests and the names of `.ai/`); a plain `dub test` runs the same. JS only:
  `node scripts/utils/test-js.mjs` (one line when they pass; `--verbose` a line per test).
- `dub test` runs unit-threaded's runner in one thread: each `unittest` block is a test of its
  own, a failed one doesn't stop the ones after it.
- Some tests: `node scripts/test.mjs --filter <name>` (repeatable): the D unittests whose names
  start with it (a module, `utils.fsm`, or a test's full name) and the JS tests whose names
  contain it. `dub test --compiler=ldc2 -- <name>` filters the D ones only: its hooks run the
  JS tests whole.
- One module that doesn't depend on Sciter: `node scripts/test.mjs --module <file.d>`. It runs
  druntime's runner: no filter, a module's tests stop at the first failing `unittest` block.
- An agent runs them with `--brief` (`build`, `test`, `test --filter`, `test --module`, `dist`,
  `run.mjs`): one summary line when all pass, else the compile errors and
  failed tests with their places. The whole output is in `build/brief.log`: read it when the
  brief lines don't explain a failure.
- `build.mjs test` also runs `scripts/utils/check-ai-context.mjs`: a name of `.ai/` the code lost
  fails it. Fix the name, or add a right one to the `allowed` list of the script.

## Names and Output

- Every D `unittest` has a name: `@("<subject>: <what it checks>")` on the line before it, the
  subject the function or type tested (`parseKeyPress: modifiers by their names, in any case
  and order`), one subject: `--filter` matches the start of the name. The runner reports a
  failed test and filters by this name; a comment or a `///` above the test is no name, and a
  test without one is `<module>.unittest_L<line>`. A JS test fails on an unnamed one
  (`scripts/utils/d-test-names.mjs`).
- A test prints nothing: no `writeln` of the test's name or of "finished", no values for a
  look. The runner names the failed test; what a failure needs to explain goes into the
  message of its `assert`.

## What Gets Tested

- The logic lives where it can be tested: Sciter-free D modules (`ui/app_session`,
  `ui/filter_commands`, the state machines) and Sciter-free script modules under `tests/js`.
- Keep tests deterministic: control clocks, randomness and external effects.
- An allocator a test counts with (`StatsCollector`) whose address goes to an object of the GC
  (`allocatorObject(&stats)` given to a class, or to a struct inside one) is `static`, reset at
  the start of the test: the object is finalized later, and its frees, counted in `stats`, would
  write into the stack frame of whatever test runs then. Once it gave SIGBUS and wrong values in
  other tests that came and went with the order of the tests.
- DLT records for tests: `formats/dlt/testing_utils`. Tests never depend on `test_data/`: its
  logs are local, not in the repository. A whole log for a manual check or a benchmark:
  `node scripts/build.mjs gen-log` (same file for the same options and seed).
- Performance claims are measured, not guessed (`scripts/utils/bench_rows.d`,
  `scripts/utils/bench_index.d`, results in `docs/performance.md`): a branch against `master` with
  `node scripts/build.mjs bench`.
