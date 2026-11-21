# Sciter Behaviour and Traps

What was found the hard way, mostly on Sciter 6.0.3.12 (scapp) and 6.0.5.5 (the app's
library, `libs/SCITER_VERSION`). Check a surprising behaviour here before blaming our code; add what
you find. When a behaviour differs between scapp and the app, the app wins: check it there.

The Sciter.JS SDK (docs in `docs/md`, samples in `samples.sciter/`, e.g. `tooltips++`,
`popup`) is not in the repository; keep a copy next to the project. Its `inspector.app` shows
the DOM, the styles and a script console of the running app started with `SCITER_DEBUG_MODE=1`
(Ctrl+Shift+I in the window connects, Ctrl+Shift+click shows an element): for people, an
agent can't drive it. In scapp a plain
`<script>` with JSX doesn't run: use `<script type="module">`. Previewing a page or the app:
`.ai/workflows/preview-ui.md`.

## Native Side

- `SciterPostCallback(hwnd, wparam, lparam, 0)` from any thread delivers
  `SC_POSTED_NOTIFICATION` to the window's host callback on its thread and wakes the event
  loop of `SCITER_APP_LOOP_ITERATION` (6.0.5.5): the answer comes at once, no idle tick needed.
  `postToWindowThread` (`sciter/window`) is built on it.
- The document events of the indexing thread don't wake the loop (`EventBusAsync.publish`
  only queues them): they reach the window because `runIteration()` returns by itself, with
  no input, at least every 50-100 ms. Measured on macOS (6.0.5.5, 2026-11-10): a search of
  a 1 GB log with nobody touching the window got its progress at the pace of the work (gaps
  of 52-686 ms) and its end 80 ms after the last progress, window in the background.
  Sciter doesn't promise it, and Windows and Linux are not checked: if events stall there
  until the mouse moves, wake the loop on publish (`postToWindowThread`). The poll of a file
  being written (`LogDocument.dispatchEvents`, every 250 ms) relies on the same: it would
  stall with them (`docs/backlog.md`).
- Nothing thrown in D may unwind through the frames of Sciter (or of Cocoa): every `extern (C)`
  function they call is `nothrow` and runs its body through `guardCallback`
  (`utils/foreign_callback`). An `Exception` is logged and the callback answers its fallback, an
  `Error` aborts the process. A failed xcall is an event left unhandled: the script's `xcall`
  throws "TypeError: unknown name '<name>'", as for a name the window doesn't know (6.0.5.5,
  macOS); the cause is in the log. The rule itself is in `.ai/knowledge/architecture.md`
  (Foreign Callbacks). Sciter calls its debug output on the window's thread (6.0.5.5, macOS,
  checked while a 50 MB log was indexed): the callback may allocate.
- The constants of `sciter/capi` are copies of the SDK's headers, checked by hand: compare them
  with `include/*.h` of the SDK of `libs/SCITER_VERSION` after an update. `SCITER_WINDOW_STATE`
  was off by one (SHOWN 1, which is HIDDEN): `expand()` hid the window. macOS showed it anyway
  (`activate` brings it forward), Windows never did: the program ran with an invisible window,
  the "no window on Windows" of the users (found by the CI start check, 2026-11-17).
- The library is loaded once (`sciter/api`) and unloaded by a module destructor after main.
  The last collection of the GC runs after the module destructors: a `SciterValue` or a
  `SciterWindow` left to it would call an unloaded Sciter. `sciterApi()` asserts on such a use
  (debug builds and the unittests): release whatever holds Sciter before main returns.
- The script runs with no runtime features (`SCITER_SET_SCRIPT_RUNTIME_FEATURES` 0, `app.d`).
  Not gated by them (6.0.5.5, macOS): modules of `this://app`, `@env` (`language()`,
  `PLATFORM`), `Clipboard`, `Window.screens` and `Window.screenBox`, `Window.this.modal` (the
  dialogs of Settings and of a rule), `selectFile` opening its dialog, `SciterEval`. The path
  `selectFile` gives once a file is chosen, Windows and Linux are not checked. While a native
  file dialog is open the window's thread runs its loop: a `postToWindowThread` task waits for
  the dialog to close (the debug channel times out).
- `import()` doesn't work in code of `SciterEval` ("no function filename for import()").
- `SciterEval` runs in the global scope of the window: the names of `<script type="module">`
  are not there, only what the modules put on `globalThis`. An `ArrayBuffer` comes back as
  bytes (`T_BYTES`).
