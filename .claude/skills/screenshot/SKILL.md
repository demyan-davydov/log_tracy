---
name: screenshot
description: Take a screenshot of the DLT Explorer window (macOS, Windows, Linux on X11) with a log open (scripts/screenshot.mjs) and look at it. Use when the user asks to see the app or to check how a change looks; not for simple CSS tweaks the user checks themselves.
argument-hint: "[log path] [what to look at; --settings, --env options]"
---

Take a screenshot: $ARGUMENTS

1. Read `.ai/workflows/preview-ui.md` (When, A Screenshot of the App).
2. Run `node scripts/screenshot.mjs` with the log given (`--open`), or a local log of
   `test_data/` if none is given. A theme, a language or a window size goes into a
   `settings.json` written for it in the scratchpad (`--settings`).
3. Read the PNG and say what it shows about the question asked. One screenshot per question:
   no rounds of retakes without telling the user.
