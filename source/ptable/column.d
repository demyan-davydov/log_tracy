//! What a table knows of its columns: their layout data (`ColumnDef`) and this interface. A column (text,
//! a mark, a picture) measures and draws its cells, its title and the head of a group, answers where a point is in a cell, which
//! rectangles a range of it takes, what text a range is and what a double click selects. A position in a cell (`Position.at`) is a number only the content
//! understands; the table orders positions, keeps them as the selection and gives them back. The
//! style of a cell is the business of its content (a text content holds its fonts and colors): the table
//! passes no style. See docs/stories/painted-table.md.
module ptable.column;

import ptable.cellparts : CellPartsExtractor, trivialCellParts;
import ptable.layout : ColumnDef;
import std.typecons : Rebindable;
import ptable.memory : Arena, Buffer;
import ptable.model : CellData, Fragment;
import ptable.painter : CellContext, RowState;
import ptable.ports : Canvas, Color, FontId, Rect;

/// A place in the content of the table: the row, the column and a position in the cell that only its content reads
struct Position
{
    enum size_t begin = 0; /// before everything in the cell
    enum size_t end = size_t.max; /// after everything in the cell

    size_t row;
    size_t col; /// the place of the cell among the selectable cells of its row, as they stand on the screen
    size_t at; /// a place between two parts of the content (a caret in a text: 0 before the first character)

    /// Order by the row, then the column, then the place in the cell
    int opCmp(const Position other) const pure nothrow @nogc @safe
    {
        if (row != other.row)
            return row < other.row ? -1 : 1;
        if (col != other.col)
            return col < other.col ? -1 : 1;
        return at < other.at ? -1 : at > other.at ? 1 : 0;
    }
}

/// What a content is given of a cell: where it stands, what the model gave for it (the table never reads `data.extra`), the parts
/// of its text the model marks
struct CellInput
{
    size_t row;
    uint col;
    const(CellData)* data;
    const(Fragment)[] fragments;
}

/// What a content says of a cell by the rules of HTML: the least width it can be shown in without breaking what cannot
/// be broken (the longest word), the width it takes with no wrap at all, and its height in the width asked
struct Measured
{
    double minWidth = 0, maxWidth = 0, height = 0;
}

/// How a cell is to be drawn now: the part of it that is on the screen, the selected range of it, what the mouse does
struct DrawState
{
    Rect area, clip;
    RowState row; /// the state of the row the cell is in (selected, odd, under the mouse, current)
    bool hover, pressed; /// the mouse over this cell, the button down on it
    bool hasSelection;
    uint selectionFrom, selectionTo; /// positions in the cell, in order
}

/// How a cell is laid out in the width of its column: how high it is, its room around its content with it. What the column laid out (the lines
/// of a text) it keeps itself or lays out again where it draws and hit-tests
struct CellLayout
{
    double height = 0;
}

/// What a double click selects: the word under the point, the line, the whole cell
enum Unit : ubyte
{
    word,
    line,
    cell,
}

/// How a title is to be drawn now
struct HeaderState
{
    bool hover, pressed;
}

/// The head a group of rows is made by (a date over its rows) as the column that groups gives it
struct GroupInput
{
    const(wchar)[] head;
}

/// A column of the table. One object serves a column: it holds its own style, the data of a cell comes with each call. The
/// calls of changes and the title and the head of a group have an empty default: a column that keeps nothing between calls
/// ignores the first and has no title or head to draw.
class TableColumn
{
    /// What the layout reads: the id, the title, the least width, whether it takes the rest
    ColumnDef def;

    /// What a cell of it consists of: a head the rows are grouped by and the body it shows; null: all body (read it
    /// through `cellParts`)
    Rebindable!(immutable CellPartsExtractor) parts;

    this(ColumnDef def)
    {
        this.def = def;
    }

    /// What a cell of the column consists of, never null
    final immutable(CellPartsExtractor) cellParts() const nothrow @nogc @safe
    {
        return parts !is null ? parts : trivialCellParts;
    }

