---
name: add-format
description: Add a new log format or a variant of one to DLT Explorer (format module, detector, registry, columns, docs/formats.md). Use when the user asks to support a log format or a variant.
argument-hint: "<format> [a sample file or lines, the variant]"
---

Add the format: $ARGUMENTS

1. Read `.ai/knowledge/formats.md`, `.ai/rules/d.md` and `.ai/rules/tests.md`.
2. If there is no sample of the format (a file, or lines in the request), ask for one before
   writing code: the detector and the parser are written against real lines.
3. Follow `.ai/workflows/add-format.md` step by step, tests first.
4. Finish with `node scripts/build.mjs test`, and list what was added to `docs/formats.md`.