- `new Graphics.Image(w, h, document).toBytes("png")` with `document.state.box("dimension")`
  renders the whole window in dips (1000x800 for a 2000x1600 Retina window), without the
  system's title bar. Popups are not in it: an open `menu`, a tooltip, a notice, the list of
  a `<select>` are windows of their own (checked 6.0.5.5: a menu open over the table is on
  the screen, not in the image). An element renders by itself, a popup too while it is open:
  `new Graphics.Image(w, h, element)` with `element.state.box("dimension", "border")` (the
  border is in it; a closed popup gives an empty image). The debug channel's `shot` does so.

- A native behavior of CSS `behavior: name` reaches the host callback as `SC_ATTACH_BEHAVIOR`
  (`SciterWindow.createBehavior` answers it; a handler Sciter holds by a bare pointer is kept from
  the GC by `SciterEventHandler.hold`). In `SCN_ATTACH_BEHAVIOR` `elementProc` is the function
  pointer itself: the C type `ElementEventProc*` is a pointer to a function, the D alias is
  already one (the struct had a pointer to it: a wrong layout, fixed before first use). A handler attached so gets
  `HANDLE_DRAW`, mouse, key and focus events, but `element.xcall(name)` of the script never
  reaches its `HANDLE_SCRIPTING_METHOD_CALL`: Sciter answers "unknown name" and only asks the
  object model (`HANDLE_SOM`, cmd 0). The script calls the window instead
  (`Window.this.xcall("logTableCall", method, ...)`, `ui/main_window` hands it to
  `LogTableBehavior.script`). 6.0.5.5, macOS (2026-11-19).
