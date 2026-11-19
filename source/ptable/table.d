//! The table that draws its rows itself: the part that knows what is where and what an input does,
//! free of any host. It reads the rows from a `TableModel` through a `RowCache`, the columns from a
//! `ColumnLayout`, measures text through a `TextMeasurer`, draws every part through a `Painter` on a
//! `Canvas`, and tells the host what it needs by `TableEvents`. The host feeds it the size, the mouse
//! and the keys. It reads none of the data the model attaches to rows and cells (`Extra`): that goes to the
//! painter as it is. See docs/stories/painted-table.md.
module ptable.table;

version (unittest) import ptable.testing : portsOf, withBoxes;
import ptable.column : TableColumn;
import ptable.columnset;
import ptable.endfollow : EndFollow, EndStep;
import ptable.layout;
import ptable.lookchange : LookChange;
import ptable.navigation;
import ptable.pointer;
import ptable.hitregion : Area, areaAt;
import ptable.rowcopy;
import ptable.framepainter : FramePainter, Picked;
import ptable.rowview : RowEnv, RowView;
import ptable.dragscroll : DragScroll;
import ptable.scrollmotion : CoastPolicy, ScrollMotion;
import ptable.rowpicker : PickPorts, RowPicker;
import ptable.tableselection : TableSelection;
import ptable.tablehit : CopyTarget, HitKind, PointerKind, TableHit;
import ptable.rowhits : RowHits;
import ptable.rowpicks : Pick;
import ptable.rowranges : RowRange;
import ptable.rowstore : RowStore;
public import ptable.tableports : TablePorts;
import ptable.memory : mallocAllocator;
import std.experimental.allocator : RCIAllocator;
import ptable.model;
import ptable.painter;
import ptable.ports;
import ptable.regions;
import ptable.rowcache;
import ptable.rowlayout;
import ptable.selection;
import ptable.scrollplace : CellPosition;
import ptable.viewport;

import std.algorithm.comparison : max, min;
import std.conv : to;
import std.math : ceil, floor, round;

public import ptable.navigation : Key;

/// What the table counts, for the checks of a host
struct TableStats
{
    size_t fetches; /// items read from the model
    size_t cachedRows;
    size_t frames; /// paints
    size_t rowsOnScreen;
    size_t first; /// the first item on the screen
}

/// What the table tells its host; every one may be left null
struct TableEvents
{
    /// The table wants to be painted again (a state changed)
    void delegate() invalidate;
    /// Only this area of the table (its own coordinates) is to be painted again: a row or a cell changed how it looks (a hover, a press,
    /// a step of an animation). Null: the host does not tell areas, `invalidate` is called instead.
    void delegate(Rect area) invalidateArea;
    /// A row was selected (a click, the keys, a drag over rows): the item and its id. `delayed`: a drag or a step of the keys moved it and it may
    /// move on, whoever follows it waits for it to rest (a click and a selection asked for are not)
    void delegate(size_t item, ulong rowId, bool delayed) rowSelected;
    /// A click (a press and a release without a drag) in a cell: the item and the column of the model. What it
    /// means (an anchor, a link) is the application's
    void delegate(size_t item, size_t column) cellClicked;
    /// A drag or a press needs the mouse even outside the table: the host captures it
    void delegate(bool on) capture;
    /// What a scroll bar shows changed (a scroll, another count): the host's bar is told it after a paint
    void delegate(ScrollMetrics metrics) scrolled;
    /// What a horizontal scroll bar shows changed (the columns' widths, a scroll sideways), in pixels: `total` is what the scrolling
    /// columns need, `visible` the room they have, `position` how far they are scrolled. After a paint, like `scrolled`.
    void delegate(ScrollMetrics metrics) scrolledX;
    /// The table wants a frame to go on (a drag scrolls the rows): the host calls `tick` with the time of the next
    /// frame and again for as long as `tick` says it wants one. Null: the host gives no frames, and a drag past the
    /// rows does not scroll them.
    void delegate() needFrame;
    /// The table follows the end of its rows now (`on`) or no more: it reached the end, or it was moved away from it. Told once for each change,
    /// after a paint
    void delegate(bool on) followingEnd;
}

// What the host was last told of the scrolls, to tell it again only when it changes
private struct ReportedScroll
{
    ScrollMetrics rows, columns;
}

final class Table
{
    /// Which place of the window is kept when the heights of the rows change (a font, the width of the window): null,
    /// the top edge of the first row. The host's policy: the selected row, the middle of the window.
    AnchorPolicy anchorPolicy;

    /// Where the coast after a pan ends: null, where its speed takes it. The host's policy: a row start (a setting).
    CoastPolicy coastPolicy;

    /// The table's events: set the ones the host listens to
    TableEvents events;


    private RowStore _store; // the rows kept, the model's columns and the layout, brought up to date
    private FramePainter _frame; // draws a frame from what the table gives it
    private RowHits _hits; // what a point of the table hits in the rows

    private RowViewport _viewport; // the window on the rows: what is on the screen and the scroll
    private ReportedScroll _reported; // what the host was told of the scrolls last
    /// The room, in pixels, a row that is brought into view is left from the edge it came from (a row picked by the keys, by a click on one cut by
    /// an edge, by a jump): 0, the row at the edge, by default
    double revealMargin = 0;

    private bool _followEndAble; // `followEnd`: the table may follow the end of its rows
    private EndFollow _follow; // whether it does now
    private ViewState _placed = ViewState(size_t.max, 0); // where the rows stood when the table last put them (invalid: not yet): another place is a move of another's
    private bool _newList = true; // the rows are other ones (or not yet any): the mode is read anew at the next paint
    private bool _toldFollowing; // what the host was told of the mode last

    private RowPicker _picker; // the rows picked and how the input picks them, the text selected, the press and the copy
    private ScrollMotion _motion; // the scrolls on the host's frames: a drag past the rows, the wheel's step, the coast

    this(TableModel model, ColumnLayout layout, TablePorts ports)
    {
        _store = new RowStore(model, layout, ports);
        _picker = new RowPicker(new TableSelection(new RowCopier(model, _store.columns, ports.copyFormat), ports.clipboard),
            PickPorts(&isVirtualItem, &rowAtHeight, &showRow, &toldRow, &invalidate));
        _viewport = new RowViewport(&_store.heightOf);
        _motion = new ScrollMotion;
        auto rows = new RowView(RowEnv(_store.columns, _store.space));
        _frame = new FramePainter(ports.painter, _store, rows, _store.space);
        _hits = new RowHits(_store, _viewport, rows);
        _store.listen((const ModelChange change) { modelChanged(change); }, (const LayoutChange change) { layoutChanged(change); });
    }

    /// Lets go of the model and the layout (a table that is dropped must be disposed first)
    void dispose()
    {
        _store.dispose(); // the memory goes back to the source now, not when the collector gets to the table
    }

    TableStats stats()
    {
        return TableStats(_store.cache.fetches, _store.cache.count, _frame.frames, _viewport.slots.length, _viewport.state.first);
    }

    /// The size of the table in dips
    void resize(double width, double height)
    {
        bool widthChanged;
        if (!_store.resize(width, height, widthChanged))
            return;
        if (widthChanged)
            _viewport.keepPlace(anchorPolicy); // the wrapped rows change their heights
        invalidate();
    }

    /// The look changed: a change of colors only repaints, one of the metrics reads the geometry, the fonts and
    /// every cell again (the host drops what it measured with the old fonts before)
    void restyle(LookChange change = LookChange.metrics)
    {
        if ((change & LookChange.metrics) == 0)
        {
            invalidate();
            return;
        }
        _viewport.keepPlace(anchorPolicy);
        _store.restyle();
        invalidate();
    }

    /// The table is to be painted again, nothing else changed (a flag of the host's painter)
    void repaint()
    {
        invalidate();
    }

    /// The cell under the mouse looks another way (what the painter decides by the world outside the table): only its place is painted again
    void updateHover()
    {
        if (_picker.hover.row >= 0)
            updateCell(cast(size_t) _picker.hover.row, _picker.hover.column);
    }

    /// The row `item` looks another way (its state, not its data: that is the model's `ModelChange.rows`): only its place is painted again.
    /// Nothing for a row that is not on the screen
    void updateRow(size_t item)
    {
        Rect area;
        if (rowArea(item, area))
            invalidateArea(area);
    }

    /// The cell of the column `defIndex` of the model in the row `item` looks another way: only its place is painted again
    void updateCell(size_t item, size_t defIndex)
    {
        Rect area;
        if (cellRect(item, defIndex, area))
            invalidateArea(area);
    }

    /// Where the cell of the column `defIndex` of the model in the row `item` is, in the table's coordinates (the scrolls counted in); false
    /// if the row is not on the screen or the column is not shown
    bool cellRect(size_t item, size_t defIndex, out Rect area)
    {
        Rect row;
        if (!rowArea(item, row))
            return false;
        foreach (c; places().columns)
            if (c.defIndex == defIndex)
            {
                area = Rect(c.x, row.y, c.width, row.h);
                return true;
            }
        return false;
    }

    // Where the row `item` is in the table's coordinates; false if it is not on the screen
    private bool rowArea(size_t item, out Rect area)
    {
        layoutIfNeeded();
        foreach (ref slot; _viewport.slots)
            if (slot.index == item)
            {
                const rows = _store.space.regions.rows;
                area = Rect(rows.x, rows.y + slot.top, rows.w, slot.height);
                return true;
            }
        return false;
    }

    private void invalidateArea(Rect area)
    {
        if (events.invalidateArea !is null)
            events.invalidateArea(area);
        else
            invalidate();
    }

    private void invalidate()
    {
        if (events.invalidate !is null)
            events.invalidate();
    }

    private void modelChanged(const ModelChange change)
    {
        if (_store.modelChanged(change))
            setSelection(false);
        if (change.kind == ModelChange.Kind.everything)
        {
            _motion.stop(); // the rows are other ones: what coasted along the old ones is over, they start at their top
            _viewport.forgetPlace(); // the place kept would be a row of the old list
            _viewport.dropPending();
            _viewport.scrollToRow(0, 0);
            _newList = true;
        }
        invalidate();
    }

    private void layoutChanged(const LayoutChange change)
    {
        if (_store.layoutChanged(change))
            setSelection(false); // the cells the text is picked by have moved
        invalidate();
    }

    // ---- what the table is made of ----

    // Everything a row or a hit needs, brought up to date: what the store keeps, then the window on the rows
    private void prepare()
    {
        _store.cache.beginPass(); // the rows of the last pass are let go: the model is asked again for what this one needs
        _store.ensure();
        _viewport.height(_store.space.regions.rows.h);
        _viewport.count(_store.itemCount);
        _viewport.restorePlace(); // the heights are known now
        _store.cache.fit(_viewport.slots.length); // the room of the rows near the window is kept for that many rows and a reserve
    }

    private ref const(Placements) places()
    {
        return _store.places();
    }

    // A row of the pass for a handler: the store is brought up to date first (a handler need not have been through `prepare`)
    private Entry* entry(size_t index)
    {
        _store.ensure();
        return _store.entry(index);
    }

    // Lays out the rows on the screen: a row seen may widen a column and narrow the flex one, then the rows
    // are laid out again
    private void layout()
    {
        prepare();
        _viewport.layoutSettled(() => _store.cache.growths);
    }

    // ---- scrolling ----

    /// The rows move by `pixels` (down is positive) at the next paint; what piled up stays within a screen
    void queueScroll(double pixels)
    {
        _motion.stop();
        prepare();
        _viewport.queueScroll(pixels);
        invalidate();
    }

    /// A step of the mouse wheel of `pixels` at `timestampMs` (the clock of `tick`): the rows glide to it on the frames
    /// of the host; it ends a coast against it and speeds up one along it, and is not counted while the fingers move
    /// the rows or a spin from before them coasts on (`ScrollMotion`); a host without frames moves them at the next paint
    void wheel(double pixels, double timestampMs)
    {
        prepare();
        if (events.needFrame is null)
            queueScroll(pixels);
        else if (_motion.wheel(pixels, timestampMs, _store.space.regions.rows.h))
            events.needFrame();
    }

    /// The fingers moved the rows by `pixels` on the trackpad at `timestampMs` (the clock of `tick`): they move now
    void pan(double pixels, double timestampMs)
    {
        _motion.dragStop(); // the fingers take over from a drag past the rows
        _motion.pan(pixels, timestampMs);
        prepare();
        _viewport.scrollBy(pixels, _store.fallbackHeight);
        invalidate();
    }

    /// The fingers left the trackpad at `timestampMs`: the rows coast by the speed of the last moves, on the frames of
    /// the host (none without `events.needFrame`); true if they coast
    bool panEnd(double timestampMs)
    {
        if (events.needFrame is null || !_motion.release(timestampMs, coastPolicy))
        {
            _motion.stop();
            return false;
        }
        events.needFrame();
        return true;
    }

    /// The rows move by `pixels` now
    void scrollBy(double pixels)
    {
        _motion.stop();
        prepare();
        _viewport.scrollBy(pixels, _store.fallbackHeight);
        invalidate();
    }

    /// The columns move sideways by `pixels` (right is positive), not past their ends: the scroll of the layout
    void scrollXBy(double pixels)
    {
        _store.ensure();
        setScrollX(places().scrollX + pixels);
    }

    // The columns stand `position` pixels scrolled sideways (0 .. what they need more than the room they have)
    private void setScrollX(double position)
    {
        import std.algorithm.comparison : max, min;

        _store.ensure();
        _store.layout.setScrollX(max(0.0, min(position, places().maxScrollX)));
    }

