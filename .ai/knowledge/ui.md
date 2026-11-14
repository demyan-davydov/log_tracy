# The Window and the Script

Rules for this code: `.ai/rules/script.md`, `.ai/rules/ui.md`, `.ai/rules/ux.md`. Sciter
behaviour: `.ai/knowledge/sciter.md`.

## How the Script Is Split

- What the window shows is the state machine `resources/window-state.js` (the documents, the
  New Tab, the failed file); `script.js` only renders it, keeps the documents and the panels,
  the placeholder and the settings.
- The services of Sciter (dialogs, clipboard, window frame, OS) are reached through
  `resources/platform.js` only, as the backend is through `resources/backend.js`; the other
  modules render the DOM.
- Logic worth a test goes into a module free of both, tested by `tests/js` (it imports its
  neighbours with `./`).

## Document Panels

- Every open document has its own panel, `DocumentPane` (`resources/document-pane.js`): it
  puts the parts together and keeps what both tables share (columns, look, anchors, how each
  follows the other's selection), the bottom panel's pages (Search, Filters, File Info on the
  left; MCP Server, of the whole application, on the right, empty for now) and the buttons of
  the lost file (Retry reopens the whole document, Close its tab).
  Its parts: the filters, `FilterPanel` (`filter-panel.js`, chips on the Filters page,
  `.filter-page`; the tab's dot: `active` of `DocumentFilters.toJson`, decided by the
  backend with the predicates the view and the rows use),
  the search bar, `SearchBar` (`search-bar.js`, on `.search-bar`), and its two tables,
  `MainViewTable` and `SearchViewTable` (`view-table.js`): each a `ViewTable`, a table with
  the view of its machine, the status views covering it, the progress under it (their Cancel
  too) and the focus the covers take (`update()` over `tableStep`). What only one of them has
  stays in its subclass (the lost file and Go to Message of the main one, the empty view
  before a search); what ties the two (the found rows of the main table, following a
  selection) stays in the panel. A part binds the events of its own element and asks the
  panel through a `host` of callbacks; the skeleton of the whole panel, the elements of the
  parts too, is built by `renderPane` of `document-pane.js`. A new piece of the panel is a
  part of its own, not more members of `DocumentPane`; its decisions that can be tested go
  into a pure module (`pane-commands.js`, `pane-state.js`). `status-view.js` is not a part:
  the texts of the statuses and the filling of a status view, whose buttons the tables
  (Cancel) and the panel (Retry, Close) bind. Only the panel of the active tab is shown, the others
  are `display: none` and keep their rows, scroll, selection and draft as they are; a hidden
  panel renders what changed when it is shown.
- The tab strip (rendering, pressing, dragging, tooltips) is `resources/tabs.js`; what a tab
  does is decided by `script.js`.
- The focus a panel asks for when shown goes through its host (`host.focus(take)`): given at
  once, or, when a press on a tab showed it, when the press ends (`resources/press-focus.js`,
  `TabStrip` host `released()`; a press lost outside the window is dropped by the next one
  without it, or ended by a key). The placeholder asks the same way. A press on the active tab asks again (`DocumentPane.takeKeys()`). The strip
  itself is focusable and holds the focus during the press (`.ai/knowledge/sciter.md`,
  Events). A panel remembers its focus by `focus`/`focusin`, not in `hide()`: the press has moved it to
  the strip by then.
- The calls of a document's views, filters and search take its id first
  (`backend.mainViewItem(docId, index)`, ...); only the menu and Settings use the active
  document.
- The panel has one splitter, between the main table and the bottom panel (no side panel
  since the filters moved to the Filters page). Its size follows from the panel shown before
  and is written with the rest of `getAppState()` (`AppSettings.searchPanelHeight`; the
  mapping is `resources/panel-sizes.js`), not on each move of the splitter, and the first panel
  starts with it.
- What a table does on a change of its view is `resources/pane-state.js` (`tableStep`:
  reload, or grow in place while the view of the same `dataVersion` gets more rows); the
  flows of its search and rule commands are `resources/pane-commands.js`.
- A table grows in place by `VirtualList.grow()` (`virtual-select.js`, the decision in
  `growStep` of `list-navigation.js`): only `vlist.itemsAfter` changes, the rows on screen are
  not rendered again. `componentUpdate()` on a changed count clears and renders the rows:
  not for a view being filled. The progress and Cancel of a filter or a search filling a table
  are in the strip under it (`.view-progress`, `showProgress` of `status-view.js`).

## Table Columns

- The table columns and the row cells (`ui/table_rows`: `writeRow` over a cell writer,
  `main_window` writes them as Sciter values; the value of each column, by its kind, is read
  by `log_core/column_values`) are built from the format's `ColumnInfo` schema
  as the user's layout of that format arranges it (`log_core/column_layout`,
  `AppSettings.columnLayouts` by format id, edited in the Table section of Settings):
  `backend.tableColumnsJson(docId)`, arranged once per format and variant (`ui/table_columns`).
- Index (not a format column) stays first and Payload last; the others can be moved and
  hidden. A layout is one per format id, for all its variants.
- Dragging to reorder (tabs, columns in Settings) shares `resources/drag-strip.js` (the
  elements: shifts, classes, marker) over `resources/drag-order.js` (the math).
- How a column looks (its width) is up to `resources/table.css`, not the format: a header has
  the classes `col-<column id>` and `col-<format id>-<column id>` (`columnClass` in
  `resources/cell-format.js`; the columns JSON names the format), Index is `col-index`.

## Table Rows

