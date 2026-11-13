---
name: update-sciter
description: Update the Sciter libraries of Log Tracy in libs/ (Git LFS) to a new version, with libs/VERSION, the C API check and the behaviour checks. Use when the user asks to update or try another Sciter version.
argument-hint: "<version> [path to the Sciter.JS SDK]"
disable-model-invocation: true
---

Update Sciter: $ARGUMENTS

1. Ask for the path to the SDK of that version if it isn't given.
2. Follow `.ai/workflows/update-sciter.md`. Replacing `libs/` and `libs/VERSION` is one
   commit, made only when the user says to commit.
3. Report what changed in the C headers and which behaviours of `.ai/knowledge/sciter.md` were
   rechecked and how.
