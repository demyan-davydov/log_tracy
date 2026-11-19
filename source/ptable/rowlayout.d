//! The layout of the rows a table draws itself (prototype of docs/experiments/2026-11-19-painted-rows-d.md),
//! the D port of a script prototype (removed): the rows on a screen from (first, offset), scrolling by pixels, the
//! thumb of the scrollbar. Pure: no Sciter; the heights come in as delegates.
module ptable.rowlayout;

/// The height of a row of `lines` lines: `line` px a line, `pad` above and below
double rowHeight(size_t lines, double line, double pad) pure nothrow @nogc @safe
{
    return lines * line + 2 * pad;
}

/// The position of a view of rows: the row `first` shifted up by `offset` px
struct ViewState
{
    size_t first;
    double offset = 0;
}

/// A row on the screen: its `index`, `top` (px from the top of the body) and `height`
struct RowSlot
{
    size_t index;
    double top, height;
}

alias HeightOf = double delegate(size_t) nothrow;

/// Lays out the rows on a body of `viewHeight` px of a view of `total` rows from `state`,
/// settling it: the offset within the first row, the first row not above the log's start, the
/// last row not above the bottom of the body. `rows` is filled.
void screenRows(ref ViewState state, ref RowSlot[] rows, double viewHeight, size_t total, scope HeightOf heightOf)
{
    rows.length = 0;
    assumeSafeAppend(rows);
    if (total == 0)
    {
        state = ViewState(0, 0);
        return;
    }
    settle(state, viewHeight, total, heightOf);
    double top = -state.offset;
    for (size_t index = state.first; index < total && top < viewHeight; index++)
    {
        const height = heightOf(index);
        rows ~= RowSlot(index, top, height);
        top += height;
    }
}

// Settles `state` within the rows: the offset in 0 .. the height of the first row, the first
// row not above the log's start, the last row not above the bottom of the screen
private void settle(ref ViewState state, double viewHeight, size_t total, scope HeightOf heightOf)
{
    if (state.first > total - 1)
        state.first = total - 1;
    void forward()
    {
        while (state.first < total - 1 && state.offset >= heightOf(state.first))
            state.offset -= heightOf(state.first++);
    }

    void back()
    {
        while (state.offset < 0)
        {
            if (state.first == 0)
            {
                state.offset = 0;
                break;
            }
            state.offset += heightOf(--state.first);
        }
    }

    forward();
    back();
    // the rows end above the bottom of the screen: pull them down, the first rows come in
    double bottom = -state.offset;
    size_t index = state.first;
    while (index < total && bottom < viewHeight)
        bottom += heightOf(index++);
    if (index == total && bottom < viewHeight)
    {
        state.offset -= viewHeight - bottom;
        back();
    }
}

/// `state` scrolled by `pixels` (down is positive), settled. A scroll of more than two
/// screens does not pass row after row (each row passed is a layout): it goes by the `mean`
/// height of a row, keeping the rest in pixels.
ViewState scrollBy(ViewState state, double pixels, double viewHeight, size_t total, scope HeightOf heightOf, double mean)
{
    if (total == 0)
        return ViewState(0, 0);
    if (mean > 0 && (pixels > 2 * viewHeight || pixels < -2 * viewHeight))
    {
        const rows = cast(long)(pixels / mean); // truncated toward zero
        const first = cast(long) state.first + rows;
        state.first = first < 0 ? 0 : cast(size_t) first;
        state.offset += pixels - rows * mean;
    }
    else
        state.offset += pixels;
    settle(state, viewHeight, total, heightOf);
    return state;
}

/// The thumb of a scrollbar of a `track` px long
struct Thumb
{
    bool visible;
    double top = 0, size = 0;
}

/// The thumb for `visible` rows of `total`, by the first row and the part of it scrolled
/// away; at the bottom of the track when the last row is the first to leave the screen.
/// `min` is the least size. Not visible when all the rows are on the screen.
Thumb thumbOf(size_t first, double offset, double firstHeight, size_t total, double track, size_t visible, double min_)
    pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max, min;

    if (!(total > visible) || !(track > 0))
        return Thumb.init;
    const size = min(track, max(min_, track * visible / total));
    const position = max(0.0, min(1.0, (first + offset / max(1.0, firstHeight)) / (total - visible)));
    return Thumb(true, (track - size) * position, size);
}

/// The row (a number with a fraction) at the top when the thumb stands at `top`
double rowAtThumb(double top, double track, double size, size_t total, size_t visible) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max, min;

    const room = track - size;
    if (!(room > 0))
        return 0;
    return max(0.0, min(1.0, top / room)) * (total - visible);
}

version (unittest)
{
    // rows of `height` px each, but the ones in `tall`
    private HeightOf heights(double height, double[size_t] tall = null)
    {
        return (size_t i) nothrow {
            if (auto p = i in tall)
                return *p;
            return height;
        };
    }
}

