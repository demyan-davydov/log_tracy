//! The painter of a table: how its parts look (the rows, the borders of the cells, the plates of the groups, the empty room);
//! what is in a cell is its column's (`TableColumn`). The table decides what is where (rows, cells, the
//! header, the footer, the empty room), the painter draws each part and may change only some of them:
//! every method does something plain by default. A painter that reads simple rules (paddings,
//! alignment, colors) is a second layer on top of this one. See docs/stories/painted-table.md.
module ptable.painter;

import ptable.layout : ColumnDef;
import ptable.column : TableColumn;
import ptable.model : CellData, Fragment, RowData;
import ptable.ports;

/// The state of a row the table knows by itself
struct RowState
{
    bool selected, odd, hover, focused;
}

/// A row to draw (the header: `data` null): `area` is where, in the body of the table
struct RowContext
{
    size_t index;
    const(RowData)* data;
    Rect area;
    RowState state;
}

/// A cell to draw: its `area` is in the table's coordinates, `clip` the part of it that is not hidden by a
/// pinned area or the edges
struct CellContext
{
    const(RowContext)* row;
    TableColumn column;
    size_t columnIndex;
    const(CellData)* data;
    Rect area, clip;
    bool isHeader; /// a cell of the header: `data` is the title, `row.data` is null
    bool pressed; /// the button is down on this cell (a press on a cell of a clickable column that is on)
    bool hover; /// the mouse is over this cell (`row.state.hover`: over the row it is in)
}

/// A head of a group of rows (a date over the rows of its day, a shift) to draw in `cell`, the part of its column: in
/// the margin above the group's first row (`Painter.paintGroupBand` paints the margin first), or, for the rows on top,
/// over the column's title (`sticky`). Heads are painted after the header: over it only in the cell of their column, so
/// a margin going up covers the titles of the columns that changed in it and the heads there, not the others
struct GroupContext
{
    const(wchar)[] head;
    Rect cell;
    bool sticky;
    TableColumn column; /// the column the head is of: it draws the head on the plate
}

/// What the table needs to know of the look to lay itself out
struct TableGeometry
{
    double headerHeight = 21; /// 0 or less: as high as the tallest title of the columns (`TableColumn.measureHeader`), so a font change moves it
    double footerHeight = 0; /// 0: no footer
    /// Room above the first row and under the last one, scrolled with the rows (the window on them keeps the height of the body), painted by
    /// `paintEmpty` where it is in view; the margins left and right are the column host's (`ColumnHost.setMargins`), the same for its tables
    double marginTop = 0, marginBottom = 0;
    /// The plate of the heads above the first row of a group (rows grouped by the heads of a column, `CellPartsExtractor`),
    /// stuck over the titles for the rows on top; 0: none, the rows are not grouped; less than 0: as high as the header
    double groupHeight = 0;
    /// Empty room above and under the plate of a group's heads: a margin is the room above, the plate (`groupHeight`
    /// high) and the room under it
    double groupPadTop = 0, groupPadBottom = 0;
    /// The line between two columns on the screen (none left of the first, none right of the last): not a part of a column,
    /// `placeColumns` puts it between them; 0: none
    double columnBorder = 0;
    /// The line under each row: a part of the height of its row, under its cells; 0: none
    double rowBorder = 0;
    /// The lines at the top and at the bottom of the margin of a group (`paintGroupOutline`), across the rows: they take no room of their own,
    /// they are drawn in the margin over its band and under the plates of the heads, so a plate covers the bottom one in its column; 0: none
    double groupOutline = 0;
}

/// A part of the table with no rows in it
enum EmptyZone : ubyte
{
    marginTop, /// the table's margin above the first row (`TableGeometry.marginTop`), all of the width, the part of it in view
    marginBottom, /// the margin under the last row
    beside, /// right of the last column when they do not fill the width
    marginLeft, /// the margin left of the rows (`ColumnHost.margins`), as high as the body
    marginRight, /// the margin right of the rows
}

/// How a table looks. Every method may be overridden; the default of each draws nothing but a plain
/// background, so a painter starts with what it cares about.
class Painter
{
    /// A frame begins: `slots` are the rows on the screen, in the order they come. The rows are given to the painter from
    /// the top down (`paintRow`, then the cells), so a painter may keep what it learns of them (the date of the first row, where
    /// the next date begins) and use it in `endFrame` and in the header, which is painted after them.
    void beginFrame(Canvas canvas, size_t firstRow, size_t rowCount)
    {
    }

    /// The rows of the frame are all painted (with their pinned parts, which are drawn row by row): the header and the
    /// footer follow
    void endFrame(Canvas canvas)
    {
    }

