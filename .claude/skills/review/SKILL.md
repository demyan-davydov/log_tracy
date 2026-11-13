---
name: review
description: Review the current change of Log Tracy by lenses (rules, architecture, performance and threads, UX), each in its own reviewer agent, chosen by the files the change touches, and join their reports. Use when the user asks to review a change against the project, or before a merge of a feature branch. Complements /code-review (bugs), doesn't replace it.
argument-hint: "[lens names: rules, architecture, performance, ux] [range, commit, paths or a plan file; default: the branch against master plus uncommitted changes]"
---

Review the change by lenses: $ARGUMENTS

1. Read `.ai/workflows/review.md`.
2. Lenses named in the arguments are the ones to run. Otherwise run
   `node scripts/review-lenses.mjs` (or with the base given) and take its `lenses`; if it
   lists no files, say there is nothing to review and stop.
3. Launch one agent per lens **in parallel** (one message, several Agent calls):
   `rules` → `rules-reviewer`, `architecture` → `architecture-reviewer`,
   `performance` → `performance-reviewer`, `ux` → `ux-reviewer`. Give each the scope (the
   default, or the one in the arguments) and ask for the report in the user's language. A plan
   (a file or text, no code yet) goes to `architecture-reviewer` only, unless lenses are named.
4. Join the reports as `.ai/workflows/review.md` says (Joining the Lenses): Red Flags on top,
   then by lens, a finding two lenses made kept once.
5. Say which findings you would fix and which you would decline, with a reason each. Don't fix
   anything until the user asks.
