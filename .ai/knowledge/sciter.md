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
