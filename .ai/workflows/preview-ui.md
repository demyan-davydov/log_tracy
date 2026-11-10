# Previewing the UI

## When

Simple visual tweaks (a color, a hover style) are not checked by launching the app and taking
screenshots: say the change is unchecked and let the user look. Preview only when the user
asks or a cause can't be found otherwise, and say so first; no rounds of screenshots on one's
own.

## A Screenshot of the App

```sh
node scripts/screenshot.mjs --open <log> [--open <log>] [--out build/x.png] [--wait 3]
    [--settings <settings.json>] [--env PSEUDO_LOCALE=1] [--release] [--no-build]
```

It builds the app, starts a copy in a temporary folder with its own settings (never the
developer's), opens the logs (`OPEN_AT_START`), waits for the window and `--wait` seconds more,
captures that window only into `build/screenshot.png` and stops the copy. The copy is removed
after a screenshot; when something fails it is kept with the app's output (the path is
printed). Only a debug build writes its output line by line (`app.d`): a killed release build
leaves it empty. Read the PNG to look at it.

- A theme, a language, a column layout, a window size: start from a `settings.json` written for
  it (`--settings`).
- Logs: a local one of `test_data/` if there is one (not in the repository), or one made for
  the case.
- macOS: the first run compiles `build/tools/window-list` with `swiftc`; capturing needs the
  Screen Recording permission of the terminal. Windows: PowerShell with user32
  (`build/tools/window-shot.ps1`, the C# compiled once into `WindowShot.dll`; `PrintWindow`). Linux: X11 or XWayland
  (`GDK_BACKEND=x11`) with `xdotool` and ImageMagick's `import` (the window is raised first:
  `import` reads the screen). Windows and Linux are not
  tried yet (`docs/backlog.md`).
- What the screenshot can't show (hover, an open popup, a drag) needs a script driving the app:
  below.

## A Dialog in scapp

The dialogs of `resources/` (`settings.htm`, `rule-editor.htm`) render with sample data when
opened without parameters, so they can be seen in the SDK's `scapp`:
`<sciter-js-sdk>/bin/macosx/scapp <absolute path>.htm`. Start it as a plain background
process: under a pty scapp shows no window. A scapp copied on macOS may need
`xattr -cr` + `codesign -f -s -` to run.

Synthetic `MouseEvent` dispatch doesn't reach the handlers in scapp: to preview a drag, call
the named functions from a temporary copy of the page, then delete the copy.

## Driving the App

`scripts/app.mjs` drives a running copy of a debug build through the debug channel
(`docs/building.md`, "Driving the app"): no temporary changes of the script any more.

```sh
node scripts/app.mjs start --open <log> [--settings <settings.json>] [--env NAME=VALUE] [--no-build]
node scripts/app.mjs wait "<js true when ready>" [--timeout 10]
node scripts/app.mjs eval "<js>"          # the value of the last expression as JSON
node scripts/app.mjs shot [build/x.png]   # then read the PNG
node scripts/app.mjs run <steps file>     # eval <js> | wait [<n>s] <js> | shot <file>, a line each
node scripts/app.mjs log | stop
```

- Wait for a condition (`wait`), never a fixed pause: indexing and search run in the background.
- An element comes back as `{tag, id, class, text, box}` (`box`: x, y, w, h in the window), so
  geometry is read, not guessed: `el.state.box(...)`, `getComputedStyle`-like checks by
  `el.style[...]`.
- The code runs in the global scope: the modules' own names (`$`, imports) are not there; use
  `document.$(...)` and what the modules put on `globalThis`.
- `shot` is Sciter's own render of the window: no Screen Recording permission, no title bar of
  the system. For the window as the system shows it: `screenshot.mjs`.
- Not possible yet: real mouse and keys (hover, `:focus` from the mouse); `el.click()` and
  `el.dispatchEvent(...)` don't move the mouse (`docs/backlog.md`).
- Stop the copy when done (`stop`): it keeps running otherwise.

Refresh the binary of a copy with `rm` then `cp`, never `cp` over the old file: macOS kills an
overwritten signed binary at start (exit 137, no output), which looks like a crash. Launching
right after `pkill` in the same command often fails: launch in a separate command.

## Screenshots by Hand (macOS)

Screenshot only the window of the process, never the whole screen: its id from
`build/tools/window-list <pid>` (on screen, layer 0, the largest: the app also owns off-screen
layer-0 windows that give a blank shot), then `screencapture -x -o -l<id>`. A dropdown list is
a window of its own.

Input: `CGEvent` posted to `.cghidEventTap` doesn't reach the Sciter window; click into the
window first, then `event.postToPid(pid)` works.
