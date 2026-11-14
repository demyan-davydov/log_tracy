---
name: app
description: Drive a running debug copy of Log Tracy through its debug channel (scripts/utils/app.mjs): run JavaScript in its window, wait for a state, read elements and their geometry, render the window, run a scenario of steps. Use to check every state of a UI change, reproduce a UI bug, or look inside the window instead of guessing from a screenshot; not for simple CSS tweaks the user checks themselves.
argument-hint: "[log path] [what to check]"
---

Drive the app: $ARGUMENTS

1. Read `.ai/workflows/preview-ui.md` (When, Driving the App).
2. `node scripts/utils/app.mjs start --open <log>` with the log given, or a local log of `test_data/`
   if none is given; a theme, a language or a window size goes into a `settings.json` written
   for it in the scratchpad (`--settings`).
3. `wait` for the state, then `eval` what is asked; `shot` and read the PNG when the look
   matters; `hover`, `key`, `type` for the real mouse over an element and keys (macOS).
   Several steps: a steps file in the scratchpad and `run`.
4. `node scripts/utils/app.mjs stop` when done, and say what was checked and what couldn't be (a
   press of a mouse button, mouse focus, Sciter's `title` tooltip).
