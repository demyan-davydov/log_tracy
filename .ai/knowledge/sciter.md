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
- Mouse capture (`state.capture`) on an element recreated in the same mousedown went together
  with a segfault on tab drag; capture isn't needed for dragging: document-level
  `mousemove` / `mouseup` work.
- A `selectable` cell consumes the mouse press and release itself: neither `mousedown` nor
  `mouseup` bubbles to the tbody, and `addEventListener(..., {capture: true})` doesn't help. A
  class handler in the sinking phase works: `["on ^mousedown"]` / `["on ^mouseup"]`
  (`^` = sinking); not consuming it leaves the cell its text selection.
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

## Popups, Tooltips, Menus

- `Window.this.modal({url, alignment})`: `alignment` is a number of the numpad, 1..9 on the
  screen, -1..-9 on the parent window (-5: its centre, `platform.showModal`). A string such
  as `"center"` is ignored: the dialog lands at the top left of the screen.
- A dialog's buttons take Enter and Escape by role, no `keydown` handler: `role="default-button"`
  is clicked on Enter (a focused button takes Enter itself; its handler checks it is enabled),
  `role="cancel-button"` on Escape (an open list of a select takes the first Escape). Their
  `click` handlers close the dialog. Driving it: `app.mjs key` reaches only the main window,
  a key of the system (`osascript ... key code 53`) reaches the dialog.

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
- `:nth-child` styles are not updated for the siblings that stay when an element is prepended
  or removed (6.0.5.5): `matches(":nth-child(even)")` gives the new answer, the applied style
  is the old one. The rows virtual-list keeps while scrolling had wrong stripes
  (`:nth-child(even)`, `table.css`) at every odd shift of its window. Any change of the
  document restyles them: a class toggled on the `tbody` (`VirtualList.restyleRows`, posted
  from `oncontentrequired`: virtual-list removes the rows past its window after it returns),
  an attribute set on each row (`followAnchor` sets `view-index`). So a check of this bug
  must not write into the page (a status text heals it): the repro writes to the window
  caption.
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
- `position: absolute` offsets are relative to the padding box (inside the border); calibrate
  by measuring `getBoundingClientRect()`. `position: absolute` with `height: 100%` gets height
  0 inside a `position: relative` block: pin it by `left/top/right/bottom: 0` with
  `size: auto`.
- Gradients: `background-image: linear-gradient(...)` is ignored, only the `background:`
  shorthand draws one. A CSS variable works inside the gradient
  (`linear-gradient(to right, var(--rule-color), transparent 33%)`); a whole gradient stored in
  a variable doesn't.
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
  vector icon: `foreground-image: icon(viewbox;d-path)` with `fill` and `stroke` (the rule
  swatch, `.filter-swatch` in `style.css`).
- `overflow: hidden` clips at the content box, not the padding box: a padding doesn't make
  room for an absolute child sticking out (the buttons of a filter chip).
- To diagnose a layout bug, compare `el.state.box("xywh","border","parent")` between a working
  and a broken element instead of guessing.

## Virtual Lists and the Log Table

- **Never hide a log table itself.** A `<table>` with a virtual-list tbody hidden by
  `display: none` before it was ever laid out keeps its cells at x=0, 1px wide, for good.
  Hidden ancestors are harmless, so is hiding a table already laid out. Show status views over
  it (`.status-view.overlay`).
- Rows appended to the data of a virtual-list need no render: assigning `vlist.itemsAfter`
  (6.0.5.5) grows the scrollbar range, keeps the rendered rows, the first visible item and the
  scroll, and the list asks for the new rows when scrolled to them. A list whose window ends
  at its last row with room left doesn't ask: append the rows (`VirtualList.grow`).
- A virtual-list hidden (`display: none`, or `visibility`) and shown again keeps its rows, first
  visible item and pixel offset, even after a resize while hidden; a hidden list requests no
  rows. Focus stays on an element inside a hidden pane: move it on a switch.