- A row is: anchored, rule id, view index, message index, level, found, then one cell per
  column (`rowLayout` in `resources/cell-format.js`), then one more cell after the columns:
  what the chips of the search found in the payload, `[[start, end, chip]]` in UTF-16 units,
  shown in the chips' match colors in both tables; null for a row the search didn't find.
  - Found: the current search found the record (`DocumentItem.found`; an anchor the search
    doesn't match is listed in the results but not found); the row gets `row-found` by it,
    its matches are shown in the chips' colors (how a found row itself is marked: see
    `.ai/rules/ux.md`, rule 27); the main view looks the record up in the search index.
  - The rule id: see `.ai/knowledge/filters.md`.
  - A time cell is `[microseconds, TimeKind]`: shown by the kind of the record, not of the
    column.
  - Hex cells are formatted by the backend: 64-bit values don't fit a script number.
  - The level colors the cells of columns with `ColumnInfo.byLevel` (an HTTP status shown as
    it is).
  - How a cell shows its value is `resources/cell-format.js`.
  - The Index shows its thousands apart (`groupDigits`): empty `i.digit-gap` elements
    between the digits, no character in the text, so the selection's offsets and the
    copied text stay the plain number.
- Text is selected across cells and rows by the table itself, not by Sciter (no `selectable`
  in a log table: Sciter can't select over a virtual-list): a plain drag selects text, a plain
  click selects the row, Shift/Cmd work on rows. The selection is positions (row, cell,
  character, from the cell's `rangeFromPoint`), painted when a row renders and copied from the
  backend's rows; its logic is `resources/text-selection.js` (story:
  `docs/stories/selectable-cells.md`). Row selection: `resources/row-selection.js` (the keys: `onkeydown` of `VirtualDltTBody`,
  Shift+arrows/Home/End extend from the anchor).
- Rendering a row is hot: see `.ai/rules/ui.md`.
- A log table sizes its sliding window to its height (`VirtualDltTBody.fitWindow`,
  `windowSize`, by the lowest of its rows and header): each half of the window holds the
  rows it can show and a quarter more (5 rows more at least), no fewer than 20 rows in all.
  Sciter fills a list with half its window: a smaller half leaves a gap under the rows. It
  is refitted when it renders, and by the table itself (`watchSize`) when it is resized or
  its font size changes (`sizechange` of the tbody and the thead, only when a height
  changed); a window that grew is filled (`VirtualList.fill`): rows after the last one, rows
  before the first one only at the end of the rows with room under it. Sciter's own window of 160 rows made a jump ~3× slower.
- Every navigation of a list goes through `VirtualList.navigateTo` (`navigationStep`): a
  row past the rows the list counts crashes Sciter, "end" is the last row by number.

## Menu

- The main menu is described once, per platform convention, in the Sciter-free `ui/app_menu`
  (`appMenu`; commands reach the script as `onMenuCommand(id)` on every platform).
  `ui/main_menu_loader` builds the native macOS menu from it; on Windows and Linux the script
  gets it as JSON (`menuJson`, `backend.menu()`: what the items are, not how they look) and
  draws a Sciter menu bar from it (`resources/menu-bar.js`); on every platform the script takes
  the texts of shortcuts in hints from it (`resources/menu-shortcuts.js`).
- A label marks its mnemonic with `&` (`E&xit`). `MENU_BAR_PLATFORM=windows|linux` shows that menu
  bar on macOS too, to try it.

## If You Need X, Start Here (resources/)

- The window, its documents, the start screen: `script.js`, `window-state.js`, `new-tab.js`
- Tabs: `tabs.js`, `drag-strip.js`, `drag-order.js`
- One document's panel: `document-pane.js`, `view-table.js`, `filter-panel.js`,
  `search-bar.js`, `status-view.js`, `pane-state.js`, `pane-commands.js`, `panel-sizes.js`
- The log table: `virtual-dlt-view.js`, `cell-format.js`, `table.css`, `row-selection.js`,
  `text-selection.js`, `list-navigation.js`, `rule-colors.js`
- Search: `search-editor.js`, `search-query.js`, `search-editing.js`, `edit-history.js`,
  `match-colors.js`, `match-colors.css`, `search-editor.css`
- Filters and the rule editor: `rule-editor.htm`, `rule-form.js`
- Settings: `settings.htm`, `settings-sections.js`, `column-settings.js`
- Go to Message (Navigation menu, Cmd+G / Ctrl+G): `go-to-message.htm`, `go-to-message.js`;
  the row it lands on (the nearest shown when filtered out) is
  `backend.mainViewNearestPosition`, `MainViewTable.goToMessage`
- Recent files: `recent-time.js`, `recent-file-menu.js`
- File Info page: `file-info.js` (the rows; the FIBEX row of a DLT log: what decodes it, a
  read going on or why one failed, Load File / Load Folder / Unload), rendered by
  `DocumentPane.updateFileInfo`, refreshed by `onFileInfoChanged`
- Notices: `notice.js`; dropdown lists: `virtual-select.js`
- Menu bar (Windows/Linux): `menu-bar.js`, `menu-bar.css`, `menu-shortcuts.js`
- Theme and window frame: `theme.js`, `theme-light.css`, `theme-dark.css`, `window-frame.js`,
  `osx-frame.css`, `win-frame.css`
- File dialogs' type filters: `file-types.js`; OS services: `platform.js`
- Translations: `i18n/` (see `.ai/knowledge/i18n.md`)
- Visual standards (spacing, radii, typography): `docs/ui-guidelines.md`