    /// The column with the parts `parts` its cells consist of (a column that groups the rows by the heads of its cells)
    final TableColumn withParts(immutable CellPartsExtractor parts) nothrow @nogc @safe
    {
        this.parts = parts;
        return this;
    }

    /// The cell laid out in `width` (the room of its text), in `arena`; one line by default
    CellLayout layout(ref const CellInput cell, double width, ref Arena arena)
    {
        return CellLayout.init;
    }

    /// The back of the cell under the text selected (the table draws the selection between the two): what its fragments mark. Asked only of
    /// a cell that has fragments
    void drawBack(Canvas canvas, ref const CellInput cell, ref const DrawState state) {}

    /// The text of the part [from, to) of what the cell shows for the clipboard; `inFull`: the cell selected whole gives its full text, the head a
    /// group goes by too (`bodyStart` is where what it shows begins)
    wstring copyPart(wstring full, size_t bodyStart, size_t from, size_t to, bool inFull) const
    {
        const body = full[bodyStart .. $];
        return inFull && from == 0 && to == body.length ? full : body[from .. to];
    }

    /// The text of the whole cell: its full text with the head if `inFull`, else as it is shown
    wstring copyCell(wstring full, size_t bodyStart, bool inFull) const
    {
        return inFull ? full : full[bodyStart .. $];
    }

    /// The range a double (`Unit.word`) or a triple click (`Unit.cell`) at the place `at` selects, as two places in the cell; the whole cell by
    /// default
    size_t[2] expand(ref const CellInput cell, size_t at, Unit unit)
    {
        return [Position.begin, Position.end];
    }

    /// The least width of the column as a whole: its least width of the content (`ColumnDef.minWidth`) and the paddings its cells and its
    /// title have (the line between the columns is the table's, not the column's)
    double leastWidth() const
    {
        return def.minWidth;
    }

    /// The size of the title (nothing: no title to draw, the header is as the painter makes it)
    Measured measureHeader()
    {
        return Measured.init;
    }

    void drawHeader(Canvas canvas, Rect area, in HeaderState state) {}

    /// The size of the head of a group
    Measured measureGroup(in GroupInput group)
    {
        return Measured.init;
    }

    /// The head of a group on its plate `area` (the plate is the painter's)
    void drawGroup(Canvas canvas, in GroupInput group, Rect area) {}

    /// The size of a cell in `width` (it is asked for rows off the screen too: no drawing state is needed); the widths only if `widths`
    /// (the height of every row read is asked, the widths only of the rows the columns grow to). An empty cell (`cell.data` null) is the
    /// lowest the column has: a row is never lower than an empty one (`RowGeometry.floor`), whatever a filled cell measures
    Measured measure(ref const CellInput cell, double width, bool widths)
    {
        return Measured.init;
    }

    /// Whether the cells break into lines in the width of the column (its rows are laid out again when it changes; it does not grow to its
    /// texts)
    bool wraps() const
    {
        return false;
    }

    void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state) {}

    /// The place in the cell in `area` nearest to the point (`x`, `y`, in the table's coordinates): a caret in a text; `Position.begin` for a
    /// content with no places. `view` is the part of `area` seen (a content that keeps in view stands where it was drawn: `DrawState.clip`)
    size_t hitTest(ref const CellInput cell, Rect area, Rect view, double x, double y)
    {
        return Position.begin;
    }

    /// The rectangles the range [`from`, `to`) of the cell in `area` takes (one per line of text), in the table's coordinates; `view` as for
    /// `hitTest`
    void rects(ref const CellInput cell, Rect area, Rect view, size_t from, size_t to, scope void delegate(Rect) emit) {}

    /// The rows `first`..`last` (not including) of the model changed
    void rowsChanged(size_t first, size_t last) {}

    /// The column is now `width` wide
    void widthChanged(double width) {}

    /// The fonts or the scale changed, or the table reads its columns again: what the column measured of its fonts is to be measured again
    void lookChanged() {}
}