- `vlist.navigateTo(n)` puts row n at the top only when n is outside the sliding window or
  above the screen; below the screen but inside the window it lands at the bottom; on screen
  it doesn't scroll. `VirtualList.navigateToTop` navigates past n first
  (n + slidingWindowSize), then to n (`resources/list-navigation.js`).
- A virtual-list scrolls animated with `scrollTo({ top, behavior: "smooth" })` and
  `vlist.advanceTo(n)` (~250 ms, eased); `vlist.scrollBy` and `vlist.navigateTo` are instant
  (6.0.5.5). A smooth scroll renders no rows: it stops at the last rendered one; it goes past
  the last row of the list (clamp to `scrollHeight - clientHeight`); in the frame of an
  instant `scrollTo` it overshoots by that one. `VirtualList.smoothAnimateTo` jumps first,
  then animates the last rows of the way (`approachStep`).
- When rows change height (a class toggle, a smaller font) the scroll position stays in pixels
  and may be past the end. Layout isn't redone until the next frame, not even in a `post`ed
  call; inside `requestAnimationFrame(...)` the geometry is new and `navigateTo` works.
  `vlist.firstVisibleItem` is kept while hidden.
- 6.0.5.5: a far jump (scrollbar drag) asks `where=±1` with a far `start` and drops the old
  rows itself (6.0.3.12 asks `where=0`). It first renders ~half a window of rows around the
  old place, then a whole window at the new one, and lays every new row out (styles, the
  widths of the table): about 1 ms a row of a log table, nearly all of a jump; our script
  is ~6 %. So the window is sized to the list (`vlist.slidingWindowSize`, read-write, 160 by
  default; `windowSize` of `resources/list-navigation.js`, `VirtualDltTBody.fitWindow`).
  Dragging the thumb to an end of a list of ~85M+ rows segfaults inside Sciter
  (`vlist_ctl::move_buffer_to`), reproduced with the SDK sample alone.
- Sciter fills a list (a new view, a jump) with half its window, a couple of rows less, and
  asks for no more until it scrolls: a window grown after (a higher list, a smaller font)
  leaves a gap under the rows. `VirtualList.fill` renders the rows itself (`fillStep`).
  Rows prepended with `itemsBefore` lowered push the rows on screen down, the end of the
  list too: navigate to the last row again.
- A window smaller than the rows on screen segfaults on a jump (`vlist_ctl::move_buffer_to`),
  and so does `navigateTo(n)` with `n >= vlist.itemsTotal` while rows are rendered, whatever
  the window (`advanceTo` past it returns null). `itemsTotal` lags behind `totalItems()`
  while a view grows; an empty list navigated past it lands on its last known row. Navigate
  through `VirtualList.navigateTo` (`navigationStep`: counts the rows first, keeps the target
  within them), never `vlist.navigateTo` or `vlist.navigate`.
- `vlist.navigateTo("end")` asks for a row per pixel of the list's height (483 rows for a
  list 483px high), whatever `slidingWindowSize`, and keeps them: ~0.5 s on a tall list.
  `navigateTo(last row)` puts the last row at the bottom just the same with a window of rows
  (`safeTarget` does it). `navigateTo("start")` asks for a window.
- `sizechange` reaches a virtual-list subscribed with `on("sizechange", ...)`; an
  `["on sizechange"]` method of its class is never called. A `thead` gets it when the font
  size of its table changes (its row follows the font), before the next frame.
- The `outline` of a row of a scrolled virtual-list is painted `scrollTop` lower than the row
  (6.0.5.5), a frame over another row; frame a row with `box-shadow: inset ...` instead.
- Text selection: `behavior: virtual-list` blocks drag selection of text whatever carries
  `selectable`; only `selectable` per cell works, inside one cell. Selection over a
  virtual-list is ours, in JS (`resources/text-selection.js`).
- `element.rangeFromPoint(x, y)` (x, y in the element's inner box) works on a non-selectable
  cell too: it gives the character **under** the point (right of the text: length − 1), on the
  line under `y`; an empty cell gives a node outside it.
