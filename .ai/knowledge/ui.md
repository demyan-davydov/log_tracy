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
  the view of its machine, the status views covering it, the progress under it (its Cancel
  too) and the focus the covers take (`update()` over `tableStep`: the table when the view
  has content, its `dataVersion`; the progress under it when it can be cancelled). What only one of them has
  stays in its subclass (the lost file and Go to Message of the main one, the empty view
  before a search); what ties the two (the found rows of the main table, following a
  selection) stays in the panel. A part binds the events of its own element and asks the
  panel through a `host` of callbacks; the skeleton of the whole panel, the elements of the
  parts too, is built by `renderPane` of `document-pane.js`. A new piece of the panel is a
  part of its own, not more members of `DocumentPane`; its decisions that can be tested go
  into a pure module (`pane-commands.js`, `pane-state.js`). `status-view.js` is not a part:
  the texts of the statuses (`covers`: of a status view; `progress`: of the strip under a
  table) and their filling; the tables bind the Cancel of the strip, the panel the
  buttons of the lost file (Retry, Close). Only the panel of the active tab is shown, the others
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
  (`backend.mainViewPosition(docId, message)`, ...); only the menu and Settings use the active
  document.
- The panel has one splitter, between the main table and the bottom panel (no side panel
  since the filters moved to the Filters page). Its size follows from the panel shown before
  and is written with the rest of `getAppState()` (`AppSettings.searchPanelHeight`; the
  mapping is `resources/panel-sizes.js`), not on each move of the splitter, and the first panel
  starts with it.
- The log table is the native behavior `log-table` (`ui/log_table_behavior`, over `ptable`): the panel puts one in a slot for each view
  (`LogTableView` in `resources/log-table-view.js`, which writes on the element what it shows, `doc`, `search` and `table`, the number the script talks to it by,
  `logTableCall(tableId, method, ...)`, `ui/table_script`). It hears the views of its document itself (a new content version starts at the top,
  rows added to the same one are appended, a table at its end follows it, rule 30), so the script tells it nothing of a reload or a growth.
  What the script does with the views is `resources/pane-state.js` (`tableStep`: which status or table a view shows, the progress under it) and
  `resources/pane-commands.js` (the flows of its search and rule commands).
- The row the user selects in one table is shown in the other (rule 28): D tells the row chosen (`logTableRowChosen`, with `delayed` for a drag and
  the keys), `SelectionFollower` (`row-selection.js`) waits where it must, `jumpStep` decides where to scroll, `scrollTo` and the quiet
  `pickRow` do it (`ViewTable.showMessage`). Go to Message is `MainViewTable.goToMessage`.
- A document opened anew in its tab (Retry, a file truncated or of a format its first bytes
  tell: the backend's `onDocumentReopened`) resets the tab by `DocumentPane.reopened()`. The progress and Cancel of a filter or a search filling a table
  are in the strip under it (`.view-progress`, `showProgress` of `status-view.js`).

## Table Columns

- The columns of the log table come from the format's `ColumnInfo` schema as the user's layout of that format arranges it
  (`log_core/column_layout`, `AppSettings.columnLayouts` by format id, edited in the Table section of Settings, `ui/columns_json`): the
  table makes them in `ui/log_table/document_model` (`DocumentColumns`) and hears when they change. The value of each column, by its
  kind, is read by `log_core/column_values` (`ui/row_cells`).
- Index (not a format column) stays first and Payload last; the others can be moved and hidden. A layout is one per format id, for all
  its variants.
- Without a layout of the user a column is shown as its `ColumnInfo.shownByDefault` says (`defaultLayout`); so is a column a layout
  doesn't know. A layout equal to that default is dropped on saving (`withColumnLayouts`), so the default must count the flag.
- Dragging to reorder (tabs, columns in Settings) shares `resources/drag-strip.js` (the elements: shifts, classes, marker) over
  `resources/drag-order.js` (the math).
- How a column looks (its width, its ink) is the column's style in the table (`ptable_text/columnstyle`, the look `ui/log_table/log_look`
  from the CSS variables of the theme, `resources/log-table-look.js`), not the format.

## Table Rows

- A row is read from the document when the table draws it (`DocumentRows`: the message, the marks of found, anchored, its level and the
  color of its rule), cell by cell by the columns; nothing of it is kept for the next frame.
  - Found: the current search found the record (`DocumentItem.found`; an anchor the search doesn't match is listed in the results but not
    found); its background is `--bg-row-found` / `--bg-row-found-stripe` (rule 27 of `.ai/rules/ux.md`), its matches are in the chips' own colors (`.ai/knowledge/filters.md`, Search).
  - The rule id: see `.ai/knowledge/filters.md`.
  - A time cell shows the time by the kind of the record, not of the column. Hex cells are formatted by the backend.
  - The level colors the cells of columns with `ColumnInfo.byLevel` (an HTTP status shown as it is).
  - The Index shows its thousands apart by the width of its own text.
- Text is selected across cells and rows by the table (`ptable`), not by Sciter: a plain drag selects text, a plain click selects the row,
  Shift/Cmd work on rows (rule 29). Positions are (row, cell, caret).
- Drawing a row is hot: see `.ai/rules/ui.md`; the table keeps no content of a row from one frame to the next.

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
- The log table: `log-table-view.js` (the table of a view), `log-table-look.js`, `log-table-gesture.js`, `table.css`, `row-selection.js`,
  `rule-colors.js`
- Search: `search-editor.js`, `search-query.js`, `search-editing.js`, `edit-history.js`,
  `match-colors.js`, `match-colors.css`, `search-editor.css`; the history of a file's queries
  (`backend.searchHistory`, `backend.removeSearch`; `withSearch`/`withoutSearch` of
  `ui/recent_files`) is the popup of `SearchEditor.openHistory`
- Filters and the rule editor: `rule-editor.htm`, `rule-form.js`
- Settings: `settings.htm`, `settings-sections.js`, `column-settings.js`
- Go to Message (Navigation menu, Cmd+G / Ctrl+G): `go-to-message.htm`, `go-to-message.js`;
  the row it lands on (the nearest shown when filtered out) is
  `backend.mainViewNearestPosition`, `MainViewTable.goToMessage`
- Find (Navigation menu, Cmd+F / Ctrl+F): `DocumentPane.focusSearch` shows the Search page and
  puts the caret at the end of the query (`SearchEditor.focusAtEnd`)
- Recent files: `recent-time.js`, `recent-file-menu.js`
- File Info page: `file-info.js` (the rows; the FIBEX row of a DLT log: what decodes it, a
  read going on or why one failed, Load File / Load Folder / Unload), rendered by
  `DocumentPane.updateFileInfo`, refreshed by `onFileInfoChanged`
- Notices: `notice.js`
- Menu bar (Windows/Linux): `menu-bar.js`, `menu-bar.css`, `menu-shortcuts.js`
- Theme and window frame: `theme.js`, `theme-light.css`, `theme-dark.css`, `window-frame.js`,
  `osx-frame.css`, `win-frame.css`
- File dialogs' type filters: `file-types.js`; OS services: `platform.js`
- Translations: `i18n/` (see `.ai/knowledge/i18n.md`)
- Visual standards (spacing, radii, typography): `docs/ui-guidelines.md`
