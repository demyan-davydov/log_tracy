---
name: add-backend-call
description: Add a call from the script of Log Tracy to the D backend (AppSession method, MainWindow xcall case, backend.js function, tests), or a new file to resources/. Use when a script feature needs data or an action of the backend.
argument-hint: "<what the script needs from the backend>"
---

Add the call: $ARGUMENTS

1. Read `.ai/knowledge/architecture.md` (Script ↔ Backend), `.ai/rules/d.md`,
   `.ai/rules/script.md` and `.ai/rules/tests.md`.
2. Follow `.ai/workflows/add-backend-call.md`, tests first: the session's unittest and the
   case in `tests/js/backend.test.mjs` fail before the code is written.
3. Finish with `node scripts/build.mjs test`.