- The graphics API (`graphicsApi()`, `sciter-x-graphics.h`) has 72 functions in the table
  `SciterGraphicsAPI` (the order is checked by a unittest), every one `nothrow`. `RGBA` packs a, b, g, r from the
  top byte. A text layout (`TextLayout`, `textCreateForElementAndStyle`) takes the font, the size
  and the color from its style declaration (`font-size: 8pt; font-family: 'Courier New', ...;
  color: #333`); `gDrawText` has no color, so a text of another color is another layout. Not even
  through the fill: `gFillColor` before `gDrawText` doesn't recolor a layout (it keeps the color
  of its style), and a layout with no `color` in its style draws black, not in the fill color,
  and its words stood wider apart (the JS `graphics.draw(text, {fill})` of the docs paints it
  in a fill color; the C API can't: tried 2026-11-20, 6.0.5.5, macOS). The C API gives no
  position of a character in a layout either (`textGetMetrics`: widths, height, lines only;
  the JS `Graphics.Text` likewise: its widths, height, the metrics and the text of a line): a place
  in a text is had by measuring the text before it, or by summing what was measured. Its
  coordinates of a `DRAW_CONTENT` are the element's own in dips (`params.area` is the content
  box on the view). A layout is lazy: `textCreateForElementAndStyle` costs ~3.6 µs, the laying out is done at the
  first `textGetMetrics` or `gDrawText` (~31 µs for 15 chars, ~52 µs for 95), a laid out one draws in ~1 µs,
  `textRelease` ~2-3 µs; the style string costs nothing to speak of, and the same text in another layout is laid out
  again (no shared cache). `gStateSave`/`gStateRestore` keep the line and fill colors, transform and clip, not a text's
  color. There is no reading of the clip or of the area Sciter repaints; `imageCreate` + `gCreate` (or `imagePaint`)
  give a graphics on an image; `gGetNativeDC` gives the native context on Windows only (Direct2D types; on macOS it
  answers `GRAPHIN_FAILURE`). A partial paint is impossible: `SciterRefreshElementArea` with a small rect still has
  Sciter redraw the whole window at the next frame, every painted element gets its `DRAW_CONTENT` (one nobody asked
  too) on a cleared background, and what a handler leaves out is blank, not kept (tried 2026-11-21, 6.0.5.5, macOS:
  the table drew only the strip of its bar, the rest of it came out empty). A frame costs the whole draw of every
  painted table on the screen. A one-off refresh (`SciterRefreshElementArea`, `SciterUpdateElement`, JS
  `requestPaint()`) draws the window twice, ~2 ms apart: Sciter's own render in its loop, then again when Core
  Animation has the view's layer display (`NSViewBackingLayer display` → `notifyWindowPaint`). Frames of an animation
  frame request come once each. Not caused by the handler (a handler that only fills does the same), nor by the layer
  (CG, Skia raster alike); details in `docs/backlog.md`, "наведение перерисовывает всю таблицу".
  Drawing the table into an image to blit it on the second pass doesn't pay: inside `DRAW_CONTENT` `gCreate` on an
  image answers `GRAPHIN_NOTSUPPORTED`, `imagePaint` works and keeps text sharp at `gScale(2)`, but drawing into it
  costs ~3x drawing on the screen (the image is rastered by the CPU, the screen's commands go to the GPU). Numbers and what the API lacks:
  `docs/experiments/2026-11-21-text-layout-cost.md`. A layout costs ~20 KB of memory: 5000 cached ones were +100 MB of RSS, 600 are
  +10 MB (`SciterTextCache` keeps two generations, `ui/sciter_table/generations`). A layout wraps only by a `width: Npx` in its style: `textSetBox` alone leaves one line. Details and numbers:
  `docs/experiments/2026-11-19-painted-rows-d.md`.
- Sciter's own scroll bar (`overflow-y: scroll-indicator` on an element scrolling a spacer 1/shown of
  it high) doesn't fit the painted table: dropped after a try (2026-11-20, 6.0.5.5, macOS). The
  indicator covers its whole element (a child placed under the header for it); a child over the
  rows takes their mouse; it shows only over itself or while Sciter scrolls it, not on a
  `SciterSetScrollPos` without `smooth`, and a smooth one runs ~800 px at most; a press on the
  track pages (`SCROLL_PAGE_PLUS` and `SCROLL_PAGE_MINUS`, no place of the press); the drag is lost outside the
  window; `SciterGetScrollInfo` tells a content size of 0; a position set right after the
  spacer's height is clamped by the old height until the layout; the scroll events of a child
  don't bubble to the table (`SciterAttachEventHandler` on the child gets them), and a move of
  the position comes as cmd 14 (not in the SDK's enum) with no axis. Changing a style while
  the table paints (its `scrolled` is told during the paint) makes a paint of every paint: the
  window hung while a log was read. The table draws its own bars (`ptable/scrollbar`).

## Events of the System

- `SciterProcX` with `SXM_MOUSE`/`SXM_KEY` is for Sciter Lite (no window of its own): a real
  window answers "not handled" to every message and nothing reaches the document (6.0.5.5).
- macOS: the window's `contentView` is an `NSVisualEffectView`; Sciter's view (ContentView)
  is inside it (`hitTest:`). An `NSEvent` made by `mouseEventWithType:...` handed to that
  view's `mouseMoved:` gives `mouseenter`/`mousemove` and `:hover` as a real move (over an open
  popup, a window of its own: the window of `windowNumberAtPoint:` and its view); one made
  by `keyEventWithType:...` to its `keyDown:`/`keyUp:` types into the focused element (any
  character: it goes through the text input). Through `[NSWindow sendEvent:]` neither
  arrives. A press of a button reaches nothing whatever way: the view, the window,
  `[NSApp sendEvent:]`, `[NSApp postEvent:]` (it lies in the queue till a real event comes),
  `+[NSEvent pressedMouseButtons]` made to say "pressed", CGEventPostToPid to the own
  process. Sciter's tooltip of `title` doesn't show after such a hover (it seems to look at
  the real cursor). `sendMouseMove`, `sendKeyPress` (`sciter/window`).

## DOM and Script

- `element.content(a, b, c)` uses only the first argument; build lists with
  `innerHTML = ""` + `append(jsx)` per item. `Element.append` takes a single node.
- `element.content([...])` of an array mixing texts and elements keeps only the elements
  (`["a", <i/>, "b"]` gives `<i></i>`); a fragment keeps both: `content(<>{pieces}</>)`.
