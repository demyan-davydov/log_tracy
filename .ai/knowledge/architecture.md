# Architecture

## Data Flow

From bytes to the table:

```
ByteSource (log_core/byte_source)          bytes of a log, addressed by offset (FileSource = mmap, grows)
  └ LogFormat (log_core/log_format)        splits bytes into records, decodes one into a LogMessage,
       │                                   declares the table columns (ColumnInfo)
       ├ DltFormat (formats/dlt/format)    binary DLT; parser in formats/dlt/parser
       └ TextFormat (log_core/text/...)    line-based base: multiline records, record length limit,
            │                              UTF-16 through inEncoding (log_core/text_encoding)
            └ formats/*                    PlainTextFormat (fallback), LogcatFormat, ...
LogIndex (domain/log_index)                offset/filter/search indexes, built on a background thread
LogDocument (domain/log_document)          a log + its main view and search view, operation events
DocumentStore (domain/document_store)      open documents and who holds them, their events by id
AppSession (ui/app_session)                what the calls of the script do: files, tabs
                                           (ui/document_tabs), views, search, filters, settings
                                           (Sciter-free, tested); what detection picks for a file, for the
                                           marks of "Open as": ui/detected_formats (kept while the file stays)
MainWindow (ui/main_window)                Sciter window: xcall bridge to the session
resources/script.js, tabs.js               the window: tabs, placeholder, settings, backend callbacks
resources/document-pane.js                 a panel per document: its parts (view-table: the two tables,
                                           filter-panel, search-bar) and status-view
LogTableBehavior (ui/log_table_behavior)   the native behavior `log-table`: Sciter's events and drawing for a LogTable
  └ LogTable (ui/log_table/log_table)      a view of a document (DocumentRows) as a painted table of ptable,
                                           its cells by ptable_text, its look by ui/log_table
resources/log-table-view.js                 the log table of a view: the element of the behavior `log-table`, its menus, gestures and clipboard
```

## Packages

A package imports only the packages to its left (unittests may import more, e.g. a format to
build test data):

```
utils  ←  log_core  ←  formats  ←  domain  ←  ui  ←  app.d
utils  ←  sciter  ←  ui
ptable  ←  ptable_text  ←  ui
```