    /// What a horizontal scroll bar of the host shows, in pixels (see `TableEvents.scrolledX`)
    ScrollMetrics scrollMetricsX()
    {
        _store.ensure();
        return metricsOf(places());
    }

    /// The item `index` is the first row
    void scrollTo(size_t index)
    {
        _motion.stop();
        _viewport.scrollTo(index);
        invalidate();
    }

    /// The first item and the part of it scrolled away
    ViewState position() const
    {
        return _viewport.state;
    }

    /// Where the rows lie in the table (a scroll bar of the host runs along it)
    Rect rowsArea()
    {
        _store.ensure(); // the regions, not a new pass: a host asks this on every mouse move over its bar
        return _store.space.regions.rows;
    }

    /// What a scroll bar of the host shows (in items); `events.scrolled` tells when it changes
    ScrollMetrics scrollMetrics() const
    {
        return _viewport.metrics();
    }

    /// The table may follow the end of its rows (as `tail -f`, or a terminal, does): it does while the user has scrolled to the end, until they scroll up;
    /// a new list starts over (not following, unless all of it is in view). Off by default
    void followEnd(bool able)
    {
        _followEndAble = able;
        if (!able)
        {
            _follow = EndFollow.init;
            _toldFollowing = false;
        }
        _newList = true;
        invalidate();
    }

    /// Whether the table follows the end of its rows now. As the last paint left it
    bool isFollowingEnd() const
    {
        return _followEndAble && _follow.following;
    }

    /// The last row is the one at the bottom (the way "End" does): the table follows the end from then. With the time of the host the rows glide, as
    /// `scrollToPosition` does
    void scrollToEnd(double timestampMs = double.nan)
    {
        _motion.stop();
        prepare();
        const count = _store.itemCount;
        if (count == 0)
            return;
        auto at = firstVisible;
        at.row = count - 1;
        at.dy = _store.space.regions.rows.h - _store.heightOf(count - 1);
        scrollToPosition(at, timestampMs);
    }

    /// The width and the height of the room the rows lie in (the table less the header and what is around the rows)
    Size size()
    {
        const rows = rowsArea();
        return Size(rows.w, rows.h);
    }

    /// The height of the item `index` (it is read, if the table has not done that yet)
    double rowHeight(size_t index)
    {
        _store.ensure();
        return _store.heightOf(index);
    }

    // Whether the row is in the room of the rows at least in part: a row that ends where it begins or begins where it ends is not (a glide
    // ends within a hair of a pixel)
    private static bool inSight(ref const RowSlot slot, double height)
    {
        enum hair = 1e-6;
        return slot.top + slot.height > hair && slot.top < height - hair;
    }

    /// The items in sight, part of an item counts: `[first, past the last)`, empty if there are none. As the last paint left them
    size_t[2] partlyVisibleRows()
    {
        const height = _store.space.regions.rows.h;
        size_t[2] range;
        bool any;
        foreach (ref slot; _viewport.slots)
        {
            if (!inSight(slot, height))
                continue;
            if (!any)
                range[0] = slot.index;
            range[1] = slot.index + 1;
            any = true;
        }
        return range;
    }

    /// The first item in sight and the first column in sight, both may be partly gone: where they stand from the corner of the room of the rows
    /// (a negative `dy`, `dx`). As the last paint left them; the first item and column when none is in sight
    CellPosition firstVisible()
    {
        return cellInSight(false);
    }

    /// The last item in sight and the last column in sight, as `firstVisible`
    CellPosition lastVisible()
    {
        return cellInSight(true);
    }

    private CellPosition cellInSight(bool last)
    {
        _store.ensure();
        CellPosition at;
        const height = _store.space.regions.rows.h;
        foreach (ref slot; _viewport.slots) // a row that ends where the window begins or begins where it ends is not in sight
        {
            if (!inSight(slot, height))
                continue;
            at.row = slot.index;
            at.dy = slot.top;
            if (!last)
                break;
        }
        const p = places();
        foreach (ref c; p.columns)
        {
            if (c.area != Pin.none || c.x + c.width <= p.leftWidth || c.x >= p.leftWidth + p.middleWidth)
                continue;
            at.column = c.defIndex; // the scrolling columns that show at least a part, left to right
            at.dx = c.x - p.leftWidth;
            if (!last)
                break;
        }
        return at;
    }

    /// The top of the item `position.row` stands `position.dy` and the left of the column `position.column` `position.dx` from the corner of the room of the
    /// rows (a `dy` below the top shows the items before the row; the rows and the columns never go past their ends; a column that is pinned or that
    /// the model has not leaves the columns where they are). With the time of the host (`timestampMs`, the clock of `tick`) the rows glide to a place
    /// near, to a place far off they jump to a screen from it and glide the rest; without it they are moved now
    void scrollToPosition(CellPosition position, double timestampMs = double.nan)
    {
        import std.algorithm.comparison : max, min;
        import std.math : abs, isFinite, isNaN;

        _motion.stop();
        prepare();
        const row = min(position.row, _store.itemCount > 0 ? _store.itemCount - 1 : 0);
        if (events.needFrame !is null && timestampMs.isFinite)
        {
            layout();
            double top = _viewport.topOf(row);
            if (top.isNaN)
            {
                const room = _store.space.regions.rows.h;
                _viewport.scrollToRow(row, row > _viewport.state.first ? position.dy + room : position.dy - room);
                layout();
                top = _viewport.topOf(row);
            }
            if (!top.isNaN && top != position.dy)
            {
                const distance = top - position.dy; // not cut to a screen: it is at most two
                if (_motion.wheel(distance, timestampMs, max(_store.space.regions.rows.h, abs(distance))))
                    events.needFrame();
            }
        }
        else
            _viewport.scrollToRow(row, position.dy);
        const p = places();
        foreach (ref c; p.columns)
            if (c.defIndex == position.column && c.area == Pin.none)
                setScrollX(c.x - p.leftWidth + p.scrollX - position.dx); // the left of the column in the scrolling content, less where it is to stand
        invalidate();
    }

    // ---- painting ----

    /// Draws the table: the whole of it is (0, 0, width, height) of `canvas`
    void paint(Canvas canvas)
    {
        prepare();
        _viewport.applyPending(_store.fallbackHeight);
        layout();
        followStep();
        refreshHover(); // the rows may have moved under a mouse that did not
        const p = places();
        const picked = Picked(_picker.rows, _picker.currentRow, _picker.text.hasText, _picker.text.range, _picker.hover.row, _picker.hover.column,
            _picker.cellPress.row, _picker.cellPress.column);
        _frame.paint(canvas, _viewport.slots, p, picked);
        if (p.scrollX != _store.layout.scrollX)
            _store.layout.setScrollX(p.scrollX); // the scroll the columns have after the clamp: the layout keeps it, it does not run ahead
        const metrics = _viewport.metrics();
        if (metrics != _reported.rows)
        {
            _reported.rows = metrics;
            if (events.scrolled !is null)
                events.scrolled(metrics);
        }
        const across = metricsOf(p);
        if (across != _reported.columns)
        {
            _reported.columns = across;
            if (events.scrolledX !is null)
                events.scrolledX(across);
        }
    }

    // The table follows the end of its rows as a terminal does (`EndFollow`): where the rows stand now, if the table did not put them there, is a move
    // of another's; while following, the end is put in view again at every paint (a growth, a larger window, a row that came out taller)
    private void followStep()
    {
        if (!_followEndAble)
            return;
        const foreign = _viewport.state != _placed;
        const step = _follow.step(foreign, _viewport.endInView(), _newList);
        _newList = false;
        if (step == EndStep.stick)
            foreach (i; 0 .. 4) // a row that comes into view may be taller than it was guessed: laid out again until the end is in view
            {
                _viewport.scrollToEnd();
                layout();
                if (_viewport.endInView())
                    break;
            }
        _placed = _viewport.state;
        if (_toldFollowing != _follow.following)
        {
            _toldFollowing = _follow.following;
            if (events.followingEnd !is null)
                events.followingEnd(_toldFollowing);
        }
    }

    private static ScrollMetrics metricsOf(ref const Placements p)
    {
        import std.math : ceil, floor;

        return ScrollMetrics(cast(size_t) ceil(p.contentWidth), cast(size_t) floor(p.middleWidth), p.scrollX);
    }

    // The text position under the point (x, y) of the table; false with no rows
    private bool positionAt(double x, double y, out Position at)
    {
        return _hits.positionAt(x, y, _picker.rows, at);
    }

    private void setSelection(bool has, Selection selection = Selection.init)
    {
        if (_picker.text.setText(has, selection))
            invalidate();
    }

    /// Whether some text is selected
    bool hasTextSelected() const
    {
        return _picker.text.hasText;
    }

    /// Selects the part of the text under the point a double click (a word) or a triple click (the cell) takes
    bool selectAt(double x, double y, bool word)
    {
        layoutIfNeeded();
        size_t cellRow, cellColumn;
        if (clickableCellAt(x, y, cellRow, cellColumn))
            return true; // a double click on a cell of a clickable column selects nothing, and nothing else takes it
        Selection part;
        bool any;
        if (!_hits.partAt(x, y, word, _picker.rows, part, any))
            return false;
        if (any)
        {
            setSelection(true, part);
            if (!_picker.isSelected(part.anchor.row))
                _picker.pick(part.anchor.row, Pick.replace); // the click that began this double click let go of the row
        }
        return true;
    }

    // The rows are laid out at least once (a hit before the first paint)
    private void layoutIfNeeded()
    {
        if (_viewport.slots.length == 0)
            layout();
    }

    // Where a drag reaches, wherever the mouse is: see `RowHits.dragPositionAt`
    private bool dragPositionAt(double x, double y, out Position at)
    {
        return _hits.dragPositionAt(x, y, _picker.text.pressPosition.row, _picker.rows, at);
    }

    /// Selects the text from the point to the point, as a drag does
    void selectBetween(double x1, double y1, double x2, double y2)
    {
        layoutIfNeeded();
        Position a, b;
        if (positionAt(x1, y1, a) && positionAt(x2, y2, b))
            setSelection(true, Selection(a, b));
    }

    /// The text for the clipboard: the text selected, else the row selected. A cell selected whole (or a row) gives its
    /// full text, its head too (a date with the time), if `wholeCellsInFull`; else and a part of a cell as shown.
    wstring copyText(bool wholeCellsInFull = false)
    {
        prepare();
        const p = places();
        bool changed;
        return _picker.text.copyText(_store.columns.wanted(changed), p, wholeCellsInFull, _picker.ranges);
    }

    /// Puts on the clipboard what `target` says: the text selected (the rows if none), the rows picked, or the cell of the
    /// address (`row`, `column` of the model); cells and rows in full, heads too. True if something was copied
    bool copy(CopyTarget target = CopyTarget.text, size_t row = 0, size_t column = 0)
    {
        prepare();
        const p = places();
        bool changed;
        const wanted = _store.columns.wanted(changed);
        const text = target == CopyTarget.cell ? _picker.text.cellText(row, column, wanted)
            : _picker.text.copyText(wanted, p, true, _picker.ranges, target == CopyTarget.rows);
        _picker.text.toClipboard(text);
        return text.length > 0;
    }

    /// Picks every row (Cmd/Ctrl+A); the text selected is let go of, nothing scrolls
    void selectAll()
    {
        setSelection(false);
        _picker.selectAll(_store.itemCount);
    }

    /// What is at the point (x, y) of the table: the part, the row and the column, the text under it. Changes nothing: the owner
    /// of the menu decides what a click picks
    TableHit hitTest(double x, double y)
    {
        layoutIfNeeded();
        TableHit hit;
        hit.columnIndex = _store.columns.columnAt(places(), x);
        hit.column = _store.columns.idOf(hit.columnIndex);
        hit.hasText = _picker.text.hasText;
        final switch (areaAt(_store.space.regions, x, y))
        {
        case Area.header:
            hit.kind = HitKind.header;
            break;
        case Area.footer:
            hit.kind = HitKind.footer;
            break;
        case Area.around:
            hit.kind = HitKind.free;
            break;
        case Area.rows:
            hit.kind = HitKind.free;
            if (_hits.realRowAt(y, hit.row))
            {
                hit.kind = HitKind.cell;
                hit.picked = _picker.isSelected(hit.row);
                hit.onText = _hits.textAt(x, y, _picker.rows, hit.text.offset, hit.text.word);
            }
            break;
        }
        return hit;
    }

    /// The mouse is over the point (x, y) of the table, or over none (`x` NaN): the painter is told the row and the cell under it, and the
    /// table is painted again only when that is another cell
    void hoverAt(double x, double y)
    {
        layoutIfNeeded();
        _picker.hover.x = x;
        _picker.hover.y = y;
        const before = _picker.hover.row;
        if (refreshHover())
        {
            if (before >= 0)
                updateRow(cast(size_t) before); // the row the mouse left and the one it came to
            if (_picker.hover.row >= 0 && _picker.hover.row != before)
                updateRow(cast(size_t) _picker.hover.row);
        }
    }

    // The cell under the mouse where it was last seen: asked again after the rows moved under it. True if it is another cell
    private bool refreshHover()
    {
        const x = _picker.hover.x, y = _picker.hover.y;
        size_t row;
        const over = x == x && y == y && areaAt(_store.space.regions, x, y) == Area.rows && _hits.realRowAt(y, row);
        return over ? _picker.hover.set(row, _store.columns.columnAt(places(), x)) : _picker.hover.clear();
    }

