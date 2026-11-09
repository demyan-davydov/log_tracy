# Previewing the UI

## When

Simple visual tweaks (a color, a hover style) are not checked by launching the app and taking
screenshots: say the change is unchecked and let the user look. Preview only when the user
asks or a cause can't be found otherwise, and say so first; no rounds of screenshots on one's
own.

## A Dialog in scapp

The dialogs of `resources/` (`settings.htm`, `rule-editor.htm`) render with sample data when
opened without parameters, so they can be seen in the SDK's `scapp`:
`<sciter-js-sdk>/bin/macosx/scapp <absolute path>.htm`. Start it as a plain background
process: under a pty scapp shows no window. A scapp copied on macOS may need
`xattr -cr` + `codesign -f -s -` to run.

Synthetic `MouseEvent` dispatch doesn't reach the handlers in scapp: to preview a drag, call
the named functions from a temporary copy of the page, then delete the copy.

## A Copy of the App

Never run against the developer's own `settings.json`. Copy the binary, its Sciter library and
a copy of `resources/` to a scratch folder with a `settings.json` of its own. Open files are
not restored at start: append `setTimeout(() => openFile("<abs path>"), 300);` to the copied
`script.js` (a local log of `test_data/` if there is one: it is not in the repository).
Driving it: a script appended to the copied `script.js` (expose what it needs on `globalThis`
there; the app has no test hooks of its own), its output read from stdout under
`script -q -F log` (unbuffered).

Refresh the binary of such a copy with `rm` then `cp`, never `cp` over the old file: macOS
kills an overwritten signed binary at start (exit 137, no output), which looks like a crash.
Launching right after `pkill` in the same command often fails: launch in a separate command.

## Screenshots (macOS)

Screenshot only the window of the process, never the whole screen: get its window id from its
pid with a small Swift `CGWindowListCopyWindowInfo` helper (layer 0 and `kCGWindowIsOnscreen`
true: the app also owns off-screen layer-0 windows), then `screencapture -x -o -l<id>`. A
dropdown list is a window of its own.

Input: `CGEvent` posted to `.cghidEventTap` doesn't reach the Sciter window; click into the
window first, then `event.postToPid(pid)` works.
