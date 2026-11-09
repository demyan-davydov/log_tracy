# Git Workflow

## Branches

- The main branch is `master` (there is no `main`, whatever the tooling says). Branches start
  from it, merges and pull requests target it.
- A feature goes on its own branch, named after the feature, and is merged into `master` with
  `--no-ff`.
- A small one-off fix (one commit, no story, nothing to follow) is committed straight on
  `master`. When unsure whether a fix is small, ask.
- To bring `master` into a feature branch the usual way is a rebase of the branch onto
  `master`, not a merge: the branch history stays linear before its `--no-ff` merge.

## Commits

- Subjects are short, lower-case and imperative ("grow the indexes by chunks instead of ...").
- On a feature branch every subject starts with the feature's name and a colon:
  `i18n: add the core of translations`. A side branch of a feature (`i18n-simplify`) takes the
  feature's name. Commits straight on `master` have no prefix; merge commits read
  `merge <branch>: <what the feature does>`.
- A Sciter update replaces `libs/` and `libs/VERSION` in one commit
  (`.ai/workflows/update-sciter.md`).

## A Feature, End to End

1. Branch from `master`.
2. Tests first (`.ai/rules/tests.md`), then the code; `node scripts/build.mjs test` passes.
3. The story in `docs/stories/<feature>.md` (Russian): what and why, what was tried and
   rejected. What is left for later goes to `docs/backlog.md`.
4. Docs for people (`docs/`, English) and `.ai/` updated where the feature changes them
   (`.ai/rules/docs.md`).
5. The user checks the result, then it is merged into `master` with `--no-ff`.

## Agent Boundaries

- Commit only when the user explicitly says to commit. A confirmation that the change works or
  looks fine is not a request to commit; when the user says they will check a change, leave it
  uncommitted.
- When asked to merge `master` into a branch, first ask whether a rebase onto `master` is
  meant.
- Don't push, tag, delete branches or rewrite published history unless asked.
- Don't modify or merge a branch that was parked (see `docs/backlog.md`) unless the user
  brings it up.