    /// The whole body first
    void paintBackground(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, Color(255, 255, 255));
    }

    /// Every hook that may draw by whether the table has the focus (`Table.tableHasFocus`, as the host said) is told it as `tableHasFocus`: a
    /// painter that draws the same with or without it ignores it. It is not part of the state of a row: it is the table's.

    /// A row's background; its cells follow through `paintCell`
    void paintRow(Canvas canvas, ref const RowContext row, bool tableHasFocus)
    {
    }

    /// What goes over a row once its cells (and the pinned strips) are drawn: a frame the lines of the columns must not cross
    void paintRowOver(Canvas canvas, ref const RowContext row, bool tableHasFocus)
    {
    }

    /// What the painter adds to a cell after its column drew it (`TableColumn.draw`, `drawHeader`), in the area of the cell: the lines
    /// between the columns and the rows are not a part of it (`paintColumnLine`, `paintRowLine`)
    void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus)
    {
    }

    /// The line between two columns, right of a cell of `column` (`TableGeometry.columnBorder` wide, as high as the cell), in a row or
    /// (`header`) in the header: the table leaves its room out of the cell
    void paintColumnLine(Canvas canvas, Rect area, TableColumn column, bool header)
    {
    }

    /// The line under a row (`TableGeometry.rowBorder` high, across the block of the columns): the table leaves its room out of the cells
    void paintRowLine(Canvas canvas, Rect area, ref const RowContext row)
    {
    }

    /// The header and the footer: one call for the area, the table asks `paintCell` for the cells with `row.data` null
    void paintHeader(Canvas canvas, Rect area)
    {
    }

    void paintFooter(Canvas canvas, Rect area)
    {
    }

    /// The margin above the first row of a group, across the rows, before its heads: once a margin
    void paintGroupBand(Canvas canvas, Rect area)
    {
    }

    /// A line of the margin of a group (`TableGeometry.groupOutline` high, across the rows): at its top (`top`), under the row above, or at
    /// its bottom, over the rows of the group; after the band, before the heads
    void paintGroupOutline(Canvas canvas, Rect area, bool top)
    {
    }

    /// A head of a group, in the cell of its column: in its margin, or over the title (`TableGeometry.groupHeight` high);
    /// once for each column whose head changed
    void paintGroup(Canvas canvas, ref GroupContext group, bool tableHasFocus)
    {
    }

    /// The margins around the rows: the painter fills them as it wants (the background is under them)
    void paintEmpty(Canvas canvas, Rect area, EmptyZone zone)
    {
    }

    /// The sizes and fonts the layout needs
    TableGeometry geometry()
    {
        return TableGeometry.init;
    }

    /// A rectangle of the text selected, under the texts
    void paintTextSelection(Canvas canvas, Rect area, bool tableHasFocus)
    {
        canvas.fillRect(area, Color(0x7f, 0xdc, 0x94));
    }
}

version (unittest)
{
    /// A canvas that keeps what was drawn, as text
    final class RecordingCanvas : Canvas
    {
        string[] calls;

        void fillRect(Rect area, Color color) { calls ~= "fill"; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
        {
            import std.conv : to;

            calls ~= "text:" ~ text.to!string;
        }

        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color)
        {
            import std.conv : to;

            calls ~= "paragraph:" ~ text.to!string;
        }

        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) { calls ~= "circle"; }
        void pushClip(Rect area) { calls ~= "clip"; }
        void popClip() { calls ~= "unclip"; }
    }
}

@("Painter: a painter changes only the parts it cares about, the rest is the plain default")
unittest
{
    class Mine : Painter
    {
        override void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus)
        {
            canvas.drawText(0, cell.data.text, cell.area.x, cell.area.y, Color(0, 0, 0));
        }
    }

    auto canvas = new RecordingCanvas;
    Painter painter = new Mine;
    painter.paintBackground(canvas, Rect(0, 0, 100, 100));
    painter.paintEmpty(canvas, Rect(0, 90, 100, 10), EmptyZone.marginBottom);
    const data = CellData("hi"w);
    CellContext cell;
    cell.data = &data;
    cell.area = Rect(1, 2, 3, 4);
    painter.paintCell(canvas, cell, true);
    assert(canvas.calls == ["fill", "text:hi"], "the background is the default, the empty room is left alone");
}

@("Rect: the right and bottom edges, a point is inside by its left top edge")
unittest
{
    const r = Rect(10, 20, 5, 6);
    assert(r.right == 15 && r.bottom == 26);
    assert(r.contains(10, 20) && !r.contains(15, 20) && !r.contains(10, 26));
}

