---
name: review-rules
description: Review the current change of DLT Explorer against the repository's rules (.ai/rules Red Flags, boundaries, i18n, tests, docs) with the rules-reviewer agent. Use when the user asks to check a change against the project rules, or before a merge of a feature branch.
argument-hint: "[range, commit or paths; default: the branch against master plus uncommitted changes]"
---

Launch the `rules-reviewer` agent (Agent tool, `subagent_type: "rules-reviewer"`) to review the
change: $ARGUMENTS (empty: the default scope of `.ai/workflows/review.md`).

Pass the scope in the prompt and ask for the report in the user's language. When it returns,
relay its findings to the user as they are, then say which ones you would fix and which you
would decline, with a reason each. Don't fix anything until the user asks.