    /// The stable id the model gave the row `item` (`RowData.id`); false if the row is not there (the rows changed since the click)
    bool rowId(size_t item, out ulong id)
    {
        auto e = entry(item);
        if (!e.valid)
            return false;
        id = e.data.id;
        return true;
    }

    /// Whether the cells of the column `defIndex` of the model are for a click (`ColumnDef.clickable`)
    bool isClickable(size_t defIndex)
    {
        return defIndex < _store.columns.length && _store.columns.def(defIndex).clickable;
    }

    /// The rows are other ones (a row came into the view or left it): nothing is picked, selected or hovered any more
    void forgetPicks()
    {
        setSelection(false);
        _picker.selectRow(-1, Pick.replace);
        _picker.hover.clear();
        _picker.hover.x = _picker.hover.y = double.nan;
    }

    /// What the model attached to the row `item` (`Extra.bits`), 0 for a row that is not there
    ulong rowExtra(size_t item)
    {
        auto e = entry(item);
        return e.valid ? e.data.extra.bits : 0;
    }

    /// The id of the column `defIndex` of the model
    string columnId(size_t defIndex)
    {
        return _store.columns.idOf(defIndex);
    }

    /// The pointer for the point (x, y): a hand over a cell of a clickable column (`ColumnDef.clickable`) of a real row, else the arrow.
    /// Cheap: asked at every move of the mouse
    PointerKind pointerAt(double x, double y)
    {
        layoutIfNeeded();
        size_t row, column;
        return clickableCellAt(x, y, row, column) ? PointerKind.hand : PointerKind.arrow;
    }

    // The point is on a cell of a real row in a clickable column: the row and the column of the model
    private bool clickableCellAt(double x, double y, out size_t row, out size_t column)
    {
        if (areaAt(_store.space.regions, x, y) != Area.rows || !_hits.realRowAt(y, row))
            return false;
        column = _store.columns.columnAt(places(), x);
        return column < _store.columns.length && _store.columns.def(column).clickable;
    }

    /// A click for a context menu on the row: if it is picked the rows stay, else it becomes the only one (the text selected
    /// stays too)
    void contextPick(size_t row)
    {
        _picker.pickForContext(row);
    }

    // ---- the rows ----

    /// The selected item, -1 if none
    long selected() const
    {
        return _picker.selected;
    }

    /// Selects an item alone and shows it (a virtual item is not selected); the host is told, even if it was selected
    void select(long index)
    {
        _motion.stop(); // the row is shown: no glide takes it away
        _picker.select(index);
    }

    /// The item `index` is picked alone, quietly: nobody is told, nothing is scrolled or shown (a script that follows a row of another table, or goes to
    /// a message, scrolls by itself). A virtual item and one the model has not are not picked
    void pickRow(size_t index)
    {
        if (index >= _store.itemCount || isVirtualItem(index))
            return;
        _picker.pick(index, Pick.replace);
        invalidate();
    }

    /// The current row, the one the other table follows: false if it is not picked (none, or taken out of the picked ones)
    bool currentRow(out long row) const
    {
        row = _picker.selected;
        return row >= 0;
    }

    /// Picks the item `index` by `mode` and shows it (`replace`: alone; `extend`: the rows from the anchor to it; `toggle`: it
    /// in or out; `extendAdd`: the rows from the anchor to it join the others). A virtual item is not picked. The host is told
    /// the current row when it changed, or always if `always`.
    void selectRow(long index, Pick mode, bool always = false, double timestampMs = double.nan)
    {
        _motion.stop();
        _picker.selectRow(index, mode, always, timestampMs);
    }

    /// Whether the item `index` is selected
    bool isSelected(size_t index) const
    {
        return _picker.isSelected(index);
    }

    /// How many items are selected
    ulong selectedCount() const
    {
        return _picker.count;
    }

    /// The items selected, as ranges, sorted: valid until the selection changes
    const(RowRange)[] selectedRanges() const
    {
        return _picker.ranges;
    }

    /// Lets go of the items selected
    void clearRows()
    {
        _picker.clear();
    }

    // What the picker asks of the table
    private bool isVirtualItem(size_t index)
    {
        return entry(index).data.kind == ItemKind.virtual_;
    }

    private bool rowAtHeight(double y, out size_t row)
    {
        return _hits.rowAt(y, row);
    }

    // The row is shown: laid out, and the rows go to it (by a glide on the frames of the host if it gave the time)
    private void showRow(size_t index, double timestampMs)
    {
        layout();
        revealRow(index, timestampMs);
    }

    private void toldRow(size_t index, bool delayed)
    {
        if (events.rowSelected is null)
            return;
        auto e = entry(index);
        events.rowSelected(index, e.valid ? e.data.id : 0, delayed);
    }

    // Shows the row `index`: the rows glide to it on the frames of the host if it gave the time (`timestampMs`, the clock of
    // `tick`), so the eye sees where they go; else, and for a row far off, they are moved now
    private void revealRow(size_t index, double timestampMs)
    {
        import std.algorithm.comparison : max;
        import std.math : abs, isFinite, isNaN;

        const plan = _viewport.revealPlan(index, revealMargin);
        if (!plan.needed)
            return;
        if (plan.top.isNaN)
            _viewport.scrollToRow(index, plan.dy); // far off: it stands there at once
        else if (events.needFrame !is null && timestampMs.isFinite)
        {
            const distance = plan.top - plan.dy;
            if (_motion.wheel(distance, timestampMs, max(_store.space.regions.rows.h, abs(distance))))
                events.needFrame();
        }
        else
            _viewport.scrollBy(plan.top - plan.dy, _store.fallbackHeight);
    }

    /// The row `index` is shown: when it is not in view the rows move so that it stands with `revealMargin` pixels left on the side it came
    /// from, or at the top of the window if it does not fit with them (see `RowViewport.revealPlan`). With the time of the host the rows glide
    void reveal(size_t index, double timestampMs = double.nan)
    {
        _motion.stop();
        layout();
        revealRow(index, timestampMs);
        invalidate();
    }

    // ---- input ----

    private void capture(bool on)
    {
        if (events.capture !is null)
            events.capture(on);
    }

    /// A press of the main button at the point; true if the table took it
    bool mouseDown(double x, double y, Pick mode = Pick.replace)
    {
        layoutIfNeeded();
        _motion.stop(); // a press that began before it never ended is over, a coast too, wherever it is pressed
        if (y < _store.space.regions.rows.y)
            return true;
        size_t cellRow, cellColumn;
        if (clickableCellAt(x, y, cellRow, cellColumn))
        {
            _picker.cellPress.begin(cellRow, cellColumn); // picks nothing and selects nothing: the host gets the click
            capture(true);
            updateCell(cellRow, cellColumn); // the cell shows that it is pressed
            return true;
        }
        setSelection(false);
        Position at;
        const has = positionAt(x, y, at);
        _picker.text.pressBegin(x, y, has, at, _store.columns.columnAt(places(), x));
        _picker.press(y, mode); // a mode picks the row at the press, a drag from it goes over rows
        capture(true);
        return true;
    }

    /// The mouse moved with a button down (after `mouseDown`, even outside the table)
    bool mouseMove(double x, double y)
    {
        if (!_picker.text.pressed)
            return false;
        if (!_picker.text.dragged(x, y))
            return true;
        const by = y - _store.space.regions.rows.y;
        const beyond = by < 0 ? by : by > _store.space.regions.rows.h ? by - _store.space.regions.rows.h : 0.0;
        if (events.needFrame !is null)
        {
            // the rows go on scrolling at a speed that grows with the distance, the mouse moving or not; the host
            // gives a frame if one is not on its way already, so a frame that never came is asked for again
            const rate = DragScroll.rateFor(beyond);
            _motion.dragTo(x, y, rate);
            if (rate != 0)
                events.needFrame();
        }
        if (_picker.rowDrag)
        {
            _picker.dragTo(y);
            return true;
        }
        Position at;
        if (_picker.text.pressHasPosition && dragPositionAt(x, y, at))
            setSelection(true, Selection(_picker.text.pressPosition, at));
        return true;
    }

    /// A frame of the host at `timestampMs` (milliseconds, from any start): the scrolls the table makes by itself move
    /// the rows (a drag past them, then the selection reaches under the mouse that has not moved; the coast after
    /// `panEnd`). True while the table wants the next frame: the host calls it again on the next one.
    bool tick(double timestampMs)
    {
        const step = _motion.tick(timestampMs);
        if (step.pixels != 0)
        {
            // the rows move now, by all of it (not through the wheel's queue, cut to a screen): the mouse is over the new
            // ones, a coast lands where it was aimed
            prepare();
            _viewport.scrollBy(step.pixels, _store.fallbackHeight);
            layout();
            invalidate();
        }
        Position at;
        if (step.dragging && _picker.rowDrag)
            _picker.dragTo(step.y);
        else if (step.dragging && _picker.text.pressHasPosition && dragPositionAt(step.x, step.y, at))
            setSelection(true, Selection(_picker.text.pressPosition, at));
        return step.active;
    }

    /// The window lost the mouse or the focus with a button down: the press is over, with no click and no scroll
    void cancelPress()
    {
        if (_picker.cellPress.active)
        {
            const pressedRow = _picker.cellPress.row, pressedColumn = _picker.cellPress.column;
            _picker.cellPress.cancel();
            capture(false);
            if (pressedRow >= 0)
                updateCell(cast(size_t) pressedRow, pressedColumn);
        }
        if (!_picker.text.pressed)
            return;
        _picker.text.pressCancel();
        _picker.endPress();
        _motion.dragStop();
        capture(false);
    }

    /// The button went up
    bool mouseUp(double x, double y)
    {
        if (_picker.cellPress.active)
        {
            size_t row, column;
            const over = clickableCellAt(x, y, row, column);
            capture(false);
            const pressedRow = _picker.cellPress.row, pressedColumn = _picker.cellPress.column;
            const click = _picker.cellPress.end(over, row, column);
            if (pressedRow >= 0)
                updateCell(cast(size_t) pressedRow, pressedColumn); // and that it is not any more
            if (click && events.cellClicked !is null)
                events.cellClicked(row, column);
            return true;
        }
        const rowDrag = _picker.rowDrag; // a press with a mode picked its row when it began
        const release = _picker.text.pressEnd();
        _picker.endPress();
        _motion.dragStop();
        if (!release.wasPressed)
            return false;
        capture(false);
        if (release.click)
        {
            if (!rowDrag)
            {
                _motion.stop();
                _picker.click(release.position.row);
            }
            if (events.cellClicked !is null)
                events.cellClicked(release.position.row, release.column);
        }
        return true;
    }

    /// A key; true if the table used it
    bool key(Key k, Pick mode = Pick.replace, double timestampMs = double.nan)
    {
        _motion.stop();
        layoutIfNeeded();
        if (k == Key.escape)
        {
            if (!_picker.escape())
                return false;
            invalidate();
            return true;
        }
        const count = cast(long) _store.model.itemCount();
        if (count == 0)
            return false;
        const page = cast(long) max(1UL, _viewport.slots.length - 1);
        const at = _picker.currentRow < 0 ? cast(long) _viewport.state.first : _picker.currentRow; // the row with the marker, picked or not
        setSelection(false);
        const to = navigate(k, at, count, page, (long i) => entry(cast(size_t) i).data.kind == ItemKind.virtual_);
        if (to >= 0)
            selectRow(to, mode, false, timestampMs);
        return true;
    }
}

version (unittest)
{
    import ptable.model : NumbersModel;
    import ptable.painter : RecordingCanvas;

    // every glyph 10 dips wide, a line 14 high, the ascent 11; never wraps by itself
    private final class FakeClipboard : Clipboard
    {
        wstring last;
        void writeText(const(wchar)[] text) { last = text.idup; }
    }

    private struct Fixture
    {
        NumbersModel model;
        Table table;
        RecordingCanvas canvas;
        FakeClipboard clipboard;
        ColumnLayout layout;
        size_t invalidations;
    }

    // the first column is clickable
    private class ClickableModel : NumbersModel
    {
        this(size_t count) { super(count); }
        override TableColumn[] columns()
        {
            auto columns = super.columns();
            columns[0].def.clickable = true;
            return columns;
        }
    }

    private Fixture make(size_t rows, double width = 400, double height = 121)
    {
        Fixture f;
        f.model = new NumbersModel(rows);
        f.layout = new ColumnLayout;
        f.clipboard = new FakeClipboard;
        f.canvas = new RecordingCanvas;
        f.table = new Table(f.model, f.layout, portsOf(new Painter, f.clipboard));
        f.table.resize(width, height);
        return f;
    }
}

@("Table: it paints the rows that fit under the header and reads only them from the model")
unittest
{
    auto f = make(1000); // 121 high: 21 of header, 100 of body, rows of 16
    f.table.paint(f.canvas);
    const stats = f.table.stats;
    assert(stats.rowsOnScreen == 7, "100 / 16 rounded up");
    assert(stats.cachedRows == 7, "the pass has read the rows of the window");
    assert(stats.fetches >= 7, "the model was asked for them");
}

@("Table: the wheel moves the rows by the pixels at the next paint, up to a screen")
unittest
{
    auto f = make(1000);
    f.table.paint(f.canvas);
    f.table.queueScroll(40);
    f.table.queueScroll(40);
    f.table.paint(f.canvas);
    assert(f.table.position.first == 5 && f.table.position.offset == 0, "80 px of rows of 16");
    f.table.queueScroll(100_000);
    f.table.paint(f.canvas);
    assert(f.table.position.first == 5 + 6, "a pile is cut to a screen of 100 px: 6 rows and 4 px");
    f.table.queueScroll(-100_000);
    f.table.queueScroll(-100_000);
    f.table.paint(f.canvas);
    assert(f.table.position.first == 5, "a screen up: 100 px of it piled up, 80 of them are rows");
}

