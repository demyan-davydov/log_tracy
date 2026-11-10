# DLT Explorer AI Context Index

## Overview

This is the entrypoint of the repository's shared context, written for developers and agents
alike. `AGENTS.md` points here and also holds the few facts every session needs (commands,
package layering, conventions); `CLAUDE.md` only imports it for Claude Code.

- `.ai/knowledge/`: orientation — how the code is built and where to start for a change.
- `.ai/rules/`: binding rules for every code change and every review.
- `.ai/workflows/`: recurring processes end to end (the git flow, a review by lenses,
  adding a format or a backend call, updating Sciter, a screenshot of the app). In Claude Code
  most of them are skills too (`.claude/skills/`).

Read the indexes, then only the files the task touches. Do not load every file by default.

## Start Here

1. `.ai/knowledge/INDEX.md`: the map of the code and the context files.
2. `.ai/rules/INDEX.md`: before writing or reviewing code.
3. `.ai/workflows/INDEX.md`: when the task is one of its processes.

## Keeping It Up to Date

- A change that moves a responsibility, adds a module or an extension point updates the
  knowledge file of its area in the same change.
- A general requirement stated by the user (not a one-off fix) goes into the rules at once:
  UI and UX ones into `.ai/rules/ux.md` (see there). A requirement that contradicts a rule is
  asked about before acting, then the rule is updated.
- A Sciter behaviour found the hard way goes into `.ai/knowledge/sciter.md`.
- Documentation for people stays in `docs/` (English), the stories of features in
  `docs/stories/` and what was left for later in `docs/backlog.md` (Russian).