@("rowHeight: lines of `line` px with a pad above and below")
unittest
{
    assert(rowHeight(3, 14, 1) == 44);
    assert(rowHeight(1, 14, 1) == 16);
}

@("screenRows: the rows from the first one, the last one cut by the bottom")
unittest
{
    auto state = ViewState(2, 5);
    RowSlot[] rows;
    screenRows(state, rows, 50, 100, heights(20));
    assert(state == ViewState(2, 5));
    assert(rows.length == 3, "rows 2..4 cover 50 px from -5");
    assert(rows[0] == RowSlot(2, -5, 20));
    assert(rows[2].top == 35 && rows[2].top + rows[2].height > 50, "the third is cut by the bottom");
}

@("screenRows: an offset past the first row moves on to the next ones")
unittest
{
    auto state = ViewState(0, 45);
    RowSlot[] rows;
    screenRows(state, rows, 50, 100, heights(20));
    assert(state.first == 2 && state.offset == 5, "45 px is two rows and 5 px");
}

@("screenRows: a negative offset moves back, not above the start of the log")
unittest
{
    RowSlot[] rows;
    auto state = ViewState(3, -30);
    screenRows(state, rows, 50, 100, heights(20));
    assert(state.first == 1 && state.offset == 10, "30 px back is a row and 10 px");
    state = ViewState(0, -30);
    screenRows(state, rows, 50, 100, heights(20));
    assert(state == ViewState(0, 0), "the log starts here");
}

@("screenRows: the end of the log is pulled down to the bottom of the screen")
unittest
{
    RowSlot[] rows;
    auto state = ViewState(9, 0); // one row of 10 of 20 px: the screen of 50 px has a gap
    screenRows(state, rows, 50, 10, heights(20));
    assert(rows[$ - 1].index == 9);
    assert(rows[$ - 1].top + rows[$ - 1].height == 50, "the last row ends at the bottom");
}

@("screenRows: no rows, no layout")
unittest
{
    RowSlot[] rows;
    rows ~= RowSlot(1, 2, 3);
    auto state = ViewState(5, 7);
    screenRows(state, rows, 50, 0, heights(20));
    assert(rows.length == 0 && state == ViewState(0, 0));
}

@("screenRows: rows of different heights")
unittest
{
    RowSlot[] rows;
    auto state = ViewState(0, 0);
    double[size_t] tall = [1: 50.0];
    screenRows(state, rows, 100, 20, heights(20, tall));
    assert(rows.length == 4, "the fourth starts at 90, above the bottom");
    assert(rows[1] == RowSlot(1, 20, 50));
    assert(rows[2] == RowSlot(2, 70, 20));
}

@("scrollBy: by pixels row after row")
unittest
{
    auto state = scrollBy(ViewState(0, 0), 25, 100, 1000, heights(20), 20);
    assert(state == ViewState(1, 5));
    state = scrollBy(state, -10, 100, 1000, heights(20), 20);
    assert(state == ViewState(0, 15));
}

@("scrollBy: a far scroll goes by the mean height of a row")
unittest
{
    size_t asked;
    auto counting = (size_t i) nothrow { asked++; return 20.0; };
    const state = scrollBy(ViewState(0, 0), 20_000, 100, 100_000, counting, 20);
    assert(state.first == 1000 && state.offset == 0, "20000 px of 20 px rows");
    assert(asked < 50, "no row passed one by one");
}

@("thumbOf: nothing to scroll has no thumb")
unittest
{
    assert(!thumbOf(0, 0, 20, 10, 200, 10, 24).visible);
    assert(!thumbOf(0, 0, 20, 50, 0, 10, 24).visible, "no track");
}

@("thumbOf: the size by the visible part, the place by the first row")
unittest
{
    const top = thumbOf(0, 0, 20, 100, 200, 10, 24);
    assert(top.visible && top.top == 0);
    assert(top.size == 24, "10 of 100 of 200 px is 20, the least is 24");
    const end = thumbOf(90, 0, 20, 100, 200, 10, 24);
    assert(end.top == 200 - 24, "the last screen: the thumb is at the bottom");
    const middle = thumbOf(45, 10, 20, 100, 200, 10, 24);
    assert(middle.top > 0 && middle.top < end.top);
}

@("rowAtThumb: the thumb at the ends is the first row and the last screen")
unittest
{
    assert(rowAtThumb(0, 200, 24, 100, 10) == 0);
    assert(rowAtThumb(176, 200, 24, 100, 10) == 90);
    assert(rowAtThumb(500, 200, 24, 100, 10) == 90, "past the track: the end");
    assert(rowAtThumb(10, 24, 24, 100, 10) == 0, "no room to move");
}
