# Sciter Behaviour and Traps

What was found the hard way, mostly on Sciter 6.0.3.12 (scapp) and 6.0.5.5 (the app's
library, `libs/VERSION`). Check a surprising behaviour here before blaming our code; add what
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
  until the mouse moves, wake the loop on publish (`postToWindowThread`).
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
- `el.attributes["x"] = null` sets the text "null"; use `removeAttribute` / `setAttribute`.
- Setting an input's `value` attribute in JSX doesn't change its current value: assign
  `input.value`.
- `style.variables({name: null})` doesn't remove a variable: `var(name, default)` then doesn't
  fall back; set the default value explicitly.
- `componentUpdate()` doesn't render synchronously: it posts `render()`. Anything posted right
  after it runs before the render and before what `render()` posts itself (e.g. VirtualList's
  `navigate("start")`), so scroll targets are passed into render
  (`VirtualList.navigateTarget`), not posted next to `componentUpdate`.
- An element needs `tabindex="0"` (not -1) to take the focus from `state.focus = true`;
  otherwise the focus lands on an ancestor.
- `Clipboard.readText()` returns the text with a trailing NUL (`\u0000`): strip it.
- Changing `src` of an existing `<style>` doesn't reload it: replace the element
  (`resources/theme.js` `applyTheme`). A `<style>` created at run time with `innerHTML` or
  `src` does apply.

## Events

- **Don't replace the element under the mouse in a mouse handler, and read what it needs of
  `evt` first.** A press in a log table that dropped the text selected re-rendered the row
  (`patch`), removing `evt.target`, then read `evt.clientX`: a segfault on a null pointer in
  `qjs::event_client_x` went together with it (seen in a crash report, not reproduced). The
  table now unpaints a dropped selection in place (`_unpaintTextSelection`).
- Mouse capture (`state.capture`) on an element recreated in the same mousedown went together
  with a segfault on tab drag; capture isn't needed for dragging: document-level
  `mousemove` / `mouseup` work.
- A `selectable` cell consumes the mouse press and release itself: neither `mousedown` nor
  `mouseup` bubbles to the tbody, and `addEventListener(..., {capture: true})` doesn't help. A
  class handler in the sinking phase works: `["on ^mousedown"]` / `["on ^mouseup"]`
  (`^` = sinking); not consuming it leaves the cell its text selection.
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

## Popups, Tooltips, Menus

- Text cut with `text-overflow: ellipsis/path-ellipsis` gets an automatic tooltip
  `popup[role=overflow-tooltip]` (besides `title` → `popup[role=tooltip]`). Tooltip popups
  can't be found with `$$()`; give them a `prototype:` class (registered on `globalThis`) to
  track them, close with `popup.state.popup = false`. `path-ellipsis` cuts in the middle only
  text with `/`.
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
- `:empty` is not re-evaluated when a script changes `innerText`: set `style.display` from the
  script instead.
- `position: absolute` offsets are relative to the padding box (inside the border); calibrate
  by measuring `getBoundingClientRect()`. `position: absolute` with `height: 100%` gets height
  0 inside a `position: relative` block: pin it by `left/top/right/bottom: 0` with
  `size: auto`.
- Gradients: `background-image: linear-gradient(...)` is ignored, only the `background:`
  shorthand draws one. A CSS variable works inside the gradient
  (`linear-gradient(to right, var(--rule-color), transparent 33%)`); a whole gradient stored in
  a variable doesn't.
- Dark theme: `document.attributes["theme"] = "dark"` switches Sciter's own widgets (select,
  buttons, checkboxes, inputs) to dark; our `theme-dark.css` alone doesn't. The open list of a
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
- In a `flow: horizontal` row a child's own `vertical-align` (meant for its content) also
  places it in the row: `margin-bottom: *` keeps it at the top.
- To diagnose a layout bug, compare `el.state.box("xywh","border","parent")` between a working
  and a broken element instead of guessing.

## Virtual Lists and the Log Table

- **Never hide a log table itself.** A `<table>` with a virtual-list tbody hidden by
  `display: none` before it was ever laid out keeps its cells at x=0, 1px wide, for good.
  Hidden ancestors are harmless, so is hiding a table already laid out. Show status views over
  it (`.status-view.overlay`).
- A virtual-list hidden (`display: none`, or `visibility`) and shown again keeps its rows, first
  visible item and pixel offset, even after a resize while hidden; a hidden list requests no
  rows. Focus stays on an element inside a hidden pane: move it on a switch.
- `vlist.navigateTo(n)` puts row n at the top only when n is outside the sliding window or
  above the screen; below the screen but inside the window it lands at the bottom; on screen
  it doesn't scroll. `VirtualList.navigateToTop` navigates past n first
  (n + slidingWindowSize), then to n (`resources/list-navigation.js`).
- When rows change height (a class toggle, a smaller font) the scroll position stays in pixels
  and may be past the end. Layout isn't redone until the next frame, not even in a `post`ed
  call; inside `requestAnimationFrame(...)` the geometry is new and `navigateTo` works.
  `vlist.firstVisibleItem` is kept while hidden.
- 6.0.5.5: a far jump (scrollbar drag) asks `where=±1` with a far `start` and drops the old
  rows itself (6.0.3.12 asks `where=0`). Dragging the thumb to an end of a list of ~85M+ rows
  segfaults inside Sciter (`vlist_ctl::move_buffer_to`), reproduced with the SDK sample alone.
- Text selection: `behavior: virtual-list` blocks drag selection of text whatever carries
  `selectable`; only `selectable` per cell works, inside one cell. Selection over a
  virtual-list is ours, in JS (`resources/text-selection.js`).
- `element.rangeFromPoint(x, y)` (x, y in the element's inner box) works on a non-selectable
  cell too: it gives the character **under** the point (right of the text: length − 1), on the
  line under `y`; an empty cell gives a node outside it.
