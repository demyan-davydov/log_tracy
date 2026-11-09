# DLT Explorer Rules Index

## Overview

Repository code rules live under `.ai/rules/`. They are binding for every code change and every
review, on top of the context in `.ai/knowledge/`. Choose the files that cover the areas being
touched.

A section marked `Red Flag` is a violation a review must report, even when the rest of the
change is sound.

## Rules

- Every change: `.ai/rules/tests.md`, and `.ai/rules/docs.md` when it adds or moves something
  documented.
- D code: `.ai/rules/d.md`
- Script code (`resources/*.js`, `*.htm`): `.ai/rules/script.md`
- Anything the user sees (script, CSS, markup, backend texts): `.ai/rules/ui.md`
- UX decisions (how the interface behaves and looks): `.ai/rules/ux.md`. Check a new UI
  requirement against it before acting.