@("Table: a click selects the row and tells it, the keys move the selection and scroll it into view")
unittest
{
    auto f = make(1000);
    f.table.paint(f.canvas);
    ulong told = ulong.max;
    f.table.events.rowSelected = (size_t item, ulong id, bool delayed) { told = id; };
    assert(f.table.mouseDown(30, 21 + 16 * 2 + 3)); // the third row
    assert(f.table.mouseUp(30, 21 + 16 * 2 + 3));
    assert(f.table.selected == 2 && told == 2);
    f.table.key(Key.down);
    assert(f.table.selected == 3);
    f.table.key(Key.end);
    f.table.paint(f.canvas);
    assert(f.table.selected == 999 && f.table.position.first > 990, "the end is shown");
    f.table.key(Key.escape);
    assert(f.table.selected == -1);
}

@("Table: select all picks every row without scrolling and lets go of the text; copying rows only ignores the text")
unittest
{
    auto f = make(50);
    f.table.paint(f.canvas);
    f.table.selectAll();
    assert(f.table.selectedCount == 50 && f.table.position.first == 0);
    f.table.key(Key.down, Pick.extend);
    assert(f.table.selectedCount == 2, "Shift with a key goes on from the first row, the anchor");
    f.table.selectAll();
    f.table.selectBetween(30, 21 + 3, 60, 21 + 3);
    assert(f.table.hasTextSelected);
    f.table.copy(CopyTarget.text);
    const text = f.clipboard.last;
    f.table.copy(CopyTarget.rows);
    assert(f.clipboard.last.length > text.length, "the rows, not the text");
    f.table.selectAll();
    assert(!f.table.hasTextSelected, "the text goes");
}

@("Table: the pointer is a hand over the cells of a clickable column, the arrow over the others, the header and below the rows")
unittest
{
    auto f = make(2, 400, 300);
    f.model = null;
    auto model = new ClickableModel(2);
    auto table = new Table(model, f.layout, portsOf(new Painter, f.clipboard));
    table.resize(400, 300);
    table.paint(f.canvas);
    assert(table.pointerAt(5, 21 + 3) == PointerKind.hand, "the first column: clickable");
    assert(table.pointerAt(395, 21 + 3) == PointerKind.arrow, "the second one is not");
    assert(table.pointerAt(5, 5) == PointerKind.arrow, "the header");
    assert(table.pointerAt(5, 250) == PointerKind.arrow, "below the rows");
}

@("Table: a press on a cell of a clickable column picks no row, selects no text and is a click for the host on the cell it began on; a double click selects nothing there")
unittest
{
    auto f = make(5, 400, 200);
    auto model = new ClickableModel(5);
    auto table = new Table(model, f.layout, portsOf(new Painter, f.clipboard));
    table.resize(400, 200);
    table.paint(f.canvas);
    size_t clickedRow = size_t.max, clickedColumn = size_t.max;
    table.events.cellClicked = (size_t item, size_t column) { clickedRow = item; clickedColumn = column; };
    const y = 21 + 16 * 2 + 3; // the third row
    assert(table.mouseDown(5, y) && table.mouseUp(5, y));
    assert(clickedRow == 2 && clickedColumn == 0 && table.selectedCount == 0 && !table.hasTextSelected, "a click, no row picked");
    clickedRow = size_t.max;
    table.mouseDown(5, y);
    assert(table.mouseUp(5, y + 16) && clickedRow == size_t.max, "released over another row: no click");
    assert(table.selectAt(5, y, true) && !table.hasTextSelected, "a double click selects nothing, and is taken");
    assert(table.mouseDown(60, y) && table.mouseUp(60, y) && table.selectedCount == 1, "another column: a click picks the row as before");
}

@("Table: the mouse over a cell is told to the painter, only the rows it leaves and comes to are painted again")
unittest
{
    auto f = make(5, 400, 200);
    f.table.paint(f.canvas);
    Rect[] areas;
    f.table.events.invalidateArea = (Rect area) { areas ~= area; };
    f.table.hoverAt(5, 21 + 3);
    assert(areas == [Rect(0, 21, 400, 16)], "the first row only");
    f.table.hoverAt(8, 21 + 5);
    assert(areas.length == 1, "the same cell: no news");
    f.table.hoverAt(395, 21 + 5);
    assert(areas.length == 2, "another column of the same row: the row once");
    f.table.hoverAt(5, 21 + 16 + 3);
    assert(areas == [Rect(0, 21, 400, 16), Rect(0, 21, 400, 16), Rect(0, 21, 400, 16), Rect(0, 37, 400, 16)], "the row left and the row come to");
    f.table.hoverAt(395, 5);
    assert(areas.length == 5 && areas[4] == Rect(0, 37, 400, 16), "over the header: the row is let go of");
    f.table.hoverAt(double.nan, double.nan);
    assert(areas.length == 5, "the mouse left: nothing to let go of");
}

@("Table: updateHover paints again the cell under the mouse only, none with the mouse elsewhere")
unittest
{
    auto f = make(10, 400, 200);
    f.table.paint(f.canvas);
    Rect[] areas;
    f.table.events.invalidateArea = (Rect area) { areas ~= area; };
    f.table.updateHover();
    assert(areas.length == 0);
    f.table.hoverAt(5, 21 + 16 * 2 + 3);
    areas = null;
    f.table.updateHover();
    assert(areas.length == 1 && areas[0].y == 21 + 16 * 2 && areas[0].h == 16 && areas[0].x == 0);
}

@("Table: cellRect is where a cell is on the screen, none for a row off it or a column that is not shown")
unittest
{
    auto f = make(100, 400, 200);
    f.table.paint(f.canvas);
    Rect area;
    assert(f.table.cellRect(3, 0, area) && area.y == 21 + 16 * 3 && area.h == 16 && area.x == 0 && area.w > 0);
    Rect second;
    assert(f.table.cellRect(3, 1, second) && second.x == area.right && second.y == area.y);
    f.table.scrollBy(32);
    f.table.paint(f.canvas);
    Rect scrolled;
    assert(f.table.cellRect(3, 0, scrolled) && scrolled.y == 21 + 16, "two rows went up");
    assert(!f.table.cellRect(0, 0, scrolled) && !f.table.cellRect(5000, 0, scrolled) && !f.table.cellRect(3, 77, scrolled));
}

@("Table: updateRow and updateCell paint again the place of a row or a cell only, none for a row off the screen, the whole table with no host to tell areas")
unittest
{
    auto f = make(100, 400, 200);
    f.table.paint(f.canvas);
    Rect[] areas;
    size_t whole;
    f.table.events.invalidate = () { ++whole; };
    f.table.updateRow(3);
    assert(whole == 1, "no host that tells areas: all of it");
    f.table.events.invalidateArea = (Rect area) { areas ~= area; };
    f.table.updateRow(3);
    assert(areas == [Rect(0, 21 + 16 * 3, 400, 16)]);
    f.table.updateCell(3, 1);
    assert(areas.length == 2 && areas[1].y == 21 + 16 * 3 && areas[1].h == 16 && areas[1].x > 0 && areas[1].w > 0 && areas[1].right == 400);
    f.table.updateRow(5000);
    f.table.updateCell(5000, 0);
    f.table.updateCell(3, 77);
    assert(areas.length == 2, "a row off the screen, a column that is not there: nothing");
}

@("Table: the cell under a still mouse is asked again when the rows scroll under it")
unittest
{
    static final class Spy : Painter
    {
        long hoverRow = -2;
        override void paintRow(Canvas canvas, ref const RowContext row)
        {
            if (row.state.hover)
                hoverRow = row.index;
        }
    }

    auto f = make(100, 400, 200);
    auto spy = new Spy;
    auto table = new Table(f.model, f.layout, portsOf(spy, f.clipboard));
    table.resize(400, 200);
    auto canvas = new RecordingCanvas;
    table.paint(canvas);
    table.hoverAt(5, 21 + 3); // the first row
    table.paint(canvas);
    assert(spy.hoverRow == 0);
    table.scrollBy(32); // two rows of 16 up
    table.paint(canvas);
    assert(spy.hoverRow == 2, "the mouse did not move: the row under it is the third one now");
}

@("Table: forgetPicks lets go of the rows, the text and the hover")
unittest
{
    auto f = make(50, 400, 200);
    f.table.paint(f.canvas);
    f.table.selectAll();
    f.table.selectBetween(30, 21 + 3, 60, 21 + 3);
    f.table.hoverAt(5, 21 + 3);
    f.table.forgetPicks();
    assert(f.table.selectedCount == 0 && !f.table.hasTextSelected);
    ulong id;
    assert(f.table.rowId(2, id) && id == 2, "a row that is there has its id");
    assert(!f.table.rowId(5000, id), "a row that is not there has none");
}

@("Table: below the rows, and in a table with no rows, the point is free space with the column under it")
unittest
{
    auto few = make(2, 400, 300);
    few.table.paint(few.canvas);
    auto hit = few.table.hitTest(30, 200);
    assert(hit.kind == HitKind.free && hit.column.length > 0, "below the last row");
    assert(few.table.hitTest(30, 21 + 3).kind == HitKind.cell);
    auto none = make(0);
    none.table.paint(none.canvas);
    assert(none.table.hitTest(30, 60).kind == HitKind.free && none.table.hitTest(30, 5).kind == HitKind.header);
}

@("Table: a context click is only asked what it hits; the owner of the menu picks, and copies from the address")
unittest
{
    auto f = make(50);
    f.table.paint(f.canvas);
    f.table.key(Key.down);
    f.table.key(Key.down, Pick.extend);
    assert(f.table.selectedCount == 2);
    auto hit = f.table.hitTest(30, 21 + 16 + 3);
    assert(hit.kind == HitKind.cell && hit.row == 1 && hit.picked && !hit.hasText && f.table.selectedCount == 2, "asking changes nothing");
    assert(hit.onText && hit.text.word.length > 0 && hit.column.length > 0);
    hit = f.table.hitTest(30, 21 + 16 * 6 + 3);
    assert(hit.kind == HitKind.cell && hit.row == 6 && !hit.picked && f.table.selectedCount == 2);
    hit = f.table.hitTest(30, 5);
    assert(hit.kind == HitKind.header && hit.column.length > 0, "the header: a column, no row");
    assert(f.table.hitTest(395, 21 + 16 * 6 + 3).kind == HitKind.cell && !f.table.hitTest(395, 21 + 16 * 6 + 3).onText, "right of the text");
    f.table.contextPick(1);
    assert(f.table.selectedCount == 2, "on a row picked the rows stay");
    f.table.contextPick(6);
    assert(f.table.selectedCount == 1 && f.table.isSelected(6));
    assert(f.table.copy(CopyTarget.cell, 6, 1) && f.clipboard.last == "row 6"w, "the cell of the address, not the rows picked");
    assert(f.table.copy(CopyTarget.rows) && f.clipboard.last == "6\trow 6"w);
    assert(!f.table.copy(CopyTarget.cell, 600, 1), "a row that is not there copies nothing");
}

@("Table: a drag selects the text across the cells, copying gives it by tabs and lines, a click drops it")
unittest
{
    auto f = make(100);
    f.table.paint(f.canvas);
    // the columns: N (width 10 + 7 by the longest text seen), text; the rows are at y = 21 + 16 i
    f.table.selectBetween(2, 21 + 3, 40, 21 + 16 + 3);
    assert(f.table.hasTextSelected);
    f.table.copy();
    assert(f.clipboard.last.length > 0 && f.clipboard.last[0 .. 1] == "0");
    f.table.mouseDown(5, 21 + 3);
    assert(!f.table.hasTextSelected, "a press drops the selection");
    f.table.mouseUp(5, 21 + 3);
}

@("Table: a double click selects what the column of the cell says is under the mouse (a box: the cell), a triple one the cell")
unittest
{
    auto f = make(10);
    f.table.paint(f.canvas);
    const left = 24.0 + 3; // the first column is at least 24 wide, the text is padded by 3
    f.table.selectAt(left + 4 * 10 + 2, 21 + 3, true);
    assert(f.table.copyText == "row 0", "a box has no words: the cell");
    f.table.selectAt(left + 2, 21 + 3, false);
    assert(f.table.copyText == "row 0", "the whole cell");
}

@("Table: the model growing or changing is told to the host to paint again")
unittest
{
    auto f = make(10);
    size_t invalidations;
    f.table.events.invalidate = () { invalidations++; };
    f.table.paint(f.canvas);
    f.model.append(5);
    assert(invalidations >= 1);
    f.table.paint(f.canvas);
    assert(f.table.stats.rowsOnScreen == 7);
}

@("Table: a column grows to its longest text and the layout is shared: another table sees it")
unittest
{
    auto f = make(1000);
    f.table.paint(f.canvas);
    const before = f.layout.width("n");
    assert(before > 0, "the digits were measured");
    f.table.scrollTo(990);
    f.table.paint(f.canvas);
    assert(f.layout.width("n") > before, "three digits are wider than one");
    auto other = new Table(f.model, f.layout, portsOf(new Painter));
    other.resize(400, 121);
    other.paint(f.canvas);
    assert(f.layout.width("n") >= before, "the second table does not shrink what the first grew");
}