version (unittest)
{
    import ptable.ports : Color, FontId;

    // a canvas that keeps the colors of the rectangles filled
    private final class ColorCanvas : Canvas
    {
        Color[] colors;

        void fillRect(Rect area, Color color) { colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    // a column that is no text at all: a color of the row's number; a position in it is 0 or 1
    private final class Swatch : TableColumn
    {
        size_t measured, changedRows;

        this()
        {
            super(ColumnDef("swatch", "Swatch"));
        }

        override Measured measure(ref const CellInput cell, double width, bool widths)
        {
            ++measured;
            return Measured(10, 10, 16);
        }

        override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
        {
            canvas.fillRect(state.area, Color(cast(ubyte) cell.row, 0, 0));
        }

        override size_t hitTest(ref const CellInput cell, Rect area, Rect view, double x, double y)
        {
            return x < area.x + area.w / 2 ? 0 : 1;
        }

        override void rects(ref const CellInput cell, Rect area, Rect view, size_t from, size_t to, scope void delegate(Rect) emit)
        {
            const half = area.w / 2;
            if (from < 1)
                emit(Rect(area.x, area.y, half, area.h));
            if (to > 0)
                emit(Rect(area.x + half, area.y, half, area.h));
        }

        override void rowsChanged(size_t first, size_t last)
        {
            changedRows += last - first;
        }
    }
}

@("Position: ordered by the row, then the column, then the place in the cell; the ends of a cell are its limits")
unittest
{
    assert(Position(1, 0, 5) < Position(2, 0, 0));
    assert(Position(1, 0, 5) < Position(1, 1, 0));
    assert(Position(1, 1, 3) < Position(1, 1, 4));
    assert(Position(1, 1, 4) == Position(1, 1, 4));
    assert(Position(1, 1, Position.begin) <= Position(1, 1, 0) && Position(1, 1, 7) < Position(1, 1, Position.end));
    assert(Position(1, 0, Position.end) < Position(1, 1, Position.begin), "the end of a cell is before the next cell");
}

@("TableColumn: a column that is no text measures, draws, answers a hit and gives the rectangles of a range through the interface alone")
unittest
{
    TableColumn content = new Swatch;
    const cell = CellInput(3, 1, null);
    assert(content.measure(cell, 100, true) == Measured(10, 10, 16));
    auto canvas = new ColorCanvas;
    DrawState state;
    state.area = Rect(0, 0, 40, 16);
    content.draw(canvas, cell, state);
    assert(canvas.colors == [Color(3, 0, 0)]);
    assert(content.hitTest(cell, Rect(0, 0, 40, 16), Rect(0, 0, 40, 16), 30, 4) == 1);
    Rect[] seen;
    content.rects(cell, Rect(0, 0, 40, 16), Rect(0, 0, 40, 16), Position.begin, Position.end, (Rect r) { seen ~= r; });
    assert(seen == [Rect(0, 0, 20, 16), Rect(20, 0, 20, 16)]);
    content.rowsChanged(2, 5); // the empty default for a content that keeps nothing, and this one counts
    assert((cast(Swatch) content).changedRows == 3);
    content.widthChanged(10);
    content.lookChanged();
    assert(content.def.id == "swatch" && content.measureHeader() == Measured.init, "no title to draw by default");
    assert(content.expand(cell, 0, Unit.word) == [Position.begin, Position.end], "a double click takes the cell by default");
}

@("TableColumn: a column is all body unless it is given its parts")
unittest
{
    import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;

    auto plain = new Swatch;
    assert(plain.cellParts is trivialCellParts && !plain.cellParts.hasHead);
    const time = plain.withParts(new immutable HeadedCellPartsExtractor(&firstSpace));
    assert(time is plain && time.cellParts.hasHead && time.cellParts.head("2026/11/18 10:00"w) == "2026/11/18");
}
