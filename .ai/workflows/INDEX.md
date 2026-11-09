# DLT Explorer Workflows Index

## Overview

Each file describes one recurring process end to end, for developers and agents alike. Load a
workflow only when the task is that process. In Claude Code most of them are skills too
(`.claude/skills/`, named in brackets), the review runs in its own agent
(`.claude/agents/rules-reviewer.md`); the skills only point here.

## Workflows

- Branches, commits, merges, stories, and what an agent does on its own: `.ai/workflows/git.md`
- Reviewing a change against the rules of the repository: `.ai/workflows/review.md`
  (`/review-rules`)
- Adding a log format or a variant: `.ai/workflows/add-format.md` (`/add-format`)
- Adding a call from the script to the backend, or a file to `resources/`:
  `.ai/workflows/add-backend-call.md` (`/add-backend-call`)
- Updating the Sciter library: `.ai/workflows/update-sciter.md` (`/update-sciter`)
- A screenshot of the app, a dialog in scapp, driving the app:
  `.ai/workflows/preview-ui.md` (`/screenshot`)
