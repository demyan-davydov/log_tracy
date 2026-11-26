//! The text a user has selected in a table, the press of the mouse that waits to become a click or a drag, and the text a copy
//! takes of it or of the rows picked. The rows picked are `RowPicker`'s (it owns this too). Pure.
//! See docs/stories/painted-table.md.
module ptable.tableselection;

version (unittest) import ptable.testing : tabbed;
import ptable.layout : Placements;
import ptable.pointer : PressTracker, Release, SelectionState;
import ptable.rowcopy : CopiedRows, RowCopier;
import ptable.rowranges : RowRange;
import ptable.selection : Position, Selection, TextRange, textRange;

final class TableSelection
{
    private SelectionState _text;
    private PressTracker _press;
    private RowCopier _copier;

    this(RowCopier copier)
    {
        _copier = copier;
    }

    // ---- the text ----

    bool hasText() const
    {
        return _text.has;
    }

    TextRange range() const
    {
        return textRange(_text.selection);
    }

    /// Sets the text selected (`has` false: none); true if it changed
    bool setText(bool has, Selection selection = Selection.init)
    {
        return _text.set(has, selection);
    }

    /// Lets go of the text selected; true if there was some
    bool clearText()
    {
        if (!_text.has)
            return false;
        _text.set(false);
        return true;
    }

    // ---- the press ----

    /// A press at (x, y) on the text position `at` (`hasPosition` false: on no text) in `column`
    void pressBegin(double x, double y, bool hasPosition, Position at, size_t column)
    {
        _press.begin(x, y, hasPosition, at, column);
    }

    bool pressed() const
    {
        return _press.pressed;
    }

    /// The mouse moved to (x, y): true once the press is a drag
    bool dragged(double x, double y)
    {
        return _press.dragged(x, y);
    }

    /// Where the press began, if it was on text
    bool pressHasPosition() const
    {
        return _press.hasPosition;
    }

    Position pressPosition() const
    {
        return _press.position;
    }

    /// The press is cancelled (the window lost the mouse or the focus): no click, no scroll
    void pressCancel()
    {
        _press.end();
    }

    /// The button went up
    Release pressEnd()
    {
        return _press.end();
    }

    // ---- the copy ----

    /// The text for the clipboard: the text selected, else the rows `rows` (sorted ranges of the items picked); the rows always
    /// if `rowsOnly`
    wstring copyText(const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull, const(RowRange)[] rows, bool rowsOnly = false)
    {
        CopiedRows copied;
        return copyText(wanted, p, wholeCellsInFull, rows, rowsOnly, copied);
    }

    /// The same, and how many rows it took of how many (`copied`; nothing for a text selected)
    wstring copyText(const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull, const(RowRange)[] rows, bool rowsOnly,
        out CopiedRows copied)
    {
        if (_text.has && !rowsOnly)
            return _copier.ofRange(textRange(_text.selection), wanted, p, wholeCellsInFull);
        return _copier.ofRows(rows, wanted, p, wholeCellsInFull, copied);
    }

    /// The full text of one cell (`RowCopier.cellText`)
    wstring cellText(size_t row, size_t column, const(bool)[] wanted)
    {
        return _copier.cellText(row, column, wanted);
    }
}

@("TableSelection: a new text reports a change once, clearText lets go of it")
unittest
{
    auto picked = new TableSelection(null);
    assert(!picked.hasText && !picked.clearText(), "nothing picked");
    const text = Selection(Position(1, 0, 0), Position(1, 0, 3));
    assert(picked.setText(true, text) && !picked.setText(true, text) && picked.hasText);
    assert(picked.range.start == Position(1, 0, 0));
    assert(picked.clearText() && !picked.hasText && !picked.clearText());
}

@("TableSelection: the rows given are what is copied when no text is selected")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;
    import ptable.columnset : ColumnSet;
    import ptable.model : NumbersModel;

    auto model = new NumbersModel(10);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    auto picked = new TableSelection(new RowCopier(model, columns, tabbed));
    assert(picked.copyText(null, p, true, null) == ""w, "no rows");
    assert(picked.copyText(null, p, true, [RowRange(2, 2), RowRange(4, 5)]) == "2\trow 2\n4\trow 4\n5\trow 5"w);
    picked.setText(true, Selection(Position(1, 0, 0), Position(1, 0, 1)));
    assert(picked.copyText(null, p, true, [RowRange(2, 2)]) != "2\trow 2"w, "the text selected goes first");
    assert(picked.copyText(null, p, true, [RowRange(2, 2)], true) == "2\trow 2"w, "rowsOnly: the rows, the text is ignored");
}

@("TableSelection: a press that is not dragged is a click at its place, a dragged one is not")
unittest
{
    auto picked = new TableSelection(null);
    assert(!picked.pressed);
    picked.pressBegin(10, 10, true, Position(3, 1, 4), 2);
    assert(picked.pressed && picked.pressHasPosition && picked.pressPosition.row == 3);
    assert(!picked.dragged(11, 10));
    const click = picked.pressEnd();
    assert(click.wasPressed && click.click && click.column == 2);
    picked.pressBegin(10, 10, true, Position(3, 1, 4), 2);
    assert(picked.dragged(80, 10));
    assert(!picked.pressEnd().click);
}