@("Table: a hidden column is not drawn and not copied")
unittest
{
    auto f = make(10);
    f.table.paint(f.canvas);
    f.table.selectBetween(0, 21 + 3, 399, 21 + 3);
    assert(f.table.copyText == "0\trow 0");
    f.layout.setVisible("n", false);
    f.table.paint(f.canvas);
    f.table.selectBetween(0, 21 + 3, 399, 21 + 3);
    assert(f.table.copyText == "row 0", "no first column");
}

@("Table: a click in a cell tells which cell, a drag does not")
unittest
{
    auto f = make(100);
    f.table.paint(f.canvas);
    size_t clickedItem = size_t.max, clickedColumn = size_t.max;
    f.table.events.cellClicked = (size_t item, size_t column) { clickedItem = item; clickedColumn = column; };
    f.table.mouseDown(5, 21 + 16 + 3);
    f.table.mouseUp(5, 21 + 16 + 3);
    assert(clickedItem == 1 && clickedColumn == 0, "the first column of the model");
    clickedItem = size_t.max;
    f.table.mouseDown(100, 21 + 3);
    f.table.mouseMove(200, 21 + 3); // far enough: a drag
    f.table.mouseUp(200, 21 + 3);
    assert(clickedItem == size_t.max, "a drag is not a click");
}

@("Table: the footer and the padding of the table are painted by the painter, the rows lie between them")
unittest
{
    static class Padded : Painter
    {
        string[] seen;

        override TableGeometry geometry()
        {
            TableGeometry g;
            g.footerHeight = 20;
            g.padTop = 4;
            g.padBottom = 10;
            return g;
        }

        override void paintFooter(Canvas canvas, Rect area) { seen ~= "footer"; }
        override void paintEmpty(Canvas canvas, Rect area, EmptyZone zone) { seen ~= zone == EmptyZone.above ? "above" : "below"; }
    }

    auto model = new NumbersModel(1000);
    auto painter = new Padded;
    auto table = new Table(model, new ColumnLayout, portsOf(painter));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    assert(painter.seen == ["above", "below", "footer"]);
    // 200 - 21 header - 20 footer - 4 - 10 = 145 of rows: 10 rows of 16 (the last cut)
    assert(table.stats.rowsOnScreen == 10);
}

@("Table: a virtual item is not selected, the keys pass it")
unittest
{
    static class WithDays : TableModel
    {
        ModelListener[size_t] listeners;
        size_t itemCount() { return 20; }
        TableColumn[] columns() { return withBoxes([ColumnDef("t", "T", 24, true)]); }
        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            row.kind = index % 5 == 0 ? ItemKind.virtual_ : ItemKind.real_;
            row.id = index;
            row.cells = [CellData("x"w)];
            return true;
        }

        bool indexOf(ulong rowId, out size_t index) { index = cast(size_t) rowId; return true; }
        size_t subscribe(ModelListener l) { listeners[0] = l; return 0; }
        void unsubscribe(size_t h) {}
    }

    auto table = new Table(new WithDays, new ColumnLayout, portsOf(new Painter));
    table.resize(200, 200);
    table.paint(new RecordingCanvas);
    table.select(0);
    assert(table.selected == -1, "item 0 is a separator");
    table.select(1);
    assert(table.selected == 1);
    foreach (i; 0 .. 4)
        table.key(Key.down); // 2, 3, 4, then over the separator 5 to 6
    assert(table.selected == 6);
    table.key(Key.up);
    assert(table.selected == 4);
    table.key(Key.home);
    assert(table.selected == 1, "the first real row");
}

@("Table: the table does not read what the model attaches to a row: it reaches the painter as it was")
unittest
{
    static class Marked : NumbersModel
    {
        this() { super(5); }
        override bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            const ok = super.item(index, row, wanted);
            row.extra = Extra(0xABCD00 + index, null);
            row.cells[1].extra = Extra(7, null);
            return ok;
        }
    }

    static class Reading : Painter
    {
        ulong[] rows, cells;
        override void paintRow(Canvas canvas, ref const RowContext row) { rows ~= row.data.extra.bits; }
        override void paintCell(Canvas canvas, ref CellContext cell)
        {
            if (!cell.isHeader)
                cells ~= cell.data.extra.bits;
        }
    }

    auto painter = new Reading;
    auto table = new Table(new Marked, new ColumnLayout, portsOf(painter));
    table.resize(400, 121);
    table.paint(new RecordingCanvas);
    assert(painter.rows[0] == 0xABCD00 && painter.rows[4] == 0xABCD04);
    assert(painter.cells.length == 10 && painter.cells[1] == 7 && painter.cells[0] == 0);
}

@("Table: in a steady state a frame allocates nothing from the garbage collector, rows grouped by the heads of two columns too")
unittest
{
    import core.memory : GC;

    // the texts are made once, apart from the frames
    static final class Fixed : TableModel
    {
        wstring[] texts, times, shifts;
        TableColumn[] defs;
        ModelListener[size_t] listeners;

        this()
        {
            import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;

            foreach (i; 0 .. 100)
            {
                texts ~= "row number "w ~ (cast(wchar)('0' + i % 10)) ~ " of text that is long enough to wrap in a column of 200 dips"w;
                times ~= "d"w ~ (cast(wchar)('0' + i / 10)) ~ " 12"w; // a day of ten rows
                shifts ~= "s"w ~ (cast(wchar)('0' + i / 3 % 10)) ~ " 7"w; // a shift of three: now and then with the day
            }
            defs = withBoxes([ColumnDef("n", "N"), ColumnDef("s", "S"), ColumnDef("t", "Text", 24, true)]);
            defs[0].parts = new immutable HeadedCellPartsExtractor(&firstSpace);
            defs[1].parts = defs[0].parts;
        }

        size_t itemCount() { return 100; }
        TableColumn[] columns() { return defs; }
        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            row.kind = ItemKind.real_;
            row.id = index;
            row.cells.length = 3;
            row.cells[0] = CellData(times[index]);
            row.cells[1] = CellData(shifts[index]);
            row.cells[2] = CellData(texts[index]);
            return true;
        }

        bool indexOf(ulong rowId, out size_t index) { index = cast(size_t) rowId; return true; }
        size_t subscribe(ModelListener l) { return 0; }
        void unsubscribe(size_t h) {}
    }

    static final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    static final class Null : Canvas
    {
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto table = new Table(new Fixed, new ColumnLayout, portsOf(new Grouping));
    auto canvas = new Null;
    static void noFrame() {}
    import std.functional : toDelegate;
    table.events.needFrame = toDelegate(&noFrame);
    table.resize(300, 200);
    // the wheel, the fingers and their coast on frames, as a user scrolls
    double t = 0;
    void scrollAround(int frames)
    {
        foreach (i; 0 .. frames)
        {
            table.queueScroll(i % 2 ? 7 : -5);
            table.paint(canvas);
        }
        foreach (i; 0 .. frames)
        {
            table.wheel(i % 3 ? 300 : -200, t += 16);
            table.tick(t);
            table.paint(canvas);
        }
        foreach (i; 0 .. 10)
        {
            table.pan(i % 5 ? 12 : -8, t += 16);
            table.paint(canvas);
        }
        table.panEnd(t);
        foreach (i; 0 .. frames)
        {
            table.tick(t += 16);
            table.paint(canvas);
        }
    }

    scrollAround(30); // warms up: the columns, the arenas, the maps, the scratch arrays
    table.selectBetween(5, 30, 250, 120);
    table.paint(canvas);
    const before = GC.stats().allocatedInCurrentThread;
    scrollAround(100);
    assert(GC.stats().allocatedInCurrentThread == before, "a frame allocated from the garbage collector");
}

@("Table: all the memory of the rows comes from the allocator the host gave and goes back to it on dispose")
unittest
{
    import std.experimental.allocator : allocatorObject;
    import std.experimental.allocator.building_blocks.stats_collector : Options, StatsCollector;
    import std.experimental.allocator.mallocator : Mallocator;

    StatsCollector!(Mallocator, Options.bytesUsed) stats;
    auto allocator = allocatorObject(&stats);
    const base = stats.bytesUsed; // the object of the allocator is in it
    auto f = make(1000);
    auto ports = portsOf(new Painter);
    ports.memory = allocator;
    auto table = new Table(f.model, new ColumnLayout, ports);
    table.resize(400, 121);
    table.paint(f.canvas);
    assert(stats.bytesUsed > base, "the rows are kept in the host's memory");
    table.dispose();
    assert(stats.bytesUsed == base, "given back");
}

@("Table: the model is asked only for the visible columns, and asked again when one is hidden")
unittest
{
    static class Spy : NumbersModel
    {
        bool[] lastWanted;
        size_t calls;
        this() { super(50); }
        override bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            calls++;
            lastWanted = wanted.dup;
            return super.item(index, row, wanted);
        }
    }

    auto model = new Spy;
    auto layout = new ColumnLayout;
    auto table = new Table(model, layout, portsOf(new Painter));
    table.resize(400, 121);
    table.paint(new RecordingCanvas);
    assert(model.lastWanted == [true, true]);
    const before = model.calls;
    layout.setVisible("n", false);
    table.paint(new RecordingCanvas);
    assert(model.calls > before, "the rows are read again");
    assert(model.lastWanted == [false, true], "the hidden column is not asked for");
}

@("Table: a change of the colors only repaints, one of the metrics reads the geometry and the fonts again")
unittest
{
    class Counting : Painter
    {
        int geometries;
        override TableGeometry geometry()
        {
            ++geometries;
            return super.geometry();
        }
    }

    auto painter = new Counting;
    auto table = new Table(new NumbersModel(100), new ColumnLayout, portsOf(painter));
    int repaints;
    table.events.invalidate = () { ++repaints; };
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    const geometries = painter.geometries;
    repaints = 0;
    table.restyle(LookChange.colors);
    table.paint(new RecordingCanvas);
    assert(repaints == 1 && painter.geometries == geometries, "nothing measured is read again");
    table.restyle(LookChange.metrics);
    table.paint(new RecordingCanvas);
    assert(painter.geometries > geometries, "the geometry is read again (and the columns hear of it: a test of its own)");
}

@("Table: every column hears of a change of the look of metrics when the columns are read again, not of one of colors")
unittest
{
    import ptable.testing : BoxColumn;

    static final class Counting : BoxColumn
    {
        size_t looks;
        this(ColumnDef def) { super(def); }
        override void lookChanged() { ++looks; }
    }

    static final class Fixed : NumbersModel
    {
        TableColumn[] fixed;
        this() { super(100); fixed = [new Counting(ColumnDef("n", "N")), new Counting(ColumnDef("text", "Text", 24, true))]; }
        override TableColumn[] columns() { return fixed; }
    }

    auto model = new Fixed;
    auto table = new Table(model, new ColumnLayout, portsOf(new Painter));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    size_t looks(size_t i) { return (cast(Counting) model.fixed[i]).looks; }
    assert(looks(0) == 1 && looks(1) == 1, "told once when they are first read");
    table.restyle(LookChange.colors);
    table.paint(new RecordingCanvas);
    assert(looks(0) == 1, "colors: nothing to measure again");
    table.restyle(LookChange.metrics);
    table.paint(new RecordingCanvas);
    assert(looks(0) == 2 && looks(1) == 2, "metrics: told again");
}

@("Table: a change of the fonts keeps the first row on the screen where it was, the policy of the host may choose another place")
unittest
{
    auto model = new NumbersModel(1000);
    auto table = new Table(model, new ColumnLayout, portsOf(new Painter));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    table.scrollTo(500);
    table.paint(new RecordingCanvas);
    assert(table.stats.first == 500);
    model.line = 28; // a bigger font: the rows are taller
    table.restyle(LookChange.metrics);
    table.paint(new RecordingCanvas);
    assert(table.stats.first == 500, "the same row on top, not the same pixel offset of a list of other heights");

    model.line = 14;
    table.anchorPolicy = (const(RowSlot)[] slots) => ScrollAnchor(true, slots[$ - 1].index, 0, slots[$ - 1].top);
    const last = table.stats.first + table.stats.rowsOnScreen - 1;
    table.restyle(LookChange.metrics);
    table.paint(new RecordingCanvas);
    assert(table.stats.first + table.stats.rowsOnScreen - 1 >= last - 1, "the last row stays at its place by the policy");
}

@("Table: a header that the painter leaves to the font is as tall as the font needs, and follows it when it changes")
unittest
{
    class Auto : Painter
    {
        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.headerHeight = 0;
            return g;
        }
    }

    auto model = new NumbersModel(1000);
    auto table = new Table(model, new ColumnLayout, portsOf(new Auto));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    // header 14 + 2 * (1 + 2) = 20; rows of 16: 180 px hold 11 and a quarter
    assert(table.stats.rowsOnScreen == 12);
    model.line = 28;
    table.restyle(LookChange.metrics);
    table.paint(new RecordingCanvas);
    // header 28 + 6 = 34; rows of 30: 166 px hold 5 and a bit
    assert(table.stats.rowsOnScreen == 6);
}

@("Table: a new list of rows starts at its top and does not bring back the place kept for the old one")
unittest
{
    auto model = new NumbersModel(1000);
    auto table = new Table(model, new ColumnLayout, portsOf(new Painter));
    table.anchorPolicy = (const(RowSlot)[] slots) => ScrollAnchor(true, 3, 0, 0); // a place that is not where the window is
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    table.scrollTo(500);
    table.paint(new RecordingCanvas);
    model.line = 28;
    table.restyle(LookChange.metrics); // keeps the place: row 3
    model.tell(ModelChange(ModelChange.Kind.everything)); // and then a filter replaces the list
    table.paint(new RecordingCanvas);
    assert(table.stats.first == 0, "the new list starts at its top, not at the place kept (row 3) or where the window was (500)");
}

