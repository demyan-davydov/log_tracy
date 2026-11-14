# Updating Sciter

`libs/<system>/[<architecture>/]` holds the Sciter library of every platform, packed by brotli
into `<library>.br` and kept in Git LFS (`.gitattributes`: `libs/**/*.br`); the version is in
`libs/SCITER_VERSION`. The libraries themselves are ignored by git. A clone fetches none of the
archives (`.lfsconfig`); `scripts/build.mjs` fetches the one a build needs and unpacks it next to
itself, again when the archive changes (`unpackLibrary`). A library changed while its archive
didn't stops the build: a new Sciter not packed yet.

1. Take the libraries of the new version from the Sciter.JS SDK's `bin/` for every system and
   architecture present in `libs/`. The SDK's `packfolder` is not taken.
2. Put the new libraries in `libs/`, all five, and run `node scripts/build.mjs pack-libs`: until
   then a build stops on a library that doesn't match its archive. Commit
   the archives (`<library>.br`) with the bumped `libs/SCITER_VERSION`: the binding
   (`source/sciter/capi`) is written for the API of that version.
3. Compare the SDK's C headers with `source/sciter/capi` for changed signatures or structures.
4. `node scripts/build.mjs test`, `node scripts/build.mjs check-windows`, run the app and go
   through the table (fast scroll, scrollbar drag), popups, the menu and the text selection:
   the behaviours of `.ai/knowledge/sciter.md` may change between versions. Update that file
   for what changed.
5. Update `docs/building.md` if the steps for people changed.
