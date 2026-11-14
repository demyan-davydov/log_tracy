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

- All tests: `node scripts/test.mjs` (= `build.mjs test`; D unittests, "N modules passed unittests", and
  the JS tests). JS only: `node --test "tests/js/*.test.mjs"` (node 22 takes no folder).
- The druntime test runner has no filter, and it stops a module's tests at the first failing
  `unittest` block: when one module gets several new tests, check each of them separately.
- One module that doesn't depend on Sciter: `node scripts/test.mjs --module <file.d>`.
- An agent runs them with `--brief` (`build`, `test`, `test --module`, `dist`,
  `run.mjs`): one summary line when all pass, else the compile errors and
  failed tests with their places. The whole output is in `build/brief.log`: read it when the
  brief lines don't explain a failure.
- `build.mjs test` also runs `scripts/utils/check-ai-context.mjs`: a name of `.ai/` the code lost
  fails it. Fix the name, or add a right one to the `allowed` list of the script.

## What Gets Tested

- The logic lives where it can be tested: Sciter-free D modules (`ui/app_session`,
  `ui/filter_commands`, the state machines) and Sciter-free script modules under `tests/js`.
- Keep tests deterministic: control clocks, randomness and external effects.
- DLT records for tests: `formats/dlt/testing_utils`. Tests never depend on `test_data/`: its
  logs are local, not in the repository. A whole log for a manual check or a benchmark:
  `node scripts/build.mjs gen-log` (same file for the same options and seed).
- Performance claims are measured, not guessed (`scripts/utils/bench_rows.d`,
  `scripts/utils/bench_index.d`, results in `docs/performance.md`): a branch against `master` with
  `node scripts/build.mjs bench`.