@("Table: a new list of rows starts at its top whatever coasted or was queued, the columns stay where they are")
unittest
{
    auto f = make(1000, 100, 121);
    f.layout.setWidth("n", 70);
    f.layout.setWidth("text", 150);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(400, 1, 0, 40)); // the text column 40 from the left: the columns are 30 sideways
    f.table.queueScroll(300);
    f.model.tell(ModelChange(ModelChange.Kind.everything));
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(0, 0, 0, -30), "the top of the new rows; the columns were scrolled 30 sideways and stay");
    f.model.append(5);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.row == 0, "rows that come after stay under the top");
}

@("Table: a hit right after a resize, before any paint, finds the row by the new size")
unittest
{
    auto f = make(1000);
    f.table.resize(400, 121);
    f.table.paint(f.canvas);
    f.table.resize(400, 301); // the rows are not laid out for it yet
    assert(f.table.selectAt(100, 280, false), "a point only the new height has");
    assert(f.table.copyText().length > 0 && f.table.hasTextSelected());
}

@("Table: a drag past the rows keeps scrolling on frames while the mouse is still, and the selection follows; letting go stops it")
unittest
{
    auto f = make(1000, 400, 121);
    int asked;
    f.table.events.needFrame = () { ++asked; };
    f.table.paint(f.canvas);
    f.table.mouseDown(50, 30);
    f.table.mouseMove(300, 60); // a drag, inside the rows
    assert(asked == 0 && !f.table.tick(0), "no scroll inside the rows");
    f.table.mouseMove(300, 300); // far below the rows
    assert(asked == 1, "one request for frames");
    f.table.mouseMove(300, 310);
    assert(asked == 2, "asked at each move: the host keeps one frame on its way, a frame that never came is asked for again");
    assert(f.table.tick(1000), "the first frame starts the clock");
    f.table.paint(f.canvas);
    const first = f.table.stats.first;
    assert(f.table.tick(1100), "wants the next frame");
    f.table.paint(f.canvas);
    assert(f.table.stats.first > first, "scrolled with the mouse still");
    assert(f.table.hasTextSelected(), "the selection reaches under the mouse");
    f.table.mouseUp(300, 310);
    assert(!f.table.tick(1200), "no frames after the button went up");
    f.table.mouseMove(300, 310);
    assert(!f.table.tick(1300));
}

@("Table: a press cancelled (the focus was lost) ends the scroll of a drag, and a new press starts clean")
unittest
{
    auto f = make(1000, 400, 121);
    int asked;
    f.table.events.needFrame = () { ++asked; };
    f.table.paint(f.canvas);
    f.table.mouseDown(50, 30);
    f.table.mouseMove(300, 60);
    f.table.mouseMove(300, 300);
    assert(f.table.tick(0) && asked >= 1);
    f.table.cancelPress();
    assert(!f.table.tick(16), "no frames after the press was cancelled");
    f.table.mouseMove(300, 310);
    assert(!f.table.tick(32), "and no drag without a press");
}

@("Table: a pan scrolls at once, a fast release coasts on frames and lands where the coast policy says")
unittest
{
    import std.math : isClose;

    auto f = make(1000, 400, 121);
    int asked;
    f.table.events.needFrame = () { ++asked; };
    f.table.paint(f.canvas);
    foreach (i; 1 .. 11)
        f.table.pan(16, i * 16.0); // a row of 16 px a frame: 1000 px a second
    f.table.paint(f.canvas);
    assert(f.table.position.first == 10 && f.table.position.offset == 0, "the pan moved the rows at once");
    double asks = 0;
    f.table.coastPolicy = (double distance) { asks = distance; return 80.0; }; // five rows
    assert(f.table.panEnd(160) && asked == 1, "a fast release coasts and asks for frames");
    assert(asks > 0);
    double t = 160;
    while (f.table.tick(t += 16) && t < 10_000)
        f.table.paint(f.canvas);
    f.table.paint(f.canvas);
    assert(f.table.position.first == 15 && isClose(f.table.position.offset + 1, 1), "landed on the distance of the policy");
    assert(!f.table.tick(t + 16), "and wants no more frames");
}

@("Table: the coast survives its own frames, the wheel takes over from it, a press, a key, a jump, a selection, the scroll bar stop it")
unittest
{
    static void coast(ref Fixture f)
    {
        foreach (i; 1 .. 11)
            f.table.pan(16, i * 16.0);
        assert(f.table.panEnd(160));
        assert(f.table.tick(176) && f.table.tick(192), "its own frames do not stop it");
    }

    auto f = make(1000, 400, 121);
    f.table.events.needFrame = () {};
    f.table.paint(f.canvas);
    coast(f);
    f.table.mouseDown(50, 60);
    f.table.mouseUp(50, 60);
    assert(!f.table.tick(208), "a press");
    coast(f);
    f.table.mouseDown(50, 10); // on the header
    f.table.mouseUp(50, 10);
    assert(!f.table.tick(208), "a press on the header");
    coast(f);
    f.table.key(Key.down);
    assert(!f.table.tick(208), "a key");
    coast(f);
    f.table.paint(f.canvas);
    const down = f.table.position.first;
    f.table.wheel(-100, 200); // a new turn of the wheel, up
    for (double t = 208; f.table.tick(t) && t < 5000; t += 16) {}
    f.table.paint(f.canvas);
    assert(f.table.position.first < down, "the wheel took over from the coast");
    coast(f);
    f.table.key(Key.down);
    coast(f);
    f.table.scrollTo(500);
    assert(!f.table.tick(208), "a jump");
    coast(f);
    f.table.select(700);
    assert(!f.table.tick(208), "a row selected from outside");
    coast(f);
    f.table.queueScroll(20);
    assert(!f.table.tick(208), "a scroll queued");
    coast(f);
    f.table.scrollToPosition(CellPosition(20, 0, 0, 0), double.nan);
    assert(!f.table.tick(208), "the scroll bar");
}

@("Table: a coast lands on its distance in a table lower than a frame's step")
unittest
{
    auto f = make(1000, 400, 41); // 20 of body: a step of a long coast is more than that
    f.table.events.needFrame = () {};
    f.table.paint(f.canvas);
    foreach (i; 1 .. 11)
        f.table.pan(16, i * 16.0);
    f.table.coastPolicy = (double distance) => 1600.0; // a hundred rows
    assert(f.table.panEnd(160));
    for (double t = 176; f.table.tick(t) && t < 10_000; t += 16)
        f.table.paint(f.canvas);
    f.table.paint(f.canvas);
    assert(f.table.position.first == 110, "no step was cut to the screen");
}

@("Table: a pan ends the scroll of a drag past the rows")
unittest
{
    auto f = make(1000, 400, 121);
    f.table.events.needFrame = () {};
    f.table.paint(f.canvas);
    f.table.mouseDown(50, 30);
    f.table.mouseMove(300, 60);
    f.table.mouseMove(300, 300);
    assert(f.table.tick(0));
    f.table.pan(5, 16);
    assert(!f.table.tick(32), "the fingers took over");
}

@("Table: a slow release or a host that gives no frames does not coast")
unittest
{
    auto f = make(1000, 400, 121);
    f.table.paint(f.canvas);
    foreach (i; 1 .. 11)
        f.table.pan(16, i * 16.0);
    assert(!f.table.panEnd(160), "no frames: no coast");

    f.table.events.needFrame = () {};
    foreach (i; 1 .. 11)
        f.table.pan(0.5, 1000 + i * 16.0);
    assert(!f.table.panEnd(1160), "too slow");

}

@("Table: a step of the wheel glides to its pixels on frames; a host without frames moves them at the next paint")
unittest
{
    auto f = make(1000, 400, 121);
    int asked;
    f.table.events.needFrame = () { ++asked; };
    f.table.paint(f.canvas);
    f.table.wheel(32, 1000);
    assert(asked == 1, "frames asked for");
    assert(f.table.tick(1000) && f.table.tick(1016));
    f.table.paint(f.canvas);
    assert(f.table.position.first == 0 && f.table.position.offset > 0, "a share of it at a frame");
    for (double t = 1032; f.table.tick(t) && t < 5000; t += 16) {}
    f.table.paint(f.canvas);
    assert(f.table.position.first == 2 && f.table.position.offset < 1e-9, "all of it in the end");

    auto still = make(1000, 400, 121);
    still.table.paint(still.canvas);
    still.table.wheel(32, 0);
    still.table.paint(still.canvas);
    assert(still.table.position.first == 2, "no frames: at the next paint");
}

@("Table: a row under a margin stands below it; a press in the margin finds no row")
unittest
{
    import ptable.testing : DatedModel;

    static final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    auto model = new DatedModel(100, 3);
    auto table = new Table(model, new ColumnLayout, portsOf(new Grouping, null));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    // header 21; row 0 (no margin: its head is in the header) 21..37; rows 1, 2 to 69; row 3: a margin 69..89, the row 89..105
    assert(table.selectAt(50, 30, false), "the first row");
    assert(!table.selectAt(50, 75, false), "the margin of the next day");
    assert(table.selectAt(5, 95, false), "the next day's first row");
}

@("Table: an empty table with grouped rows shows its header as it is, no head over it")
unittest
{
    import ptable.testing : DatedModel;

    static final class Seen : Painter
    {
        string[] calls;
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
        override void paintCell(Canvas canvas, ref CellContext cell) { if (cell.isHeader) calls ~= "title"; }
        override void paintGroup(Canvas canvas, ref GroupContext group) { calls ~= "group"; }
    }

    auto painter = new Seen;
    auto table = new Table(new DatedModel(0, 3), new ColumnLayout, portsOf(painter, null));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    assert(painter.calls == ["title", "title"], "the titles, no head");
}

@("Table: a change of the columns of the model (their order too) lets go of the text selected: its places are of the old cells")
unittest
{
    auto model = new NumbersModel(100);
    auto table = new Table(model, new ColumnLayout, portsOf(new Painter));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    table.selectBetween(4, 21 + 5, 30, 21 + 5);
    assert(table.hasTextSelected);
    model.tell(ModelChange(ModelChange.Kind.columns));
    assert(!table.hasTextSelected, "the columns were told to have changed");
}

@("Table: a cell selected whole is copied in full when the copy asks, as shown when not; a part of it as shown")
unittest
{
    import ptable.testing : DatedModel;

    auto clipboard = new FakeClipboard;
    auto table = new Table(new DatedModel(100, 3), new ColumnLayout, portsOf(new Painter, clipboard));
    table.resize(400, 200);
    table.paint(new RecordingCanvas);
    assert(table.selectAt(5, 21 + 5 + 16 * 4, false)); // the time cell of row 4
    assert(table.copyText(true) == "d1 t4" && table.copyText(false) == "t4" && table.copyText() == "t4");
    table.copy();
    assert(clipboard.last == "d1 t4");
    table.selectBetween(4, 21 + 5 + 16 * 4, 9, 21 + 5 + 16 * 4); // from before "t" to after it (the right half of the glyph)
    assert(table.copyText(true) == "t");
}

@("Table: a drag selects to the text nearest the mouse: over a margin, below and above the rows, outside the columns")
unittest
{
    import ptable.testing : DatedModel;

    static final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    auto table = new Table(new DatedModel(100, 3), new ColumnLayout, portsOf(new Grouping, null));
    table.resize(400, 200); // rows 21..200: row 0 21..37, 1, 2 to 69; row 3 a margin 69..89, the row 89..105; ...
    table.paint(new RecordingCanvas);
    table.mouseDown(5, 25); // the time of row 0
    table.mouseMove(5, 75); // down into the margin of row 3
    assert(table.copyText() == "t0\trow 0\nt1\trow 1\nt2\trow 2", "down to the end of the row above the margin");
    table.mouseUp(5, 75);

    table.mouseDown(9, 95); // after the first character of row 3 (the right half of the glyph)
    table.mouseMove(5, 75); // up into its margin
    assert(table.copyText() == "t", "up to the start of the row under the margin");
    table.mouseUp(5, 75);

    table.mouseDown(9, 95); // after the first character of row 3
    table.mouseMove(5, -50); // far above the rows, over the header and past it
    assert(table.copyText() == "t0\trow 0\nt1\trow 1\nt2\trow 2\nt", "up to the first row in sight, from its start");
    table.mouseUp(5, -50);

    table.mouseDown(5, 25);
    table.mouseMove(390, 500); // far below the rows and right of the columns
    assert(table.hasTextSelected() && table.copyText().length > "t0\trow 0\nt1".length, "to the last row in sight");
    table.mouseUp(390, 500);
}

@("Table: while a drag past the rows scrolls them, the selection goes on with the rows coming in, up to the first row")
unittest
{
    import ptable.testing : DatedModel;

    static final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    auto table = new Table(new DatedModel(100, 3), new ColumnLayout, portsOf(new Grouping, null));
    table.events.needFrame = () {};
    table.resize(400, 200);
    auto canvas = new RecordingCanvas;
    table.paint(canvas);
    table.mouseDown(5, 25);
    table.mouseMove(5, 260); // below the rows: they scroll
    for (double t = 0; t < 1000; t += 16)
    {
        table.tick(t);
        table.paint(canvas);
    }
    import std.algorithm.searching : canFind;
    const text = table.copyText();
    assert(table.position.first > 10, "scrolled");
    assert(text.canFind("t" ~ (table.position.first + 3).to!string), "the selection reaches the rows that came in");
    table.mouseUp(5, 260);

    // up past the top until the rows stop: the selection reaches the first row of all
    table.mouseDown(5, 120);
    table.mouseMove(5, -60);
    for (double t = 2000; t < 6000; t += 16)
    {
        table.tick(t);
        table.paint(canvas);
    }
    assert(table.position.first == 0 && table.position.offset == 0, "at the top");
    assert(table.copyText().length > 0 && table.copyText()[0 .. 3] == "t0\t", "from the first row of all");
}