- Don't keep state as properties of elements (`row.view = ...`): on rows reused as slots such
  properties went missing after a while (2026-11-15; an element held by the script kept them,
  the cause wasn't pinned down). Keep it in JS, by the element's place (elementIndex).
- `el.attributes["x"] = null` sets the text "null"; use `removeAttribute` / `setAttribute`.
- Any `classList` call (`add`, `remove`, `toggle`, even `contains`) on an element taken out of
  the DOM with `remove()` segfaults (6.0.5.5, 2026-11-15; `JS_GetPropertyInternal`). An element
  never inserted yet (`Element.create`) is fine; `className`, `setAttribute`, `textContent`
  and inserting it back are fine on a removed one. Keep elements out of the DOM only with
  `className` / `setAttribute("class")`, or reinsert first.
- Setting an input's `value` attribute in JSX doesn't change its current value: assign
  `input.value`.
- `style.variables({name: null})` doesn't remove a variable: `var(name, default)` then doesn't
  fall back; set the default value explicitly.
- componentUpdate() doesn't render synchronously: it posts `render()`. Anything posted right
  after it runs before the render and before what `render()` posts itself, so what depends on
  the render (a scroll target) is passed into render, not posted next to componentUpdate.
- An element needs `tabindex="0"` (not -1) to take the focus from `state.focus = true`;
  otherwise the focus lands on an ancestor.
- Focus stays on an element inside a pane hidden by `display: none` (or `visibility`): move it
  on a switch.
- `element.rangeFromPoint(x, y)` (x, y in the element's inner box) works on a non-selectable
  element too: it gives the character **under** the point (right of the text: length − 1), on
  the line under `y`; an empty element gives a node outside it.
- `Clipboard.readText()` returns the text with a trailing NUL (`\u0000`): strip it.
- Changing `src` of an existing `<style>` doesn't reload it. A `<style src>` created at run
  time does apply, but asynchronously: what is styled meanwhile computes without it, and when
  it arrives only `<html>` is restyled, its descendants keep the stale style until something
  restyles them (a click). A theme swapped so left the text of a dialog black. Load every
  stylesheet statically and switch by an attribute (`resources/theme.js` `applyTheme`).
- No built-in input groups the digits of a number as it is typed (6.0.5.5): `input` of type
  `integer`, `number`, `decimal` and even `<output type="integer">` show `1234567`;
  `type="masked"` has a fixed number of groups (a card, an IP), wrong for a number of any
  length. Formatting while typing is done by script, as the SDK's
  <sciter-js-sdk>/widgets/input-ex/inputex.js does (a port of Cleave.js): a class extending `Element`,
  bound by CSS (`numeral { style-set: edit-plus; prototype: NumeralInput url(inputex.js); }`,
  `@set edit-plus < std-edit` gives the element the behaviour of an edit box), handlers as
  methods (`["on change"]`, `["on keydown"]` to tell Backspace, `["on exec:edit:copy"]` to
  copy without the delimiters); on each change it formats `this.value` anew and puts the
  caret back (`this.edit.selectionEnd`, then `this.edit.selectRange(pos, pos)`): at the end
  it stays at the end, elsewhere it moves by one for a delimiter added or removed before it
  (getNextCursorPosition of its utils/Util.js). Counting the digits before the caret is more exact.

## Events

- **Don't replace the element under the mouse in a mouse handler, and read what it needs of
  `evt` first.** A press in a log table that dropped the text selected re-rendered the row
  (`patch`), removing `evt.target`, then read `evt.clientX`: a segfault on a null pointer in
  `qjs::event_client_x` went together with it (seen in a crash report, not reproduced). The
  table now unpaints a dropped selection in place (`_unpaintTextSelection`).
- A `click` may come with `evt.target` null (6.0.5.5, macOS, seen once in a user's log, not
  reproduced again): a failed open of a recent file had drawn the list again inside its click,
  the next click on the list got no target, and the clicks after it seemed lost. A delegated
  handler checks the target (`clickOpensRecentFile`); a change made by a click on the recent
  files draws the list after the click (`refreshTabsSoon` in `script.js`). Suspected, not
  confirmed: the redraw in the middle of a click.
- Mouse capture (`state.capture`) on an element recreated in the same mousedown went together
  with a segfault on tab drag; capture isn't needed for dragging: document-level
  `mousemove` / `mouseup` work.
- A `selectable` element consumes the mouse press and release itself: neither `mousedown` nor
  `mouseup` bubbles to its parent, and `addEventListener(..., {capture: true})` doesn't help. A
  class handler in the sinking phase works: `["on ^mousedown"]` / `["on ^mouseup"]`
  (`^` = sinking); not consuming it leaves the element its text selection.
- **Don't move the focus inside a mousedown handler, and don't let a press drop it to nothing.**
  A press on a non-focusable element (a tab) drops the focus to nothing before any handler
  runs (sinking phase included) and drops again a focus the handler set. A focus set to the
  log table in the mousedown of a tab cost a synchronous layout of the panel plus ~150 ms of
  restyle and layout after the handler (frames 200–310 ms instead of ~55 on large logs, 6.0.5.5,
  macOS); the same focus from a script or a timer costs ~20 ms. A press with the table focused
  cost the same. The tab strip has `tabindex="0"` so the press moves the focus to it, cheap, and
  the panel takes it when the press ends (`resources/press-focus.js`). Measured:
  `docs/experiments/2026-11-11-tab-switch-focus.md`.
- A focus set by `state.focus = true` reaches an ancestor's `on("focus", ...)` (bubbling,
  `evt.target` the focused element), not its `on("focusin", ...)` nor
  `addEventListener("focusin")`. `DocumentPane` listens to both.
- A `<button>` (`behavior: button`) takes the focus after its mousedown handler when the focus
  was outside the element the handler focused: an editor that closes its popup on `focusout`
  closes it at once. Use `behavior: clickable` (non-focusable, same look).
- `behavior: edit` works on any `flow: text; white-space: pre` element and sizes itself to its
  text; `.edit.selectRange/selectionStart/insertText` work on it. It consumes arrows even at
  its edges, Cmd+Right isn't implemented (Cmd+Left is), and it starts selecting under a drag
  begun outside it: a container that must see keys/mouse first subscribes with
  `addEventListener(name, h, {capture: true})` and consumes with
  `preventDefault` + `stopPropagation`. `Range.applyMark(name)` + `::mark(name)` tints a range.
- A moved frameset splitter fires `statechange`. `sizechange` on a `th` fires when the column
  is widened by the rows (`th.on("sizechange", ...)`, non-bubbling).
- `sizechange` reaches an element subscribed with `on("sizechange", ...)`; an
  `["on sizechange"]` method of its class is never called (an element bound by CSS
  `prototype:`: neither `this()` nor field initializers run either).
- `style.variable(name)` of a length (6.0.5.5, 2026-11-18) answers an object: its text is as written (`9pt`), its
  `units` the unit, and `Number()` of it is its size in dips whatever the unit (9pt → 12, 12px → 12, 1.5em → 20 in the
  element's font, 3mm → 11.3); a bare number answers a number. The log table takes every size in dips, so the script
  passes `Number()` of a length as it is (resources/log-table-look.js). A variable defined by `var()` of one declared
  further down in the same rule answers the resolved value.
- While the window is resized by its edge (macOS, 6.0.5.5, 2026-11-18), `sizechange` comes once the resize ends: an
  element a script places by it lags behind. An element anchored by CSS to the edges of a positioned container
  (`position: absolute; left: 0; top: 0; right: 0; bottom: 0`) follows at once (resources/log-table.js).
- The wheel and the trackpad on macOS (6.0.5.5, 2026-11-15):
  - A mouse wheel comes as `wheel` in pixels (deltaMode 0), accelerated by the system: 12,
    112, 461, … up to ~1000 px an event every ~15 ms while it spins, single ones of 20 000
    px. Apply them once a frame (requestAnimationFrame), never one by one with a layout
    each: the queue grows and the window hangs. A native scroll moves less than the deltas.
    Frames heavy enough (20–35 ms) hold the input back, and macOS sends the wheel in lumps
    (20 000–30 000 px every ~300 ms): keep the way pending to about a screen, drop the surplus.
  - requestAnimationFrame callbacks come 5–36 ms apart, not at the screen's rate: a scroll
    stepped by the raw time between frames jerks; even the step out (a mean period, the lag
    caught up a little each frame).
  - A trackpad comes as gestures, and only to an element that asks: on `gesturestart` call
    `this.state.wantsGestures("pan-vertical", "pan-horizontal")`, then `gesturepan` carries
    the finger's move (deltaY; content follows the finger, scroll by -deltaY). Without
    the request a trackpad sends the script nothing, on the element or the document (a
    mouse wheel's `wheel` comes either way).
  - The inertia after a swipe isn't delivered: `gestureswipe` comes with zero deltas and
    Sciter animates only an element with a native scroll of its own (`scrollanimationstart`
    / `end`, ~1 s). An element scrolled by script makes its own inertia.
  - `overflow: hidden-scroll` scrolls by the wheel and the trackpad without a scrollbar.
  - `SciterRequestAnimationFrameEvent(he, code, 0)` (6.0.5.5, macOS, 2026-11-18): the element gets the
    behavior event `code` at the next animation frame, and again every frame for as long as its handler
    returns true. Never ask again from that handler: each ask adds a chain of frames, they come back to back
    inside `view::do_animation` and the window hangs (`ui/sciter_table/frame_request`, `LogTableBehavior`).
  - A mouse wheel that spins freely (macOS, 2026-11-18) sends ~1100 px every ~16 ms for seconds; a trackpad pan's
    `gesturepan` of 10–40 px comes between them. The log table glides each wheel step over frames itself, does not
    count the wheel while the fingers move, and a spin begun before them does not break their coast (`ptable/scrollmotion`).
  - A touch of the trackpad without a move (a tap to stop the rows, macOS, 2026-11-18) comes as `gesturestart` and a
    `gesturepan` with zero deltas, then `gestureswipe` + `gestureend` on the release; no other event. A wheel that spins
    freely (a mouse) goes on sending steps through it: the table drops them (`wheelStale`) until the wheel is quiet.
  - The end of a pan comes as `gestureswipe` and `gestureend` together, with zero deltas, right after the
    last `gesturepan` (often of 0): a release to coast from.

## Popups, Tooltips, Menus

- `Window.this.modal({url, alignment})`: `alignment` is a number of the numpad, 1..9 on the
  screen, -1..-9 on the parent window (-5: its centre, `platform.showModal`). A string such
  as `"center"` is ignored: the dialog lands at the top left of the screen.
- A dialog's buttons take Enter and Escape by role, no `keydown` handler: `role="default-button"`
  is clicked on Enter (a focused button takes Enter itself; its handler checks it is enabled),
  `role="cancel-button"` on Escape (an open list of a select takes the first Escape). Their
  `click` handlers close the dialog. Driving it: `app.mjs key` reaches only the main window,
  a key of the system (`osascript ... key code 53`) reaches the dialog.
- macOS (6.0.5.5, 2026-11-14): a dialog of `Window.this.modal` drags with a lag (the window
  catches up with the mouse later), the system file dialog doesn't. Not the graphics layer:
  the same on ANGLE, Metal, CoreGraphics and Skia raster. Sciter makes the dialog a child
  window of its parent (`[parent childWindows]` holds it, it moves with the parent), and
  AppKit drags a child window on the app's main thread, busy with the modal loop and the
  repaints of the main window, instead of in the window server. Removing it from the parent
  (`removeChildWindow:`, tried with a timer after `modal`) makes the drag smooth, but the
  dialog is then no longer kept above the parent: a click on the parent hides it under it.
  Not acceptable as is; a fix has to keep it on top (not tried: a higher `level` of the
  dialog, ordering it above the parent on the parent's activation).
- macOS (6.0.5.5, 2026-11-18): the same child-window link is why a modal dialog dragged to
  another display vanishes (two displays with separate Spaces): it stays in `NSApp.windows`
  (isVisible 1, screen the other display, parentWindow the main window, no Visible bit in
  occlusionState), the modal loop keeps the main window blocked and nothing closes the dialog.
  After `[main removeChildWindow:dialog]` (from lldb, before the drag) it moves to the other
  display, stays visible and modal, and the main window moves independently, but it is no longer
  kept above the main window: a click on the main window makes it flicker (below, then back),
  dragging the main window over it puts it below until a click on it. Same dead end as the lag:
  the fix has to keep it on top without the child link. Looking at it: CGWindowListCopyWindowInfo
  (the windows of a pid, also off-screen ones) and lldb over `[[NSApplication sharedApplication] windows]`;
  the frame of a window in lldb needs a struct of four doubles declared in the same expression.

- Text cut with `text-overflow: ellipsis/path-ellipsis` gets an automatic tooltip
  `popup[role=overflow-tooltip]` (besides `title` → `popup[role=tooltip]`). Tooltip popups
  can't be found with `$$()`; give them a `prototype:` class (registered on `globalThis`) to
  track them, close with `popup.state.popup = false`. `path-ellipsis` cuts in the middle only
  text with `/`.
- Suspected, not checked with a real press (6.0.5.5, 2026-11-21): the mouse events of a context
  menu (`evt.source` of "contextmenu") go through the element the menu was asked for and its
  ancestors, so a capturing `mousedown` listener there that takes the press kills the item's
  "click" (the items of the search field's menu did nothing; its editor now lets presses on a
  `menu` pass: `resources/search-editor.js`, `ownMouseEvent`). An event made
  by the script (dispatched) has no `target` in a capturing listener: a mouse handler can't be tried so,
  and the debug channel can't press a button (`sendMouseMove`).
- Popups (`owner.popup(el, {anchorAt, popupAt})`) are "mouse modal": Sciter closes them on a
  press outside or when the app loses focus. `popupdismissing` comes to the popup element;
  `popupdismissed` comes to the **owner**, never to the popup. Don't remove the popup element
  inside its own event: defer it. `popup()` returns a PopupWindow, not the element.
- The popup pattern that works (SDK `samples.sciter/popup`): the owner is the control that
  toggles it; a persistent `<popup>` child of the owner, refilled on each show; toggle on the
  owner's mousedown by `owner.state.ownspopup`, skipping presses inside the popup
  (`evt.target.closest("popup...")`); listen for item clicks and `popupdismissed` on the owner.
  `owner.popup(el, {popupAt, x, y})` with window coords from
  `other.state.box("xywh","border","window")` places it under another element.
- Menus: `accesskey` on `behavior: menu-bar` / `menu` items does nothing for mnemonics:
  handle them in script (`resources/menu-bar.js`). `li.popup(li.$("menu"), {anchorAt,
  popupAt})` opens an entry, `menu.state.popup = false` closes it; keydown with a menu open
  still reaches a capture listener on `document`.
- `<select>` dropdown: `select > popup.list > option`; `option:hover` matches, but Sciter's own
  style set wins over the document's rules on the options: they need `!important`.

## CSS and Layout

- A `:before` with `position: absolute` and a width is not sized/positioned as in browsers:
  use a real child element. On `:before`, `visibility: hidden` and `opacity` are ignored;
  `color: transparent` hides it, `color: inherit` shows it. Changing its `content` relayouts
  the table and the rows below blink: keep the content, toggle the color.
- A child with `position: absolute` (`top`, `right`) inside an element itself `position:
  absolute` was placed by the positioned ancestor above both (6.0.5.5, 2026-11-15): place such
  a child in the flow (`margin-top`, `margin-left: *`) instead.
- An element with `overflow-x: hidden` still scrolls by `scrollTo` (and reports
  `scrollWidth`), but keeps its `scrollLeft` when its content gets narrower: the content stays
  shifted out of sight (`auto` brings it back); clamp it yourself.
- `element.paintBackground = gfx => ...` draws under the element's content, but the element's
  own CSS background is painted over it: give the element none and paint it too. `gfx` is in
  the element's box, in px as `getBoundingClientRect`; `element.style.variable("name")` gives a
  CSS variable for `gfx.fillStyle`; `requestPaint()` asks for it again. What it paints is not
  clipped to the element's box: cut it yourself.
- `:nth-child` styles are not updated for the siblings that stay when an element is prepended
  or removed (6.0.5.5): `matches(":nth-child(even)")` gives the new answer, the applied style
  is the old one. Any change of the document restyles them (a class toggled on the parent,
  an attribute set on each sibling), so a check of this bug must not write into the page (a
  status text heals it).
- A block is centred in its parent by `margin: 0 *` (flex units); `margin: 0 auto` leaves it
  at the left. Vertical `*` margins take all the free height: a block after it (an `:after`)
  goes down to the bottom of the cell.
- `outline` follows `border-radius`: a ring with a contrast around it is a round block with
  a `border` and an `outline` (tried for the found rows on `td.anchor:after`).
- Foreground layers (6.0.5.5, tried on the log rows): `foreground-color` with alpha is drawn
  over the background and the text of a `tr`, so it tints the letters too. `foreground-blend-mode`
  is ignored (`multiply`, `screen`, `darken`, `lighten`: the layer is drawn opaque, hiding the
  text). A `foreground-image` (an `icon()` or a gradient) on a `tr` is not drawn at all; on a
  `td` an `icon()` is drawn as a small square, not stretched by `foreground-size: 100% 100%`.
  To tint a row and keep its text: a translucent `background-color` on its cells, drawn over
  the background of the row (its stripe shows through) and under the text.
- `:empty` is not re-evaluated when a script changes `innerText`: set `style.display` from the
  script instead.
- A transition doesn't delay `visibility` (`transition-delay` or a duration: it switches at
  once); keep an element shown for a while by an `animation` of `@keyframes` with `visibility:
  visible` in both, set on the hidden state (`.filter-chip-actions`). In `transform`,
  `translate(100%, 0)` is wrong: a zero needs a unit (`0dip`); a percentage of the element's
  own width works, on a block (a `span` needs `display: block`).
- `position: absolute` offsets are relative to the padding box (inside the border); calibrate
  by measuring `getBoundingClientRect()`. `position: absolute` with `height: 100%` gets height
  0 inside a `position: relative` block: pin it by `left/top/right/bottom: 0` with
  `size: auto`.
- Gradients: `background-image: linear-gradient(...)` is ignored, only the `background:`
  shorthand draws one. A CSS variable works inside the gradient
  (`linear-gradient(90deg, var(--rule-color), transparent 25%)`); a whole gradient stored in
  a variable doesn't. Write the direction as an angle: `to right` tilts the gradient downward in
  tall cells.
- Dark theme: `document.attributes["theme"] = "dark"` switches Sciter's own widgets (select,
  buttons, checkboxes, inputs) to dark and, by `:root[theme="dark"]`, our `theme-dark.css`
  (every page loads both theme files). The open list of a
  dark select is pure black: `select > popup { background-color: ... !important }`. The macOS
  title bar stays light.
- `frameset` cols/rows size the **content** box of a frame: measure `state.box("width",
  "inner")` to save a size you will give back. `frameset.state` reads as Length values
  (`"120dip,1*"`); assigning an array of strings or another frameset's `state` works, also when
  hidden; plain numbers are ignored. After a drag it may fix the other side (`"512px,1*"`):
  don't read a panel's size from it.
- `min-width` on a `th` without `box-sizing: border-box` excludes the border: setting it from
  the measured width grows the column 1dip each round. In the fixed-layout log table the
  `width` attribute of a `th` has no effect at usual sizes; a CSS `width` is enforced.
  `box-sizing: border-box` on all headers shifted every column by 1dip: leave it off unless a
  width is set.
  A `th` with a padding of 9 px came out 14 px wider than its `min-width` (6.0.5.5), whether
  from the box's inner width or with `border-box`: learn the excess from what a `min-width`
  gave, don't derive it.
- Sizing a chip by its text and cutting it at the room left (the Filters page, 6.0.5.5):
  - a `width: max-content` element counts a child with a `max-width` as that max-width, not
    its text: a cap on the name made every chip as wide as the cap. `max-width: max-content`
    on the name (with `width: *`) makes the chip's max-content its text;
  - a column of `flow: row()` grows to its widest item, whatever its `max-width`: use a
    `flow: horizontal` row with a `width: *` part instead;
  - a `width: *` part still grows to its content unless it has `overflow-x: hidden`;
  - `max-width: 100%` of a padded child needs `box-sizing: border-box`, or the padding and
    the border stick out; `min(…)` and `calc(100% - …)` against a max-content parent don't
    work (unsupported, circular);
  - a child's `min-width` is left out of the parent's max-content: two buttons with
    `min-width: 16dip` around 11dip glyphs cut every name by 10dip. Give them a `width`.
  - a block of text in a `width: max-content; max-width: 100%` parent keeps the width of its
    own text when the parent is capped: it doesn't wrap at the parent's width and runs out
    to the right. `width: *` on it wraps it there (the status views, `tab-content.css`).
- In a `flow: horizontal` row a child's own `vertical-align` (meant for its content) also
  places it in the row: `margin-bottom: *` keeps it at the top.
- `text-shadow` is faint (no halo that keeps a white glyph seen on white) and a list of
  shadows draws none; a glyph in a small box sits ~1px low. For a mark on any color draw a
  vector icon: `foreground-image: icon(viewbox;d-path)` with `fill` and `stroke`.
- No `contrast-color()` and no CSS function of one's own: `morph()` only shifts a color
  (`darken`, `lighten`, `sepia`, `mix`...; Sciter's name for the old `tint()`). It takes a
  `var()` as its base, in a variable too: the found rows derive from the stripes this way. A
  text on a color set by the script takes its color from the script too (`contrastText`
  of `resources/rule-colors.js`, the chips of the Filters page).
- An empty element as a space in a line of text (the gaps of the Index): `display: inline`
  takes no width, padding or not; `inline-block` takes it but has no height (a background
  unseen) and with a height sits on the baseline, hanging below the text and growing the
  line: `height: 1.15em; vertical-align: top` lines it up with the text.
- `overflow: hidden` clips at the content box, not the padding box: a padding doesn't make
  room for an absolute child sticking out (the buttons of a filter chip).
- To diagnose a layout bug, compare `el.state.box("xywh","border","parent")` between a working
  and a broken element instead of guessing.
- No frozen columns of a `<table>` in CSS (6.0.5.5, 2026-11-13): the attributes `fixedcols` and
  `fixedrows` (their names are in the library) change nothing, and `position: sticky` is
  unknown (`style.position` stays null). A cell with `position: relative` moves twice its
  `left` (`left: 100dip` → 200dip), and `transform: translate(...)` doesn't move a cell at all.
