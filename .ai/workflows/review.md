# Reviewing a Change by Lenses

A review of a diff by the knowledge of this repository: what a general bug hunt
(`/code-review`) doesn't know. It complements a correctness review, it doesn't replace one. It
reports, it doesn't fix.

The review is split into lenses. Each lens has one question, its own checklist and runs with a
fresh context: a narrow question is answered more deeply than "anything wrong?".

| Lens | File | Question | When |
|---|---|---|---|
| rules | `review-rules.md` | Does the change follow the rules of the repository? | every change |
| architecture | `review-architecture.md` | Is each responsibility in its place, through the existing extension points, no more complex than needed? | a change across packages or of `app.d` / `dub.sdl`; a plan of a feature, before the code |
| performance | `review-performance.md` | Is it fast enough for a 1 GB log, and safe across the threads? | the indexing, formats, filters, the rows of the log table |
| ux | `review-ux.md` | Does it behave and look as the user's requirements say? | what the user sees and does |

`node scripts/review-lenses.mjs [base]` names the lenses a change needs by its files (and lists
the files). A lens can also be asked for by name.

When: before the merge of a feature, and on request when a change touches the threads or the
interface. Not on every commit: a lens costs 40–90 thousand tokens. `/code-review` (bugs of
logic and state) is a different review, run as well: compared on three features, the two
overlapped by about a third, each finding real issues of its own kind
(`docs/experiments/2026-11-09-review-lenses-vs-code-review.md`).

The architecture lens is the one worth running on a plan too, before the code: what it finds
after the code is often a rework. Not a lens (yet): acceptance (was the asked thing done), at
the end of a feature. See `docs/backlog.md`.

## Scope

- By default the work of the current branch: `git diff master...HEAD` plus the uncommitted
  changes (`git diff HEAD`) and the untracked files. On `master`: the uncommitted changes only.
  A range, a commit or paths given explicitly replace the default. The architecture lens also
  takes a plan (a file or the text of the task), reviewed against the code as it is.
- Read every changed hunk and, where the lens is about it, the code around it and its callers.

## Report of a Lens

- One entry per finding: `file:line`, what breaks and when (a concrete input, timing or
  scenario), and the rule or checklist item it falls under (file and a short quote).
- Red Flags first, then the order of the lens's checklist.
- Mark how sure the finding is: **confirmed** (traced in the code) or **suspected** (needs a
  measurement, a run or the author's knowledge).
- What was checked and found fine is one line, not a list. Nothing found is a valid result.
- No edits: the person or agent who asked decides what to fix.

## Joining the Lenses

When several lenses ran, their reports are joined into one: findings grouped by lens, a finding
two lenses made kept once (under the lens it matters most to), Red Flags of every lens on top.