@("Table: a long drag up past the rows of many groups paints every frame to the top")
unittest
{
    import ptable.testing : DatedModel;

    static final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    auto table = new Table(new DatedModel(3000, 3), new ColumnLayout, portsOf(new Grouping, null));
    table.events.needFrame = () {};
    table.resize(400, 300);
    auto canvas = new RecordingCanvas;
    table.scrollTo(2000);
    table.paint(canvas);
    table.mouseDown(5, 150);
    table.mouseMove(5, -200); // far above: the fastest scroll
    for (double t = 0; t < 120_000 && table.tick(t); t += 16)
        table.paint(canvas);
    table.paint(canvas);
    assert(table.position.first == 0 && table.copyText()[0 .. 3] == "t0\t", "at the top, selected from the first row");
}

@("Table: with margins the columns, the rows and a hit stand between them, and the margins are painted as room")
unittest
{
    class Margined : Painter
    {
        Rect[] rowAreas;
        Rect[] cellAreas;
        Rect[] beside;

        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.marginLeft = 20;
            g.marginRight = 10;
            return g;
        }

        override void paintRow(Canvas canvas, ref const RowContext row) { rowAreas ~= row.area; }
        override void paintCell(Canvas canvas, ref CellContext cell) { if (!cell.isHeader) cellAreas ~= cell.area; }
        override void paintEmpty(Canvas canvas, Rect area, EmptyZone zone) { if (zone == EmptyZone.marginLeft || zone == EmptyZone.marginRight) beside ~= area; }
    }

    auto painter = new Margined;
    auto table = new Table(new NumbersModel(100), new ColumnLayout, portsOf(painter));
    table.resize(400, 121);
    table.paint(new RecordingCanvas);
    assert(painter.rowAreas[0].x == 20 && painter.rowAreas[0].w == 370, "a row spans the block between the margins");
    assert(painter.cellAreas[0].x == 20, "the first column starts at the margin");
    assert(painter.beside == [Rect(0, 21, 20, 100), Rect(390, 21, 10, 100)], "the margins are painted as room");
    assert(table.rowsArea() == Rect(20, 21, 370, 100));
    // a press in the left margin is left of the columns: the first column, the first character
    assert(table.selectAt(3, 30, false), "a hit in the margin finds the row");
    assert(table.hasTextSelected());
}

@("Table: the host is told the current row: at once for a click and a selection asked for, delayed for a drag over rows and for the keys")
unittest
{
    auto f = make(100, 400, 301);
    struct Told { size_t item; bool delayed; }
    Told[] told;
    f.table.events.rowSelected = (size_t item, ulong id, bool delayed) { told ~= Told(item, delayed); };
    f.table.paint(f.canvas);
    const y = (size_t row) => 21.0 + 16 * row + 3;
    f.table.mouseDown(30, y(2));
    f.table.mouseUp(30, y(2));
    assert(told == [Told(2, false)], "a click follows at once");
    told = null;
    f.table.key(Key.down);
    assert(told == [Told(3, true)], "a step of the keys: the host waits for the row to rest");
    told = null;
    f.table.select(9);
    assert(told == [Told(9, false)], "a selection asked for");
    told = null;
    f.table.mouseDown(30, y(4), Pick.toggle);
    f.table.mouseMove(30, y(6));
    assert(told == [Told(4, false), Told(6, true)], "a press with a mode picks at once, the drag from it is delayed");
}

@("Table.pickRow: picks the row alone, tells nobody and scrolls nothing; the row the other table follows is the current one")
unittest
{
    auto f = make(100, 400, 121);
    size_t told;
    f.table.events.rowSelected = (size_t item, ulong id, bool delayed) { ++told; };
    f.table.paint(f.canvas);
    long row;
    assert(!f.table.currentRow(row), "nothing picked: no current row");
    f.table.pickRow(50);
    f.table.paint(f.canvas);
    assert(told == 0 && f.table.isSelected(50) && f.table.selectedCount == 1, "picked quietly");
    assert(f.table.firstVisible.row == 0, "and not shown: the place is where it was");
    assert(f.table.currentRow(row) && row == 50);
    f.table.pickRow(51);
    assert(!f.table.isSelected(50) && f.table.isSelected(51) && told == 0, "alone: the other is let go");
    f.table.mouseDown(30, 21 + 3, Pick.toggle); // Cmd+click takes the current row out of the picked ones
    f.table.mouseUp(30, 21 + 3);
    f.table.pickRow(1_000_000);
    assert(!f.table.isSelected(1_000_000) && f.table.selectedCount > 0, "a row that is not there is not picked");
}

@("Table.reveal: a row below the window comes in with the margin under it, one above with the margin over it; a row in view stays; a far one jumps there")
unittest
{
    auto f = make(1000, 100, 121); // the window is 100 high, the rows 16
    f.table.revealMargin = 24;
    f.table.paint(f.canvas);
    f.table.reveal(2);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(0, 0, 0, 0), "in view: nothing moves");
    f.table.reveal(8); // 128: below the window
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(4, 0, -4, 0), "row 8 at 60: 100 - 24 - 16, with 24 under it");
    f.table.reveal(2); // above the window
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(0, 0, -8, 0), "row 2 at 24, the margin over it (the first rows are 8 above)");
    f.table.reveal(500);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(496, 0, -4, 0), "far off below: the same place, by a jump");
    f.table.reveal(10);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(8, 0, -8, 0), "far off above: row 10 at 24");
}

@("Table.reveal: a row that does not fit the window with its margin is brought to the top; with no margin set it comes to the edge it came from")
unittest
{
    auto f = make(100, 100, 41); // the window is 20 high: a row of 16 and a margin of 24 do not fit
    f.table.revealMargin = 24;
    f.table.paint(f.canvas);
    f.table.reveal(5);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(5, 0, 0, 0));
    auto g = make(1000, 100, 121);
    g.table.paint(g.canvas);
    g.table.reveal(8); // no margin: the bottom of the row at the bottom of the window
    g.table.paint(g.canvas);
    assert(g.table.firstVisible == CellPosition(2, 0, -12, 0), "row 8 ends at 100: 84 + 16");
}

@("Table: a click on a row taller than the window that covers it does not scroll it, twice or more; one cut at an edge is brought to cover it")
unittest
{
    auto f = make(10, 100, 31); // the rows have 10 of the window and are 16 high
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(2, 0, -3, 0), double.nan); // row 2 covers the window: 3 above it, 3 below
    f.table.paint(f.canvas);
    const y = 21.0 + 5;
    foreach (i; 0 .. 3)
    {
        f.table.mouseDown(30, y);
        f.table.mouseUp(30, y);
        f.table.paint(f.canvas);
        assert(f.table.isSelected(2) && f.table.firstVisible == CellPosition(2, 0, -3, 0), "the same place after every click");
    }
    f.table.scrollToPosition(CellPosition(2, 0, 4, 0), double.nan); // it starts 4 under the top, ends 6 below the bottom
    f.table.paint(f.canvas);
    f.table.mouseDown(30, 21.0 + 6);
    f.table.mouseUp(30, 21.0 + 6);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(2, 0, 0, 0), "cut at the bottom: its top comes to the top of the window");
    f.table.scrollToPosition(CellPosition(2, 0, -12, 0), double.nan); // 12 of it are above: the last 4 are in the window (10 high), at the top
    f.table.paint(f.canvas);
    f.table.mouseDown(30, 21.0 + 2);
    f.table.mouseUp(30, 21.0 + 2);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(2, 0, 0, 0), "cut at the top: it does not fit, its top comes to the top of the window");
}

@("Table: a click on a row picks it alone, a click on a picked one too (lets go of nothing), one on another row picks only that")
unittest
{
    auto f = make(1000, 400, 300);
    f.table.paint(f.canvas);
    ulong[] told;
    f.table.events.rowSelected = (size_t item, ulong id, bool delayed) { told ~= id; };
    const y = (size_t row) => 21.0 + 16 * row + 3;
    f.table.mouseDown(30, y(2));
    f.table.mouseUp(30, y(2));
    assert(f.table.isSelected(2) && f.table.selectedCount == 1 && told == [2]);
    f.table.mouseDown(30, y(2));
    f.table.mouseUp(30, y(2));
    assert(f.table.isSelected(2) && f.table.selectedCount == 1, "a second click does not let go (for now)");
    f.table.mouseDown(30, y(3), Pick.replace);
    f.table.mouseUp(30, y(3));
    f.table.mouseDown(30, y(1), Pick.toggle);
    f.table.mouseUp(30, y(1));
    assert(f.table.selectedRanges == [RowRange(1, 1), RowRange(3, 3)]);
    f.table.mouseDown(30, y(3));
    f.table.mouseUp(30, y(3));
    assert(f.table.selectedRanges == [RowRange(3, 3)], "a click on a row among many picks only it");
    f.table.mouseDown(30, y(5));
    f.table.mouseUp(30, y(5));
    assert(f.table.selectedRanges == [RowRange(5, 5)]);
}

@("Table: Shift extends from the anchor, Shift and Cmd add the range to the rows, Cmd toggles a row")
unittest
{
    auto f = make(1000, 400, 300);
    f.table.paint(f.canvas);
    const y = (size_t row) => 21.0 + 16 * row + 3;
    f.table.mouseDown(30, y(1));
    f.table.mouseUp(30, y(1));
    f.table.mouseDown(30, y(4), Pick.extend);
    f.table.mouseUp(30, y(4));
    assert(f.table.selectedRanges == [RowRange(1, 4)] && f.table.selected == 4);
    f.table.mouseDown(30, y(6), Pick.toggle);
    f.table.mouseUp(30, y(6));
    f.table.mouseDown(30, y(7), Pick.extendAdd);
    f.table.mouseUp(30, y(7));
    assert(f.table.selectedRanges == [RowRange(1, 4), RowRange(6, 7)]);
    f.table.mouseDown(30, y(2), Pick.toggle);
    f.table.mouseUp(30, y(2));
    assert(f.table.selectedRanges == [RowRange(1, 1), RowRange(3, 4), RowRange(6, 7)] && !f.table.isSelected(2));
}

@("Table: a drag with Shift picks the rows between the press and the mouse, with Cmd over the rows picked before")
unittest
{
    auto f = make(1000, 400, 300);
    f.table.paint(f.canvas);
    const y = (size_t row) => 21.0 + 16 * row + 3;
    f.table.mouseDown(30, y(0));
    f.table.mouseUp(30, y(0));
    f.table.mouseDown(30, y(3), Pick.toggle);
    f.table.mouseMove(30, y(4));
    f.table.mouseMove(30, y(5));
    assert(f.table.selectedRanges == [RowRange(0, 0), RowRange(3, 5)], "the text is not selected: rows are");
    assert(!f.table.hasTextSelected);
    f.table.mouseMove(30, y(2));
    assert(f.table.selectedRanges == [RowRange(0, 0), RowRange(2, 3)], "back over the rows picked before the drag");
    f.table.mouseUp(30, y(2));
    f.table.mouseDown(30, y(5), Pick.replace);
    f.table.mouseUp(30, y(5));
    f.table.mouseDown(30, y(6), Pick.extend);
    f.table.mouseMove(30, y(8));
    f.table.mouseUp(30, y(8));
    assert(f.table.selectedRanges == [RowRange(5, 8)], "Shift: from the anchor, no rows kept");
}

@("Table: Shift and the keys extend the rows from the anchor, a key at the edge of the log tells nothing")
unittest
{
    auto f = make(10);
    f.table.paint(f.canvas);
    size_t told;
    f.table.events.rowSelected = (size_t item, ulong id, bool delayed) { ++told; };
    f.table.select(3);
    assert(told == 1);
    f.table.key(Key.down, Pick.extend);
    f.table.key(Key.down, Pick.extend);
    assert(f.table.selectedRanges == [RowRange(3, 5)] && f.table.selected == 5 && told == 3);
    f.table.key(Key.up, Pick.extend);
    assert(f.table.selectedRanges == [RowRange(3, 4)]);
    f.table.key(Key.down);
    assert(f.table.selectedRanges == [RowRange(5, 5)], "a plain key: only the row");
    f.table.key(Key.end);
    f.table.key(Key.end);
    assert(f.table.selected == 9 && told == 6 - 1 + 1 - 1 + 1, "the second End at the end of the log tells nothing");
}

@("Table: Shift and the arrows past the bottom of the window scroll by the row, and the way back shrinks the rows picked")
unittest
{
    auto f = make(100, 400, 121); // 100 of rows: 6 and a bit
    f.table.paint(f.canvas);
    f.table.select(3);
    foreach (i; 0 .. 8)
    {
        f.table.key(Key.down, Pick.extend);
        f.table.paint(f.canvas);
    }
    assert(f.table.selectedRanges == [RowRange(3, 11)] && f.table.selected == 11);
    assert(f.table.position.first == 6 || f.table.position.first == 5, "by the row, not by the page: the row 11 is at the bottom");
    foreach (i; 0 .. 5)
    {
        f.table.key(Key.up, Pick.extend);
        f.table.paint(f.canvas);
    }
    assert(f.table.selectedRanges == [RowRange(3, 6)] && f.table.selected == 6, "the rows are those between the anchor and the row");
    foreach (i; 0 .. 6)
    {
        f.table.key(Key.up, Pick.extend);
        f.table.paint(f.canvas);
    }
    assert(f.table.selectedRanges == [RowRange(0, 3)], "past the anchor the other way");
}