- `ptable/`: a table that draws its rows itself, a package of its own (the log table of the
  application; the story: `docs/stories/painted-table.md`): `ptable/table` (`Table`: the layout of rows, scrolling, the selection; it calls the units below and the interfaces; `TablePorts` are what a host gives it), `ptable/tablespace` (`TableSpace`: the size, the fonts and the regions that follow from them and from the host's margins left and right, stale together; the margins above the first row and under the last one are the painter's `TableGeometry.marginTop`/`marginBottom`, scrolled with the rows (`RowViewport.margins`: inside the viewport the first and the last row are that much taller, the slots it gives are the rows' own; `ptable/edgemargins`: `EdgeMargins` cuts a margin to the room a low window leaves its row, `marginsInView` the parts in the window; the viewport alone knows them: `endTop` for `Table.scrollToEnd`, `revealPlan` brings the first and the last row with their margins, End too): the window on the rows is the whole body less the margins at its sides, `FramePainter` has the painter fill the parts of the margins in view (`paintEmpty`, by `RowViewport.marginsInView`), and the scroll bars stay the table's, along the body (`Table.bodyArea`)) with `ptable/tablefonts` (the geometry the painter asks and the metrics of the body font; what the painter leaves to the fonts is made of them), `ptable/scrollmotion` (`ScrollMotion`: the scrolls the table makes by itself on the frames the host gives through `Table.tick`, one tick for all; the table has no timers; who moves the rows is a `Scroll` state and `next` the table of its changes and of what the glide does (`Move`), a plain enum and a pure function on purpose: `ptable` imports no `utils/fsm`; the newest input takes over, the wheel is not counted while the fingers move, a wheel spinning since before them does not break their coast, a step along a coast speeds it up; a glide to a place the table shows itself (`glideTo`, a shape given) is no input: none of those rules apply to it, and a press lands it at once or stops it where it is, as the glide was told (`press`); `Table` brings a row or a place in by `RowViewport.jumpToGlide` and `Table.approach`, aimed where the row can stand (`RowViewport.reachableTop`, the ends of the rows): a row near and out of view peeks in at its edge, glides as a step of the wheel and a press lands it; a place more than `lead` windows off begins `lead` windows before it, glides quickly (`farShape`) and a press stops it; near or far is chosen by distance, not by the caller; the numbers are trials, in `Table.approach` and `farShape`; `revealMargin` is the host's) with `ptable/dragscroll` (the scroll of a drag past the rows), `ptable/inertia` (`Inertia`: how far the rows coast after a pan of the trackpad, by the speed of the last moves; `Table.coastPolicy`, a delegate of the host like `anchorPolicy`, may change that distance, a row start) and `ptable/glide` (`Glide`: the rows going over a distance, slower and slower, to land on it; the coast, the step of the wheel and the glides to a place are glides of their own `GlideShape`), `ptable/tableports` (`TablePorts`: what a host gives a table), `ptable/framepainter` (`FramePainter`: draws one frame from the slots, the places of the columns and what is picked, changes nothing), `ptable/rowstore` (`RowStore`: the rows kept with the model's columns, the fonts and the layout, brought up to date in the order they depend on each other; knows no window), `ptable/subscriptions` (the store's ears: its model and layout and the listening to them, let go of by `RowStore.dispose`), `ptable_text/columnstyle` (the style of a text column as data, one type `CellStyle` whose every field may be unset: `font`, `ink`, `back` (ids: the painter resolves colors by the theme, the core only fonts), `halign`, `valign`, `padLeft`, `padRight`; `a.over(b)` merges field by field. `ColumnDef.style` is a `ColumnStyle`: three `CellStyle` slots (`cell`, `group` for the heads of a group, `header` for the title) and what is the column\'s own: `minWidth` (`ColumnDef`\'s third constructor argument), `minHeight`, `wrap` (the flex column only; false: one line cut at its cell and at a hard break, the log table\'s single-line view, `LogTable.singleLine`). The column owns its style: the table reads none of it.), `ptable/rowranges` (`RowRanges`: the rows selected as sorted ranges, a Shift range over millions of rows is one entry, `has` is a binary search the painter asks for every row; a set only) and `ptable/rowpicks` (`RowPicks`: the set with the anchor and the current row, `Pick` = replace / extend / toggle / extendAdd that the host chooses by its keys, a drag over rows, a context click, `click(i, deselect)` lets go of all rows on a click on a picked one (the table does not use it for now); the core knows no key: `ui/sciter_table/input` has `pickMode`), `ptable/column` (`TableColumn`: a column is an object that measures (`measure`, `measureHeader`, `measureGroup`), lays out (`layout`), draws (`draw`, `drawBack`, `drawHeader`, `drawGroup`) and hit-tests (`hitTest`: the caret nearest to a point, `rects`, `expand`: what a double click takes) its cells, title and group heads by its own style and fonts; the table gives it the cell (`CellInput`), its area and the state (`DrawState`); the row is as high as its tallest wanted cell; `ui/log_table/text_column` (`TextColumn`) is the text column of the log, `ptable_text/textcell` (`TextCell`) the text column both are made of, `ptable/testing` (`BoxColumn`) the one of the tests of `ptable`), `ptable/rowpicker` (`RowPicker`: the rows picked and how the input picks them: a pick by a `Pick` mode, a click, a press with a mode that picks at once and drags over rows, Escape (the text first, then the rows), telling the host the current row; what it needs of the table (is an item virtual, the row at a height, show a row, tell the host) it gets through `PickPorts`; owns the `TableSelection` of the text, the press and the copy), `ptable/rowhits` (`RowHits`: what a point hits in the rows on the screen: the text position, where a drag reaches, the word or the cell; reads the store, the viewport and the row view, the table lays the rows out before it asks and passes the selected row and the press row as parameters), `ptable/testing` (`BoxColumn`, a column of fixed boxes, `DatedModel` and `TwoHeadsModel`, rows grouped by day, and by a day and a shift), `ptable/rowview` (`RowView`: the context of a row and of a cell, the text of a cell as it lies in the table, the cells in focus for `texthit`), `ptable/tableselection` (`TableSelection`: the text selected, the press of the mouse and the copy of the text or of the rows given), `ptable/texthit` (the position under a point and the rectangles of a selection, over any cells with `length`, `right(col)` and `cell(col)`: `FocusedRow` of `ptable/rowview`), `ptable/lookchange` (`LookChange`: colors repaint, metrics measure again), `ptable/listeners` (`Listeners!Change`: ordered, safe to unsubscribe while told), `ptable/columnset` (the columns now: definitions, flex, wanted mask, placements), `ptable/pointer` (`PressTracker`, `SelectionState`), `ptable/navigation` (`Key`, `navigate`), `ptable/hitregion` (`areaAt`: header / footer / rows / around, by the regions alone), `ptable/tablehit` (`TableHit`: the answer of `Table.hitTest(x, y)`: `HitKind` header / footer / cell / free, the column by its id, of a cell the row, whether it is picked and the characters under the point with their word, whether text is selected; JSON for the script; `CopyTarget`: what `Table.copy(target, row, column)` copies (the only way to the clipboard: `copyText` is for the script's checks), the text, the rows or a cell by its address; the table builds no menu: the host's script owns it, asks `hitTest`, calls `contextPick`, and passes an item's address to `copy`), `Table.updateRow(item)` / `updateCell(item, defIndex)` (a row or a cell looks another way, not its data: only its area is painted again through `TableEvents.invalidateArea`, the whole table through `invalidate` when the host tells no areas; the hover and the press of a clickable cell use them, an animation will), `ptable/rowcopy` (the text for the clipboard), `ptable/columnar` (the second layer, optional: `Column!Row` with extractors that write into a reused buffer, `RowSource!Row`, `ColumnarModel!Row : TableModel`), `ptable/layout`
  (`ColumnLayout`: widths, visibility, pinning and the horizontal scroll by column id, given to all the
  tables of a column host; `placeColumns`), `ptable/columnhost` (`ColumnHost`: the columns the tables of one list share, one host per
  document (`LogTables.hostOf`): the definitions, the layout, the margins left and right of the rows (`setMargins`, the same for its tables), the room of the
  columns (the least body its attached tables have less those margins: a wider one leaves its edge empty, none cuts a column; a table
  never sized, never drawn, tells none: `TableSpace.sized`), their places (`ColumnHost.places`), and `settle`, the fit
  of the widths to the rows of all its tables: each client (`ColumnClient`, the `RowStore` of a table) lays out its rows and tells what
  they need, a column takes the most, the clients lay out again while a width widens, one `LayoutChange.Kind.fit` at the end; a table
  settles only when its own window, rows or columns changed (`RowStore.fitStart`), never because of a fit of the host, so two tables
  never argue over a width; `Table.detach`/`attach` leave the host for a while and come back where the rows stood), `ptable/model` (`TableModel`, `RowData`: what a table is
  given), `ptable/cellparts` (`CellPartsExtractor` of `TableColumn.parts`: what a cell of a column consists of, a head the rows are grouped by and the body it shows; the row cache keeps the body as the cell's text and the head apart, `ptable/rowgroups` (`RowGroups`) says which columns group (every one whose cells have heads) and which heads of a row changed (`Entry.heads`, `Entry.changed`), a row whose head differs from the row's above has a margin over it (`TableGeometry.groupHeight`) where `Painter.paintGroupBand` draws the room and `Painter.paintGroup` each head that changed, in its column's cell, the heads are painted after the header (`FramePainter.paintGroups`): a margin going up covers the header, the head of the rows on top stands where the header is; only the rows near the screen and the row above them are read (the room they take is kept near the window, their content only for the pass), never the whole log; `Table.copy(wholeCellsInFull)` gives a cell selected whole with its head), `ptable/painter` (`Painter`: how its parts look), `ptable/ports` (the canvas, with its `drawText` and `drawParagraph`, and the
  clipboard a host implements (no timer: the host gives frames to `Table.tick`)), `ptable/viewport` (the lowest level: a window on a list of rows of different heights, knows no columns and no scroll bar; `ScrollMetrics` (a fraction and the part shown, no unit) and `scrollToFraction` are what any outside bar uses), `ptable/scrollscale` (the fraction of a bar for the rows and back: the point p·count of the list at p of the window, exact at both ends, measuring only the rows on the screen; a list of a few rows (`exactRows`) or with fewer rows than a window of empty rows is measured whole and scrolled by pixels; it moves forward all the way because no row is lower than an empty one, `RowGeometry.floor`), `ptable/rowcache` (`RowCache`: the facade of the rows over the units below; no content of a row lives from one frame to the next, the model is asked again each pass: a memory-mapped file gives a record in ~150 ns and its cells formatted in ~1.3 us, measured), `ptable/rowwindow` (`RowWindow`: the rows read for the pass of a frame, each once, let go by `beginPass` at the start of the next; the `Entry*` it gives live until then. A pass is a frame: `Table` begins it at the paint, or at the tick of the frame that moves the rows, whose rows the paint then draws; the hits between two frames read into the last pass, and a change of the model lets its rows go), `ptable/cellmemo` (`CellMemos`: what a column noted of a cell from frame to frame, a `CellMemo` of marks (a place, its x) per long cell of a row near the window, in a ring of `RowGeometry`'s size, let go with the room of the rows (`RowCache` clears both); `CellInput.memo` carries where to find it, the column takes it in the ring only for a long line and alone reads it: a text column marks every `markEvery` runs of a line of `memoFrom` units or more, `ptable_text/runs`), `ptable/rowgeometry` (`RowGeometry`: the room the rows near the window take, a ring whose size follows the window: four windows of rows, at least 64, no fixed limit; a row not in it is measured: read, its row above read for the heads of the groups, then the texts are let go; no row is lower than an empty one; a list scrolled by pixels has all its rows in it; a ring made anew keeps the rows known; a new width of a wrapping flex column makes the heights known estimates (`estimate`, what a sum over a list scrolled by pixels takes), measured again only when a row's own height is asked), `ptable/rowreader` (`RowReader`: the accessor, one row from the model as the table lays it out, into an arena the caller owns), `ptable/rowwrap` (`RowWrap`: the flex cell laid out by its column, `CellLayout.height`; the table keeps no lines, a text column wraps again where it draws and hit-tests), `ptable/rowgrow` (`RowGrow`: what the rows need of the column widths; `RowStore.measure` tells the column host what the rows on the screen and the titles need (the needs measured last again, no row measured, while its window shows the same rows and nothing they are fit to changed: a table standing while the other of its host scrolls), and `ColumnHost.settle` sets each column to the most its tables need when the window, the rows or the columns of one of them change: a column grows to a long text and narrows when it is out of sight; the user's width is not touched), `ptable/rowspec` (`RowSpec`: what those units are told of the columns and the look), `ptable/rowentry` (`Entry`), `ptable/regions`
  (header, body, footer, padding, thumb strip; `Panes`, `panesOf` (once a frame, from where `Placements` put the columns: `originX`, `viewportWidth`, the host's room), `seenOf`: the part of a cell seen, under no pinned strip and in the rows, which the table gives a column as `DrawState.clip` and as the `view` of `hitTest` and `rects`), `ptable/memory` (arena, buffer, hash map on an `RCIAllocator` the host gives),
  `ptable/scrollbar` (an optional layer: `ScrollBar` along the rows or along the columns (`Orientation`), its painter; `enabled` turns it off, it is shown only while there is something to scroll, it widens under the mouse, while its thumb is held or while it is `pinned` over the frames of the host (`ptable/transition`, `ScrolledTable.tick` with the table's own), the painter told how far (`wide`, 0 .. 1); the thumb keeps its size from a press to the release, and `ScrolledTable` holds the table's scale (`Table.holdScale`: by pixels or by the anchor) for as long), `ptable/scrolledtable` (`ScrolledTable`: the table with its bars over the edges of its body, taking no room from it: one at the right and, only while the columns do not fit, one at the bottom; neither runs under the other; under the bar at the right (the corner where they meet when both are there) the badge of following the end, for a table that may follow it: a press toggles `Table.setFollowingEnd`, the thumb dragged onto it and held `dwellMs` (counted on the host's frames, `tick`) turns it on; the bar is `pinned` meanwhile (its thumb held under a drag until pulled `snapOff` up, from where the mouse was when it got pinned) and the painter draws the badge (`ScrollBarPainter.paintBadge`), or the pinned thumb and the badge as one (`paintPinned`); without the badge the corner is nobody's; a host may connect its own bars to `scrollMetrics`/`scrollMetricsX` and `scrollToFraction`/`scrollToFractionX` instead), `ptable/rowlayout`, `ptable/selection` (pure logic), `ptable/endfollow` (`EndFollow`: whether a table follows the end of its rows as a terminal does: only a command turns it on (`Table.setFollowingEnd`, the badge of `ScrolledTable`), while it is on the table puts the end in view again at every paint, a move of another's than the table's own that leaves the end out of view or a new list turns it off; where the rows stand never turns it on; `Table.followEnd(true)` allows it, `mayFollowEnd`, `isFollowingEnd`, `scrollToEnd` (moves only), the event `followingEnd`; off by default, `LogTable` allows it for the views of a document), `ptable/scrollplace` (`CellPosition`: a cell and where its left top corner stands from the corner of the room of the rows; `Table.firstVisible` and `lastVisible` report it for the first and the last row and column in sight, `partlyVisibleRows` is `[first, past the last)`, `size` the room of the rows, `rowHeight(index)`, and `Table.scrollToPosition(CellPosition, timestampMs)` is told where to stand, by a glide on the frames of the host (by the same approach as a row shown) or at once; the rows far off have no pixel position, their heights are not known until they come near; `ui/view_json` writes it as JSON for the script, `ptable` knows no JSON). The table never reads the `Extra` data a model attaches to rows and
  cells (`ui/log_table/marks`: `LogMarks`, the level, found, anchored and the filter rule of a row, found once when the row is read (`LogRow`, `DocumentRows.fetch`) and read by the columns by their fields; only `marks` knows how they are packed into `Extra`), and uses no garbage collector memory in a steady frame (a test).
  Imports only `std`; `tests/js/ptable-boundary.test.mjs` keeps it so, and keeps the names of the text out of it.
- `ptable_text/`: the text columns of the log table, over `ptable` (it imports only `ptable` and `std`, nothing imports it but `ui`): `ptable_text/columnstyle` (`ColumnStyle`, `CellStyle`, `Halign`, `Valign`, `alignedX`,
  `alignOffset`: how a text column looks, as data; `CellStyle.keepInViewX`/`keepInViewY`: a text cut by the edge of the rows aligns in the part of its cell seen, each axis on its own, by `alignedXInView`/`alignedTopInView` over `Span` (`ptable/ports`, with `Rect.across`/`down`), never out of its paddings; `TextCell.spotOf` takes the view, so drawing, the hit test and the selection agree; `TextCell.alignedAcross` places a column's own marks (the anchor) the same way; a paragraph the host wraps is kept by all of its lines), `ptable_text/measurer` (`TextMeasurer`: metrics of a font, the width of a text, the lines the host wraps itself; the host implements it), `ptable_text/wrap`
  (`LineSpan`, `wrapLines` by the widths its runs are drawn with, a long word cut by the advances of the glyphs at the end of a grapheme (`graphemeCut` of `ptable_text/runs`), `glyphWidth` read off a run of the glyph, `firstLineWidth`), `ptable_text/wordpick` (`caretAt`, `charAt`, `wordAt`, `wholeText`: where a point or a click falls in a text),
  `ptable_text/runs` (a line as runs, a word or a gap of spaces or of tabs (a tab as wide as a space, drawn as one), at most `maxRun` units, a long word cut only at the end of a grapheme (`std.uni.graphemeStride`): a text cell draws a line run by run, each by a layout of its own, only those that cross the part seen (`eachRun`), and places a match, a selection or the caret by the same widths (`xAt`, `placeAt`): the start of a long line is never laid out, only its words, whose widths the host keeps; a long line walks from the marks of its cell's memo), `ptable_text/texthit` (`TextSpot`, `caretInText`, `rectsInText`, `unitInText`: what a text column answers the hit tests by), `ptable_text/textcell` (`TextCell : TableColumn`: the column of text,
  which measures, lays out, draws, hit-tests, answers a double click; its lines are wrapped again at each call, the last wrap kept; `ui/log_table/text_column` (`TextColumn`) adds the colors of the log),
  `ptable_text/testing` (`FakeMeasurer`, `TestText`, `withText`). A new kind of column (a picture, a chip) is a `TableColumn` of its own and needs none of it. The log table on it (the host
  side, `ui/`): `ui/log_table/marks` (`LogMarks`: what the model attaches to a row and the cells that draw by it, packed and read only there), `ui/log_table/document_model` (`DocumentRows`: a view of a document as a `RowSource` that hears the document through `AppSession.subscribeViews` (`ui/view_listeners`: what is told, `ViewListener` and `ViewVersion`, and the list of the listeners by document; it knows no table, so the session imports nothing of `ui/log_table` nor of `ptable`), the views turned into the changes of its model by the rule of `ui/log_table/view_events`; the rows look another way (`ModelChange.Kind.looks`: read again at the next paint, nothing measured anew) when the search view is shown anew (the main rows mark what it found) or the filter rules of the document changed (`ViewListener.rulesChanged`, told by `AppSession.filterCommand`): the script tells the tables nothing of it; `documentColumns`; `documentTableModel`: the model of the main and of the search table), `ui/look` (`Look!(Palette, Spacing)`: the text, the palette and the spacing of the layer (the log's is `LogLook`: `LogPalette`, `LogSpacing` in dips), one source for the painters, the scroll bar and the text cache; the script reads them from CSS variables (`resources/log-table-look.js`: colors of the themes, lengths of `.log-table` in any unit, Sciter gives dips: the table takes every size in dips, it knows no unit of CSS) and sends them by `setLook`; a change tells `ptable.LookChange`: `colors` repaints, `metrics` (fonts, spacing) drops what was measured, and the host drops its own caches first, through `LogTable.beforeMetrics`; the order is `applyLookChange`), `LogTables` of `ui/log_table/log_tables` (the log tables of the window: what the script asks of them is done there, the window only converts the values of Sciter; the painted tables the script talks to, in a `TableRegistry` of `ui/table_script`, by the number the script wrote on the element of each (the attribute `table`, read with `doc` and `search` by `tableAttributesOf` when the behavior attaches; `logTableCall(tableId, method, ...)` uses it), a detach takes away only its own; `logTableSetLook` and `logTableSingleLine` are the application's and reach every table; no static in the behavior), `ui/log_table/log_table` (`LogTable` and `TableSource`: the model of a view of a document, the table in the look of the log and its scroll bar, made and let go of together, no Sciter), `ui/sciter_table/frame_request` (one frame event on its way at a time, a request waited for too long is taken for lost), `ui/sciter_table/input` (what the events of Sciter mean for the table: the wheel step, the keys, the main button, copy; plain functions with tests), `ui/sciter_table/sciter_host` (`SciterHost`: the element, the cache of text layouts, the measurer, the canvas and the clipboard as one unit; a change of the fonts is one call), `ui/frame_stats` (the times of the frames and the JSON of the measurements), `ui/table_messages` (what a log table tells the script and answers it, as the JSON the script parses: a row chosen, a clickable cell clicked, a copy cut, the current row; Sciter-free) and `ui/table_script` (the script's calls to the log table as commands over a `TableControl`, Sciter-free, and `TableRegistry`; the behavior converts the values; the calls of the checks and the measurements only in a build with the debug channel), `ui/log_table/log_tables` (`LogTables` above; what a table shows, read off its element, and what the log tables share: the column host of a document, which goes with the tab (`AppSession.subscribeDocumentClosed`), the look, the single-line setting). The views are heard by `AppSession.subscribeViews` on the window thread only, in `takeScriptCalls` at the moment the script is told (the columns, from `setColumnLayouts`, by every listener of every document), `ui/log_table/painter` (the
  painter of the log table: rows, borders, group plates), `ui/log_table/column_widths` (the least widths of the columns from CSS: the variables `--column-min-width`, `-anchor`, `-index`, `-payload` and `--column-min-width-<format>-<column>`; D lists their names for every column of every format (`logTableMinWidthNames`), the script reads them in dips into `look.minWidths`, D multiplies them by the scale of the text and the columns of `DocumentColumns` take them as `ColumnDef.minWidth`, the least width of the content of a cell: `TextCell` adds the paddings, the table the line between the columns (`TableGeometry.columnBorder`); a name `table.css` gives that D does not list fails a test), `ui/log_table/log_look` (the look of the log table apart from who draws it: `LogFont`, `LogPalette`, `LogColor`, `LogSpacing`, `LogLook`, the ink and font of a level (`LogFont.level`, always monospace); the Payload has a font of its own, `LogFont.payload`, the system's or
  `monospacePayloadFont` (the levels' font) as `ui/log_table/look_json` (`scaledTextLook`) makes it by the settings; the painter and the columns read it), `ui/sciter_table/host` (canvas, text measurer, clipboard over the graphics API
  of Sciter), `ui/sciter_table/generations` (the cache of two generations both its layouts and its widths are kept in, Sciter-free: a hit in the older moves to the current, bounded by count, what goes is released `releasedPerKeep` at each `keep` after it), `ui/log_table_behavior` (the native behavior `log-table`: events of Sciter into a `ScrolledTable`).
- `utils/`: what knows nothing of logs and could move to another project as it is: chunked
  array, mapped file, lock guard, background slot, state machines (`utils/fsm`), event buses
  (`utils/event_bus/`), parallel scan, single instance, `ui_text`, substrings in any case
  (`utils/text_search`), regular expressions (`utils/text_regex`, the only module that uses
  `std.regex`), keys by name (`utils/keys`,
  whatever the system) and their codes of macOS (`utils/mac_keys`), Objective-C calls
  (`utils/objc`), the boundary of callbacks of foreign code (`utils/foreign_callback`), the
  program's own log (`utils/app_log`), the path of a `file://` URL of Sciter's dialogs
  (`utils/file_url`), standard streams a program started without
  (`utils/std_streams`).
- `log_core/`: what doesn't depend on a format (LogMessage, LogFormat, filters, ByteSource,
  column layout, the values of the columns of a record (`column_values`: the one place the
  columns of a record are read as values to show; the log table writes the texts of its cells
  through it, `ui/row_cells`), the encodings of text: `text_encoding`); `log_core/text/` the base of the text
  formats.
- `formats/`: every format, one module (`formats/logcat.d`) or a package when it has several
  (`formats/dlt/`, `formats/can/`, `formats/syslog/`). `formats/registry.d` lists them.
  `formats/generator/` is not a format: the test log generator, compiled only for the
  unittests and the `gen_log` tool (`.ai/knowledge/formats.md`, The Log Generator).
- `domain/`: documents, indexes, anchors. Knows formats only through `LogFormat`,
  `detectFormat` and the interfaces a format may add, asked by a cast (`PartedFormat`,
  `TransferringFormat`, both a `MarkedFormat`).
- `sciter/`: the D wrapper over Sciter (window, application, value, ...); `sciter/capi/` the C
  API it calls.
- `ui/`: the window and the logic behind it; the Sciter-free part of it is unit-tested.
- `scripts/`: the build script (`build.mjs`: build, test (`--module` for one D module), dist,
  Windows check, `gen-log` that builds and runs the test log generator `gen_log.d`, `bench`
  that measures the tree against a ref, its pure part in `bench.mjs`; `--brief` filters the
  output of every step through `build-output-filter.mjs`), `run.mjs`,
  `check-ai-context.mjs` (the names of `.ai/` the code lost), `backtrace.mjs` (the stacks of
  a running app),
  `app.mjs` (drives a copy of the app through the debug channel), `screenshot.mjs`,
  i18n extraction, benchmarks (`bench_rows.d`, `bench_index.d`). They run from the project
  root wherever they are called from (`gen-log` runs the generator in the caller's folder:
  the path of a log is the user's). The pure part of `build.mjs` is tested by
  `tests/js/build-script.test.mjs`, the filter of `--brief` by `tests/js/build-output-filter.test.mjs`; Linux and Windows `dist` were not tried on those systems
  yet (`docs/backlog.md`).

## The content of a cell (log table)

`ptable.column` has `TableColumn`: the interface of what a column does with its cells, its title and the head of a group (measure, draw, hit test, the rectangles of a range, the text of a range,
the calls of changes) and `Position`, a place in the table whose number inside a cell only its content reads. The direction decided with the owner
(docs/stories/painted-table.md, "Содержимое ячейки выходит из ядра"): the core knows no text and no style, a column is an object that measures and draws its cells,
its title and its group head; the table has no overrides, the model, the columns, the painter of row chrome and the format of copying come in as objects.
The text code (wrapping, line layout, text hit tests, column styles) is in `ptable_text`, over `ptable`: the core holds none of it.

## Script ↔ Backend

- The script asks the backend through `resources/backend.js`, one function per
  `Window.this.xcall(name, ...)`, read in `MainWindow.handleEvent` and done by `AppSession`.
  A new call gets its function there; the script calls nothing else
  (`.ai/workflows/add-backend-call.md`). The calls of the log tables are the exception for now:
  `logTableSetLook`, `logTableMinWidthNames` and `logTableSingleLine` are
  done by `LogTables` (`ui/log_table/log_tables`), which the window owns, not the session: they
  hold `ptable`'s column hosts, and the session knows no `ptable`; the window only converts the
  values of Sciter. `logTableCall` hands a call to the table of that number: `runScript`
  (`ui/log_table_behavior`) converts the values, `dispatch` (`ui/table_script`) does it over the
  table's `TableControl`. The settings of the tables (the single line; the text scale and the
  monospace Payload, inside the look the script makes of CSS, `collectLook`) are the script's, as every setting is: the script tells D, which
  keeps one copy in `LogTables`; the session has them only when the settings are written.
- The backend tells the script what changed by `callScript` of a global function
  (`onMainViewChanged(docId, json)`, `onSearchViewChanged`, `onDocumentOpened`, ...). A change
  the script is told of comes as an event of the document's bus (`AttachmentsChanged` gives
  `onAttachmentsChanged`), never by the session polling the document. The
  session only queues those calls; `MainWindow.onIdle()` sends them (`takeScriptCalls`) after
  the document events of the indexing thread were dispatched on the UI thread, never from
  inside an `xcall`. A log table tells the script the same way (`logTableRowChosen`,
  `logTableCellClicked`, `logTableCopy`, `logTableCopyCut`): its behavior hands the call to
  `TableHooks.tell`, the window queues it (`ui/script_queue`) and `onIdle()` sends it with the
  calls of the session, in a few rounds while the script's answers queue more.
- The resources are built into the executable (`ui/app_resources`, string imports) and served
  to Sciter at `this://app/<path>` (`SciterWindow.onLoadData`). The icons of the program are not built in:
  `resources/app-icons/`, made of its `logo.png` by `scripts/utils/make-icons.mjs`, are taken by `dist`.
- The script's `console.log` goes to the program's log (`appLog` of `utils/app_log`, which never
  throws) as `info [script]: ...` lines (errors as `error [script]: ...`): stdout, next to the
  backend's `writeln`.
- A Windows program run from Explorer has no stdout and stderr (`/SUBSYSTEM:WINDOWS`), a
  launcher elsewhere may close them, and std.stdio throws once a write to one fails. The module
  constructor of `utils/std_streams` points each missing one at the null device (`NUL`,
  `/dev/null`): the log of such a run is dropped (no log file yet: `docs/backlog.md`). It runs
  before the constructor of `sciter/api`, which writes as it loads Sciter, because that module
  imports it: a new module that writes in its constructor imports it too. Each stream is
  checked by its own handle, not by a console: a stream the program was given (a file, the
  pipe of an MCP client) stays. CI starts the Windows distribution as Explorer does and waits
  for its window (`.github/workflows/build.yml`).

## Foreign Callbacks

- Nothing thrown in D may unwind through the frames of foreign code (Sciter, Cocoa): its state
  is undefined after it, and LDC's exceptions on Windows do unwind through C++ frames. Every
  `extern (C)` function such code calls is `nothrow` and runs its body through `guardCallback`
  (`utils/foreign_callback`): an `Exception` is logged by `appLog` and the callback answers
  its fallback, an `Error` (a bug) is logged and aborts the process. A new callback does the
  same, with a unittest that it is `nothrow`. What each callback answers on a failure:
  `.ai/knowledge/sciter.md` (Native Side).
- The guard keeps Sciter whole whatever throws; the missing stdout of a Windows program is
  handled before, at start (`utils/std_streams`, above).

## Settings and Lifetime

- `settings.json` sits next to the executable and is rewritten on exit. Run a copy of the
  binary from another folder to keep the developer's own settings.
- The distribution is another build type, `dist` (`dub.sdl`): a release with
  `version (Installed)`, whose settings live in the user's folder (`settingsDir` of
  `ui/app_settings`: `~/Library/Application Support/Log Tracy`, `%APPDATA%\Log Tracy`,
  `$XDG_CONFIG_HOME/log_tracy`). Every build of our own, release included, keeps them next
  to itself.
- The settings are only marked changed: the next `onIdle()` writes them (`settingsDue`), with
  the script's `getAppState()` merged in. `saveAppState` on closing writes them at once; from
  then on the script is not called any more (its view is being torn down), and what changes
  after that is written on exit (`finish`).
- On macOS Quit (Cmd+Q, the Dock, logging out) closes the window without `closerequest` and
  exits inside the event loop: the application delegate's `applicationShouldTerminate:`
  (`ui/main_menu_loader`) writes the settings first (`MainWindow.terminate`).
- The window frame is written when the user is done moving or resizing it
  (`replacementend`) and restored by the script (`resources/window-frame.js`): `main.htm`
  sizes the window, not the creation rect.
- A release build runs one copy per `settings.json` (`utils/single_instance`, a lock on
  `settings.lock` next to it): a second one brings the first forward and exits. Debug builds
  run side by side.
- A recent file (`ui/recent_files`) keeps its format choice, its filter sets, its search history
  and its anchors (message indexes: restored when the file is opened or opened anew, dropped
  when a rotation truncates it).
- `main()` (`app.d`) puts the application together: it makes the `DocumentStore` and the
  `AppSession` over it with its factory of documents (`LogDocument`), so `ui/` doesn't create
  documents itself, gives the session to `MainWindow`, and closes the store after the window
  (on macOS Quit the loop never returns: `AppSession.terminate` closes the store then).
- A document lives while someone holds it (`DocumentStore.hold`/`release`; `add` holds it for
  the caller): a tab of the window (`AppSession`: a tab is a holder, `ui/document_tabs` the
  order and the active one), later an AI session. A hold is a token (`DocumentHold`), released
  once: a holder releasing its own twice doesn't take another's. The last `release` closes it;
  closing a tab doesn't close a document another still holds. Ids are the store's, the tabs
  know only theirs.
  The views, filters, search and anchors of a document are its tab's: another holder only holds
  it, reads records (`Document.leaseRecords`) and asks how far its load has got
  (`Document.state`: the bytes and records loaded, the end of the load, its error). Only the
  window opens files yet, so every document has a tab (a tab for a document of another
  holder: `docs/backlog.md`).
  The store is of the UI thread: `add`, `hold`, `release` (its `destroy` cancels and joins the
  indexing), `doc` are called there, so a holder on another thread (the MCP core) hands its
  calls over to it. Its events are pumped by the window's idle loop
  (`AppSession.dispatchEvents`); a subscriber may release documents meanwhile. A holder keeps
  the id, not the `Document`: a Retry replaces the object for every holder, and takes
  `doc(id)` each time. A Retry numbers the records anew: `DocumentStore.generation(id)` is one
  more after each `replace`, so a holder that keeps numbers of records compares it with the
  one they were taken in. A document may decode its records by another format of the same
  records (`Document.loadDescriptions`: a FIBEX loaded or dropped, read in the background,
  the last request winning): the numbers, the anchors and the generation stay, the values
  change; `FormatReplaced` tells any change of the choice (`decodedAnew`: the records decoded
  anew; false for a document that can't be read, or descriptions dropped that weren't
  taken), and the filter and the search are built again (a request of its own,
  `LogDocument._pendingFormat`, given to the index once no pass runs). `DescriptionsChanged`
  tells a read started, failed or taken (`Document.descriptions`). The session writes the
  choice to the recent list on `FormatReplaced` and tells the File Info page on both
  (`onFileInfoChanged`). What a holder computed from the values (AppId, text) is stale
  then. A holder keeps what it needs of the format (`DocumentFilters`: its columns), not the
  format.
- Environment variables for trying things, read in `main()` (`newSession` of `app.d`) and
  passed to the session and the window: `OPEN_AT_START` (logs opened at start, `backend.startFiles()`), `UI_PLATFORM`,
  `PSEUDO_LOCALE`, `SCITER_DEBUG_MODE` (the debug mode of Sciter, for its inspector). The table of them: `docs/building.md`, "Environment variables for
  development"; a new one goes there.
- The debug channel (only a build with `--debug-channel`, version `DebugChannel`, debug or release; `SCITER_DEBUG_PORT`): `ui/debug_channel` is a TCP
  server on 127.0.0.1 that runs the requests of `ui/debug_protocol` (JavaScript to evaluate,
  `resources/debug-eval.js` making its value plain JSON; a render of the window into a PNG,
  and of each open popup into a PNG beside it; the mouse moved and keys pressed as events of
  the system) on the window's thread through `postToWindowThread`, `evalInWindow`,
  `sendMouseMove` and `sendKeyPress` (`sciter/window`: `SciterPostCallback`, `SciterEval`,
  `NSEvent` on macOS with the codes of `utils/mac_keys`). The parsing of every request (a
  key's name by `utils/keys`), the order of the events handed (`sendInput`) and the response
  lines are in `ui/debug_protocol` only: `debug-eval.js` gives the value or what was thrown,
  not a line of the protocol; the channel only runs things on the window's thread.
  Kept apart on purpose: `main()` starts and stops it, nothing else knows of it; a new command
  is a request kind of the protocol, not a hook in the window or the session: a member of
  `RequestKind` with its parsing, script and response in `ui/debug_protocol`, and its case of
  the `final switch` of `Server.answer` in `ui/debug_channel` (the compiler asks for it). Its
  client is `scripts/utils/app.mjs`.

## Indexing and Threads

- A document reads its descriptions (a FIBEX: `Document.loadDescriptions`, the opening of a
  choice with them too) on a `BackgroundSlot` of its own, `LogDocument._descriptionsSlot`:
  the slot of the index is busy with its passes. The end of a read, whatever it was, is a
  `DescriptionsLoaded` of the document's bus, published once the slot is idle; taken on the
  UI thread if it is of the last request (`_descriptionsRequest`), else dropped and the read
  asked after it started. A request gives the running read up (`withDescriptions`' `stop`),
  so closing a document doesn't wait for a long read.
- `LogIndex` runs one pass at a time in a `BackgroundSlot` (`runPass`). A pass brings the
  indexes up to date, each over the range it doesn't cover yet: the offset index over the new
  bytes of the source, the filter index over the new records, the search index over the new
  rows of the main view; the stages take turns until none has anything left, a part at a time
  (`followRecords`) while another follows. A rebuild is the same pass from zero
  (`setViewFilter`, `setSearchFilter` clear and reset). A cancelled pass leaves what it did:
  a request that comes while one runs stops it and the next pass goes on, so a filter and a
  search asked for while the file loads run with the load. Don't add an operation that builds
  an index whole, apart from a pass.
- An anchor is taken while a pass runs too, as a request: `LogDocument.setAnchor` changes
  `_anchors` at once (the rows show the mark), queues the message (`_pendingAnchors`), stops
  the pass and gives the change to the index when it ends (`applyPendingAnchors`); the views
  built anew by a filter or a format asked for meanwhile take every anchor anyway.
  `LogIndex.updateAnchor` lists or unlists a message only where an index covers it (the
  `scanned` of its `MatchStage`): the pass lists the rest by its snapshot of the anchors. A
  row it adds or takes out of the filtered main view moves the positions the search covers
  with it. It tells the rows it changed (`AnchorRows`): in the answer of `setAnchor` when no
  pass ran, by `AnchorApplied` (the script's `onAnchorApplied`) when it was pending, so the
  tables edit their rows by what changed, not by counting rows that grow meanwhile. With
  anchors and no search the search stage still follows the load (`LogIndex.partOf`), not a
  filter alone, which would scan slower in parts: the search view
  lists them while the file loads (the machine's `ListingAnchors`).
  The anchors a file had last time (`importAnchors`, at open) are listed so too: a `quiet`
  search request (`PendingRequest`) builds the search stage anew with no operation told, so the
  view shows them as they come (`ContentGrown`) instead of a "Searching" it wasn't asked for.
- The operations the views see (`OperationStarted / Progress / Finished` of the load, the
  filter, the search) overlap. They are the document's: `LogIndex` reports only its own
  facts, `PassProgress` (its positions: bytes split, records the filter covers, rows the
  search covers; throttled, and every time the load reaches the end of its bytes or the
  filter covers the records after it), `IndexGrown` (rows its positions don't tell of) and
  `PassFinished`. `LogDocument`, which knows which operations run, makes them their
  progress and their ends on the UI thread (`domain/operation_progress`: a stage is as far
  as the one it follows) and decides when a view no operation fills is told
  `ContentGrown`; nothing about the operations is kept in the index. `OperationProgress`
  carries all of them in one event (events of one type override each other in the queue). `Document.dispatchEvents()` delivers
  the events on the UI thread. The load and the filter tell their end apart, as soon as they
  have nothing left: the file may be loaded while its filter still fills the main view (the
  main view machine goes on as `Filtering`, the same content). A failure is of a stage
  (`PassFinished.failed`): a filter or a search that fails leaves the file loading; a cancel
  names its operation (`Document.requestCancel(Operation)`).
- A source may grow (its bytes don't move): every open file does, `FileSource` follows it
  (`docs/stories/growing-file.md`). It is a `PolledSource`: `LogDocument.dispatchEvents()`
  polls it every `pollInterval` while no pass runs, through `LogIndex.poll` (the store owns
  the source; the index asserts no pass runs), then starts a pass when the index is
  `behind`; the views stay ready and `ContentGrown` tells them to count their rows.
  `ByteSource.complete` is "no byte is waited for now", not "never more": `FileSource` is
  complete once it didn't grow for `quietPeriod`, and not again when it grows. A record cut
  by the end waits while it isn't; once it is, the record is let out (`final_`: a text line
  is taken as it is, an incomplete DLT record dropped, the open messages of a
  `PartedFormat` closed), and `LogIndex.behind` starts a pass for it without new bytes. What
  was taken stays: `Records.decode` gives the format the data up to the next record (the
  last one: up to the bytes split when the `Records` was given), so a text record doesn't
  take the bytes written after it. A file truncated (`PolledSource.truncated`), or empty
  when opened and of another format than its name told by its first bytes
  (`LogDocument.detectAnew`; passes wait for them), is opened anew: the document publishes
  `ReopenWanted` and builds nothing more, `AppSession` opens it in its tab by the format
  choice of the document (`reopen`, the path of Retry; the script's `onDocumentReopened`).
  The user may pick a format (`AppSession.reopenAs`, `openFileAs(path, formatId)`, an empty id
  detects the format again, `openFile(path)` opens as it was last time: the factory
  gets `byHand`, `LogDocument` takes the variant and encoding of `registry.choiceFor` and no
  other format stands in for one that can't read the file; a `FormatException` says why:
  `unrecognized` (detection) or `unreadable` (the format asked for), the failure of the system
  is any other exception; `OpenResult.failureJson` carries the `kind`). A change of records
  drops the anchors of the file, the filters stay (`reopen`, `formatChangeOf`).
  A document is never given a format of other records in place: its holders keep the
  columns of the format they opened it with (`DocumentFilters`). But the id of a tab outlives
  its document: `DocumentStore.replace` may put a document with other columns under it, and
  whoever keeps state by that id (the rows and the column set of its tables) is told by
  `AppSession.reopen` (`ViewListeners.columnsChanged(docId)`, for the records changed only):
  a holder added later is told by it too, or paints the new rows by the old columns (a crash
  once). If it can't be opened, it
  is shown lost, with Retry. Room to grow: `utils/mapped_file` reserves address space after the file
  (`roomFor`) and maps the new pages there (`MappedFile.grow`), the slot of the fault
  handler growing with it. On Windows (placeholders, Windows 10 1803+) whole 64K pieces of
  the file at its open are a view, the rest and what is written later are read into private
  memory after it (`readTo`, at most `readPerGrow` a grow), and the fault handler guards the
  view only. Without room (an address space limit, an older Windows) a file is mapped as it
  is and doesn't grow.
- The filter and search indexes are built in parallel blocks on `std.parallelism`'s task pool
  (`utils/parallel_scan`), appended in order as the blocks before them are done; the offset
  index is built sequentially. A format and a filter are called from several threads. A block
  checks a cancel, a lost file, records closing and the stop of the scan (`ScanStop`: a
  failed delivery) every `stopCheckRecords` records, and the first three again before it is
  delivered (`Records.givesUp`): a block cut short is never delivered,
  the scan returns false. The index grows block by
  block while the scan runs: keep it so, the results are shown before the scan ends.
- `LogIndex` is the holder of its parts (`domain/index/`), which are not thread-safe: it owns
  the mutex, the worker and their lifetime. The parts:
  - `RecordStore` (`record_store`): the source, the format and the offset index, which only
    grows. The format may be replaced by one of the same records (`replaceFormat`, while no
    pass runs); a `Records` decodes by the format it was given with, so a reader of a lease
    goes on with the format of before. A format that is a `PartedFormat` (`log_core/log_format`: its records may be
    numbered parts of one message, or pieces of a text cut at a limit) has its parts joined into one record as they are found
    (`part_joiner`): `findRecords` asks the format, without the lock, what each record may
    be (`MarkedFormat.marksOf`, once a record for every question: a `RecordMark` byte a
    record of its `Bunch`), `append` asks `partOf` of those marked a part only, and of
    every record while a message of pieces is open (`PartJoiner.followsPieces`: what goes
    on with a cut piece has no mark). Every
    record goes to the offset index at once
    but the later parts of a message: they are fragments of its head (the joined bit of
    its `OffsetIndexItem`), a list in a table of the store (`Join`, `Fragment`), which
    `Records.decode` follows (`Records.partsOf`: how many parts a record is joined of).
    `length()` and `records()` stop before the head of the oldest message still open
    (`RecordStore.holding`): its text may still grow, and its join and fragments still
    change. The end of the data closes every message (a source
    may tell its end without more bytes: `LogIndex.behind` counts what is held then). An
    `append` that fails halfway leaves the store refusing every later one. A format that
    is a `TransferringFormat` (files its writers send in the log, the file transfer of
    DLT) has them cataloged as their records are appended (`transfers`): `append`
    asks `transferOf` of the records marked a transfer and gives the catalog the message
    with the number and offset of the record. The catalog keeps numbers only (the record
    that opened each transfer, the offsets of its packets in turn); `LogIndex.attachments`
    names them from the opening records and `writeAttachment` reads the bytes from the
    packets (`domain/attachments`: what a transfer is to the user), the list of the packets
    taken under the lock (`Transfers.inTurnOf`) and read apart from it: the packets in turn
    don't change. A pass publishes `AttachmentsChanged` when the catalog or its loaded state
    changed; the session writes a file of the bytes (`AppSession.saveAttachment`: beside it,
    then in its place). Its one promise
    across threads: the records below the length of a `Records` a reader was given are
    read by any number of threads while one writer appends after them. The holder gives a
    reader its `Records` (under the mutex, or by starting the thread or task that reads)
    and lets the store go (`release()`) only once no scan reads it: `LogIndex` joins its
    worker first, and a scan returns only when its blocks are done. Closing the store (the
    last `release()`) frees the offset index too: it is a class, and the GC doesn't see that
    memory. A reader on a
    thread of its own (another holder of the document) leases the records instead
    (`Document.leaseRecords`, `RecordsLease`, taken under the mutex): the store is counted,
    `LogIndex` and each lease, and the last to let it go closes it. Closing the document only
    marks the store closing (`Records.closing`) and doesn't wait for the leases: a reader of
    one may be waiting for the thread that closes it. A scan checks the mark with a cancel
    and a lost file;
  - `ViewIndexes` (`views`): the filter and search indexes, the rows of the two views;
  - `MatchStage` (`match_stage`): how far the filter or the search of a pass has got;
  - `scanMatches` (`match_scan`): the parallel scan of a range for the anchored and
    matching records, over `Records` only: what another reader of the records (a search
    of its own, apart from the views) scans with too. It takes the pool its blocks run
    on (the shared one by default): a reader that shouldn't slow the window down scans on a
    pool of its own, and folds likewise;
  - `foldRecords` (`record_fold`): the parallel fold of a range over `Records`, for another
    reader (a count by a value, the first and the last record of a group): each block folds
    into an accumulator of its own, merged in the order of the blocks (`parallelFold` of
    `utils/parallel_scan`), so nothing is decoded again on one thread. A reader apart from
    the window scans and folds on a pool of its own: on the shared one its blocks queue
    before those of an index, and closing a document waits for its index's scan;
  - `ProgressReporter` (`progress`): publishes the `PassProgress` of a pass, throttled.
- The indexes grow over `utils/chunked_array` (`domain/index/`):
  - they grow by chunks (mmap / VirtualAlloc) up to 2^32 entries;
  - entries never move, which is what lets the indexing thread read the offset index without
    the mutex while the UI thread reads under it;
  - the filter and search indexes are `BaseIndex!uint32_t`, 4 bytes a record found;
  - the offset index (`OffsetIndex` = `CompactOffsets`, `offset_index`) is an array of
    `OffsetIndexItem` to `RecordStore`, 4 bytes a record inside: blocks of 4096 records keep
    their first offset once (`_bases`), a record its distance from it in 30 bits, the joined
    bit and a far bit; a record over 1 GB past its block's start keeps its full offset in
    `_far` and its place there. An append writes the far offsets and the block starts first
    and the records last, at once: a failed one changes nothing a reader sees, and a block
    start it left is replaced. At most `maxAppend` records an append (a bunch). A template,
    so that reads are inlined into `record_store`.
- `scanRecords` can resume and leaves an incomplete last record for a later call, unless
  `final_` (the source is complete now): a growing file relies on it, and a stream will, so
  keep that contract.
- The view status shown to the user comes from the state machines `ui/main_view_fsm` and
  `ui/search_view_fsm` (on `utils/fsm`), free of Sciter so they can be unit-tested.
- A view shows its rows while an operation fills it. The contract is `dataVersion` of the
  view models: it changes when the content is replaced (a load, a filter, a search starts);
  under one version the content only grows, rows appended in order, none moved, so the table
  keeps its rows, scroll and selection and counts the new ones. The end of an operation keeps
  the version. The script grows a table on any view event of the same version, `ready` too:
  meant for sources that never end (story: `docs/stories/live-results.md`). One exception:
  an anchor adds or takes out the row of its message in place under the same version, while
  the view grows too. The script learns it from the answer of `setAnchor` (`rows`) or from
  `onAnchorApplied`, which the session queues before the view events of the same round
  (`AppSession.takeScriptCalls`): the table reads that row again (`anchorApplied`) before it counts
  the rows the view grew by.

## If You Need X, Start Here (backend)

- Opening a file, tabs, views, search, settings as the script sees them: `ui/app_session`
- The xcall dispatch: `ui/main_window`; the columns as JSON: `ui/columns_json`; the
  value of each column of a record by its kind, for any reader: `log_core/column_values`
- Columns of the table for a document: `ui/table_columns`, `log_core/column_layout`
- The log table: the core `ptable` (`Table`, `ColumnHost`), text columns `ptable_text`, the log's
  model, columns and look `ui/log_table/`, Sciter `ui/log_table_behavior` and `ui/sciter_table/`,
  the script's calls `ui/table_script` (`docs/stories/painted-table.md`)
- Settings model and recent files: `ui/app_settings`, `ui/recent_files`
- Filter panel commands: `ui/filter_commands`; search chips: `ui/search_chips`
- The menu: `ui/app_menu` (model), `ui/main_menu_loader` (native macOS)
- Indexes and background work: `domain/log_index`, `domain/index/`, `utils/background_slot`,
  `utils/parallel_scan`
- A document and its views, anchors: `domain/log_document`, `domain/document`,
  `domain/anchors`; the progress of its operations from the positions of the index:
  `domain/operation_progress`
- Formats and detection: `formats/registry` (see `.ai/knowledge/formats.md`)
- Files sent in a log (the file transfer of DLT): `formats/dlt/file_transfer`,
  `domain/index/transfers` (the catalog), `domain/attachments`, `AppSession.attachmentsJson`
- Backend texts for the user: `utils/ui_text`, `ui/translations` (see `.ai/knowledge/i18n.md`)
- Looking inside the running app (builds with `--debug-channel`): `ui/debug_channel`, `ui/debug_protocol`,
  `resources/debug-eval.js`, the client `scripts/utils/app.mjs` (`.ai/workflows/preview-ui.md`)