@("Table: a row picked by a key just past the window glides into view on the frames of the host, the rows picked are as at once")
unittest
{
    auto f = make(100, 400, 121);
    int asked;
    f.table.events.needFrame = () { ++asked; };
    f.table.paint(f.canvas);
    f.table.select(5);
    assert(f.table.position.first == 0);
    f.table.key(Key.down, Pick.extend, 1000);
    f.table.key(Key.down, Pick.extend, 1010);
    f.table.paint(f.canvas);
    assert(f.table.selectedRanges == [RowRange(5, 7)] && asked > 0, "picked now, the rows glide");
    const before = f.table.position;
    for (double t = 1016; f.table.tick(t) && t < 5000; t += 16) {}
    f.table.paint(f.canvas);
    assert(f.table.position.first >= before.first && f.table.position.first > 0, "and arrive: the row is at the bottom");
    const last = f.table.stats.first + f.table.stats.rowsOnScreen - 1;
    assert(last >= 7, "row 7 is shown");
}

@("Table: the row the keys move from is painted as focused, picked or not, and only that one")
unittest
{
    static final class Marks : Painter
    {
        size_t[] focused;
        override void paintRow(Canvas canvas, ref const RowContext row)
        {
            if (row.state.focused)
                focused ~= row.index;
        }
    }

    auto marks = new Marks;
    auto table = new Table(new NumbersModel(100), new ColumnLayout, portsOf(marks, null));
    table.resize(400, 121);
    table.paint(new RecordingCanvas);
    assert(marks.focused.length == 0, "no row is current yet");
    table.select(2);
    table.key(Key.down, Pick.extend);
    marks.focused = null;
    table.paint(new RecordingCanvas);
    assert(marks.focused == [3], "the row of the last pick, not the whole range");
    table.clearRows();
    marks.focused = null;
    table.paint(new RecordingCanvas);
    assert(marks.focused == [3], "still where the keys are, with no row picked");
}

@("Table: the keys move from the row with the marker, picked or not")
unittest
{
    auto f = make(100, 400, 300);
    f.table.paint(f.canvas);
    f.table.select(10);
    f.table.clearRows();
    f.table.key(Key.down);
    assert(f.table.selected == 11, "from the row 10 that was current, not from the top of the window");
    f.table.select(5);
    f.table.mouseDown(30, 21 + 16 * 5 + 3, Pick.toggle);
    f.table.mouseUp(30, 21 + 16 * 5 + 3);
    assert(!f.table.isSelected(5));
    f.table.key(Key.up);
    assert(f.table.selected == 4, "a row taken away by Cmd stays where the keys are");
}

@("Table: the columns wider than the room scroll sideways, not past their ends, and the host is told in pixels")
unittest
{
    auto f = make(100, 100, 121); // 100 wide: the columns need more
    f.layout.setWidth("n", 70);
    f.layout.setWidth("text", 150); // 70 + 150 = 220 wide
    ScrollMetrics told;
    size_t tells;
    f.table.events.scrolledX = (ScrollMetrics m) { told = m; ++tells; };
    f.table.paint(f.canvas);
    assert(told.total == 220 && told.visible == 100 && told.position == 0 && tells == 1);
    f.table.scrollXBy(30);
    f.table.paint(f.canvas);
    assert(told.position == 30 && tells == 2);
    f.table.scrollXBy(500);
    f.table.paint(f.canvas);
    assert(told.position == 120, "not past the end: 220 - 100");
    f.table.scrollXBy(-1000);
    f.table.paint(f.canvas);
    assert(told.position == 0);
    f.table.paint(f.canvas);
    assert(tells == 4, "nothing changed: not told again");
}

version (unittest)
{
    // the same place, give or take what a glide leaves of a pixel
    private bool near(CellPosition a, CellPosition b)
    {
        import std.math : abs;

        return a.row == b.row && a.column == b.column && abs(a.dy - b.dy) < 1e-4 && abs(a.dx - b.dx) < 1e-4;
    }
}

@("Table: the size of the room of the rows, the rows and the cells in sight, and the height of a row")
unittest
{
    auto f = make(100, 100, 121);
    f.layout.setWidth("n", 70);
    f.layout.setWidth("text", 150);
    f.table.paint(f.canvas);
    assert(f.table.size == Size(100, 100) && f.table.rowHeight(5) == 16);
    assert(f.table.partlyVisibleRows == [0, 7], "the seventh is cut at 100: [first, past the last)");
    assert(f.table.firstVisible == CellPosition(0, 0, 0, 0));
    assert(f.table.lastVisible == CellPosition(6, 1, 96, 70), "the last row starts at 96, the last column at 70");
    f.table.scrollXBy(30);
    f.table.queueScroll(40);
    f.table.paint(f.canvas);
    assert(f.table.partlyVisibleRows == [2, 9]);
    assert(f.table.firstVisible == CellPosition(2, 0, -8, -30), "rows of 16: 40 px is two rows and 8 px of the third; the columns went 30 sideways");
    assert(f.table.lastVisible == CellPosition(8, 1, 88, 40));
    f.layout.setPin("n", Pin.left);
    f.table.scrollToPosition(CellPosition(2, 1, -8, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.column == 1, "a pinned column does not scroll: the first of the scrolling ones");
}

@("Table: a table with no rows shows none")
unittest
{
    auto f = make(0, 100, 121);
    f.table.paint(f.canvas);
    assert(f.table.partlyVisibleRows == [0, 0]);
    assert(f.table.firstVisible == CellPosition(0, 0, 0, 0));
}

@("Table.scrollToPosition: the top of a row and the left of a column at dy and dx from the corner of the room of the rows")
unittest
{
    auto f = make(100, 100, 121);
    f.layout.setWidth("n", 70);
    f.layout.setWidth("text", 150);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(10, 1, -5, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(10, 1, -5, 0), "what the table reports is what it was told");
    f.table.scrollToPosition(CellPosition(10, 0, 20, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(8, 0, -12, 0), "row 10 is 20 below the top: the row before it whole and 4 of the one before");
    f.table.scrollToPosition(CellPosition(1, 0, 40, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.row == 0 && f.table.firstVisible.dy == 0, "the rows start sooner: they stay at their start");
    f.table.scrollToPosition(CellPosition(0, 1, 0, 30), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(0, 0, 0, -40), "the text column 30 from the left: the first column 40 of it is gone");
    f.table.scrollToPosition(CellPosition(0, 99, 0, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.dx == -40, "a column the model does not have: the columns stay");
    f.table.scrollToPosition(CellPosition(1_000_000, 1, 0, -1000), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.partlyVisibleRows[1] == 100 && f.table.firstVisible.column == 1, "not past the ends");
    f.layout.setPin("n", Pin.left);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(0, 0, 0, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.row == 0 && f.table.firstVisible.column == 1, "a pinned column has no place to scroll to: the columns stay");
}

@("Table.scrollToPosition: with the time of the host the rows glide to a place near, far off they jump to a screen from it and glide the rest")
unittest
{
    auto f = make(1000, 100, 121);
    f.table.events.needFrame = () {};
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(10, 0, 0, 0), 1000);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.row == 0, "near: not there yet, the frames take it");
    double now = 1000;
    while (f.table.tick(now += 16)) {}
    f.table.paint(f.canvas);
    assert(near(f.table.firstVisible, CellPosition(10, 0, 0, 0)), "landed where it was told");
    f.table.scrollToPosition(CellPosition(700, 0, 20, 0), now += 16);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible == CellPosition(692, 0, -8, 0), "far off: row 700 jumped to 20 + 100 from the top, a screen under its place; the glide is left");
    while (f.table.tick(now += 16)) {}
    f.table.paint(f.canvas);
    assert(near(f.table.firstVisible, CellPosition(698, 0, -12, 0)), "landed: row 700 is 20 from the top");
    f.table.scrollToPosition(CellPosition(3, 0, 0, 0), double.nan);
    f.table.paint(f.canvas);
    assert(f.table.firstVisible.row == 3, "no time: at once");
}

@("Table: following the end: a table that is at its end keeps its last row in view as the rows grow")
unittest
{
    auto f = make(30, 100, 121); // rows of 16 in a window of 100
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd, "at the top of a long list");
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd && f.table.partlyVisibleRows[1] == 30);
    f.model.append(10);
    f.table.paint(f.canvas);
    const last = f.table.lastVisible;
    assert(f.table.isFollowingEnd && last.row == 39 && last.dy + 16 <= 100 + 1e-6, "the new last row is in view, whole");
    f.model.append(1000);
    f.table.paint(f.canvas);
    assert(f.table.lastVisible.row == 1039, "a large growth: the end all the same");
}

@("Table: following the end: a table scrolled up stays where it is when the rows grow")
unittest
{
    auto f = make(30, 100, 121);
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(5, 0, 0, 0));
    f.table.paint(f.canvas);
    f.model.append(10);
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.firstVisible.row == 5 && f.table.firstVisible.dy == 0);
}

@("Table: following the end: a move up on the frame of a growth wins over the following")
unittest
{
    auto f = make(30, 100, 121);
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    f.model.append(5);
    f.table.queueScroll(-48); // three rows up, at the same paint
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.lastVisible.row < 34, "the user went up: it does not snap back");
    f.model.append(5);
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.lastVisible.row < 39);
}

@("Table: following the end: a jump or a bar that brings the end into view turns it on, one that leaves it turns it off")
unittest
{
    auto f = make(30, 100, 121);
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(24, 0, 0, 0)); // the last six rows fit under 100
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd);
    f.table.scrollToPosition(CellPosition(10, 0, 0, 0));
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd);
    foreach (i; 0 .. 6) // a step is cut to a window
    {
        f.table.wheel(100_000, 0);
        f.table.paint(f.canvas);
    }
    assert(f.table.isFollowingEnd && f.table.lastVisible.row == 29, "the wheel down to the end");
}

@("Table: following the end: a new list starts at the top and not following, a short one follows at once")
unittest
{
    auto f = make(1000, 100, 121);
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd);
    f.model.tell(ModelChange(ModelChange.Kind.everything));
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.firstVisible.row == 0 && f.table.lastVisible.row < 10, "the rows are other ones: the top, not following");
    f.model.count = 3;
    f.model.tell(ModelChange(ModelChange.Kind.everything));
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd, "three rows fit in the window: their end is in view");
    f.model.append(1000);
    f.table.paint(f.canvas);
    assert(f.table.lastVisible.row == 1002, "and the table follows the file that fills it");
}

@("Table: following the end: a resize and rows that turn out taller keep the end while following, and leave a table that is not")
unittest
{
    auto f = make(30, 100, 121);
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    f.table.resize(100, 221); // the window is 200 high now
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd && f.table.lastVisible.row == 29 && f.table.firstVisible.row == 29 - 12, "it stays at the end of the bigger window");
    f.model.line = 28;
    f.table.restyle(LookChange.metrics);
    f.table.paint(f.canvas);
    assert(f.table.isFollowingEnd && f.table.lastVisible.row == 29, "taller rows do not drop the mode");
    f.table.scrollToPosition(CellPosition(2, 0, 0, 0));
    f.table.paint(f.canvas);
    f.table.resize(100, 121);
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.firstVisible.row == 2, "not following: the resize leaves the place");
}

@("Table: following the end is off unless asked for; the host is told of a change once")
unittest
{
    auto f = make(30, 100, 121);
    f.table.paint(f.canvas);
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    f.model.append(10);
    f.table.paint(f.canvas);
    assert(!f.table.isFollowingEnd && f.table.lastVisible.row == 29, "nothing follows by default");
    auto told = new bool[0];
    f.table.events.followingEnd = (bool on) { told ~= on; };
    f.table.followEnd(true);
    f.table.paint(f.canvas);
    f.table.paint(f.canvas);
    f.table.scrollToEnd();
    f.table.paint(f.canvas);
    f.table.paint(f.canvas);
    f.model.append(3);
    f.table.paint(f.canvas);
    f.table.scrollToPosition(CellPosition(0, 0, 0, 0));
    f.table.paint(f.canvas);
    f.table.paint(f.canvas);
    assert(told == [true, false], "on at the end, off up: once each, not at every paint");
}

@("Table: the scroll sideways the layout keeps follows the clamp when the columns get narrower")
unittest
{
    auto f = make(100, 100, 121);
    f.layout.setWidth("n", 70);
    f.layout.setWidth("text", 150);
    f.table.paint(f.canvas);
    f.table.scrollXBy(500); // to the end: 120
    f.layout.setWidth("text", 100); // 170 wide: the end is 70
    f.table.paint(f.canvas);
    assert(f.layout.scrollX == 70 && f.table.scrollMetricsX().position == 70, "the layout does not keep what the columns cannot show");
}

@("Table: asking where the rows lie does not begin a new pass: the rows of the pass stay")
unittest
{
    auto f = make(100);
    f.table.paint(f.canvas);
    const read = f.table.stats.cachedRows;
    assert(read > 0);
    f.table.rowsArea();
    f.table.rowsArea();
    assert(f.table.stats.cachedRows == read, "the pass is the frame's: asking is not a frame");
}
