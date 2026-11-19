//! The calls the script makes to the painted table (`paintCall("jump", ...)`) as a list of commands over a
//! `TableControl`: which method does what with which arguments and defaults, and what it answers. Free of Sciter: the
//! behavior converts the values of Sciter into `ScriptArgs` and the answer into a value of Sciter, and implements
//! `TableControl` with the table it has. The checks of the experiments (docs/experiments/2026-11-19-painted-rows-d.md)
//! and the debug channel use them.
module ui.table_script;

import ptable.tablehit : CopyTarget;
import std.math : isNaN;

/// The numbers of a call's arguments after its method; a value that is not a number is NaN
struct ScriptArgs
{
    const(double)[] numbers;

    size_t count() const
    {
        return numbers.length;
    }

    /// The argument `index` as a number, `fallback` if there is none or it is not a number
    double number(size_t index, double fallback = 0) const
    {
        return index < numbers.length && !numbers[index].isNaN ? numbers[index] : fallback;
    }
}

/// What a call answers
struct ScriptResult
{
    enum Kind : ubyte
    {
        nothing,
        number,
        text,
    }

    Kind kind;
    long value; /// of a number: the microseconds a call took, for the checks
    wstring text;

    static ScriptResult ofNumber(long value)
    {
        return ScriptResult(Kind.number, value);
    }

    static ScriptResult ofText(wstring text)
    {
        return ScriptResult(Kind.text, 0, text);
    }
}

/// What the script can ask of the table drawn by D
interface TableControl
{
    /// The row `row` is the first on the screen; `now`: drawn at once. Answers the microseconds it took.
    long jump(size_t row, bool now);

    /// Where the table stands as JSON (`Viewport.toJson`): the first row and its offset, the rows and the columns, the room, what is on the screen
    wstring viewport();

    /// The rows stand at `row` with `offset` pixels of it scrolled away and the columns `x` pixels sideways; a NaN leaves its axis where it is
    void scrollTo(double row, double offset, double x);

    /// As a wheel step of `pixels`, at once; `now`: drawn at once. Answers the microseconds it took.
    long scrollBy(double pixels, bool now);

    /// The fingers moved the rows by `pixels` on the trackpad (down is positive) and the columns by `across` (right is positive),
    /// now: the time is the table's clock. A move is along one axis: the one it goes farther on.
    void pan(double pixels, double across);

    /// The fingers left the trackpad, now: the rows coast if they went fast
    void panEnd();

    /// Draws at once without changing anything; answers the microseconds (the cost of a window's frame)
    long render();

    /// Wrap the Payload by the text engine of Sciter (1) or by the glyphs (0)
    void setWrap(bool bySciter);

    /// How many text layouts the host keeps
    void setLimits(size_t texts);

    /// A wheel step in pixels is this many times the delta of the wheel
    void setWheelScale(double scale);

    /// Every row one line (the Payload cut at its cell) or the Payload wrapped (the setting of the log tables)
    void singleLine(bool on);

    void resetStats();

    /// The text from the point to the point, as a drag does (for checks)
    void select(double x1, double y1, double x2, double y2);

    /// The word (or the cell) under the point
    void selectWord(double x, double y, bool word);

    /// The text a copy takes: whole cells with their heads (the date with the time), as Cmd+C, unless `wholeCellsInFull` is false
    wstring copyText(bool wholeCellsInFull);
    void copy(CopyTarget target, size_t row, size_t column); /// the text, the rows or the cell of the address go to the clipboard
    wstring hitTest(double x, double y); /// what is at the point, JSON (`TableHit.toJson`)
    void anchorApplied(size_t message, bool moved); /// an anchor was set or cleared on the message `message`; `moved`: its row came into the view or left it
    void updateRow(size_t item); /// only the place of the row `item` is painted again (for the checks; what an animation does)
    void updateCell(size_t item, size_t column); /// the same for a cell: the column of the model
    void contextPick(size_t row); /// the click for the menu was on this row: it keeps the rows picked, or is picked alone

    /// Shows the demo of the groups of rows in place of the log (`on`), or the log again
    void showDemo(bool on);

    /// The measurements as JSON
    wstring stats();
}

/// Does the call `method` with `args` on `control`; false for a method it does not know
bool dispatch(TableControl control, const(char)[] method, ScriptArgs args, out ScriptResult result)
{
    switch (method)
    {
    case "jump":
        result = ScriptResult.ofNumber(control.jump(cast(size_t) args.number(0), args.number(1) != 0));
        return true;
    case "viewport":
        result = ScriptResult.ofText(control.viewport());
        return true;
    case "scrollTo":
        control.scrollTo(args.number(0, double.nan), args.number(1, 0), args.number(2, double.nan));
        return true;
    case "scrollBy":
        result = ScriptResult.ofNumber(control.scrollBy(args.number(0), args.number(1) != 0));
        return true;
    case "pan":
        control.pan(args.number(0), args.number(1, 0));
        return true;
    case "panEnd":
        control.panEnd();
        return true;
    case "render":
        result = ScriptResult.ofNumber(control.render());
        return true;
    case "setWrap":
        control.setWrap(args.number(0) != 0);
        return true;
    case "setLimits":
        control.setLimits(cast(size_t) args.number(0, 3000));
        return true;
    case "setWheelScale":
        control.setWheelScale(args.number(0, 1));
        return true;
    case "singleLine":
        control.singleLine(args.number(0) != 0);
        return true;
    case "resetStats":
        control.resetStats();
        return true;
    case "select":
        control.select(args.number(0), args.number(1), args.number(2), args.number(3));
        return true;
    case "selectWord":
        control.selectWord(args.number(0), args.number(1), args.number(2) == 0); // 0 the word, 1 the cell
        return true;
    case "copyText":
        result = ScriptResult.ofText(control.copyText(args.number(0, 1) != 0)); // as Cmd+C unless 0
        return true;
    case "copy":
        // paintD("copy", 0): the text or the rows as Cmd+C; 1: the rows; 2, row, column: the cell of the address
        const kind = args.number(0, 0), row = args.number(1, 0), column = args.number(2, 0);
        if (kind >= 0 && kind <= CopyTarget.max && row >= 0 && column >= 0) // an address that is none copies nothing
            control.copy(cast(CopyTarget) kind, cast(size_t) row, cast(size_t) column);
        return true;
    case "hitTest":
        result = ScriptResult.ofText(control.hitTest(args.number(0), args.number(1)));
        return true;
    case "updateRow":
        control.updateRow(cast(size_t) args.number(0));
        return true;
    case "updateCell":
        control.updateCell(cast(size_t) args.number(0), cast(size_t) args.number(1));
        return true;
    case "anchorApplied":
        control.anchorApplied(cast(size_t) args.number(0), args.number(1) != 0);
        return true;
    case "contextPick":
        control.contextPick(cast(size_t) args.number(0));
        return true;
    case "demo":
        control.showDemo(args.number(0, 1) != 0); // paintD("demo"), paintD("demo", 0) for the log again
        return true;
    case "stats":
        result = ScriptResult.ofText(control.stats());
        return true;
    default:
        return false;
    }
}

/// The table the script talks to: the one attached last that is still attached. A table that is detached leaves only
/// if it is the one registered (another one attached since stays).
struct CurrentControl
{
    private TableControl _control;

    /// A table was attached
    void attach(TableControl control)
    {
        _control = control;
    }

    /// A table was detached
    void detach(TableControl control)
    {
        if (_control is control)
            _control = null;
    }

    /// The table the script talks to, null if none
    TableControl get()
    {
        return _control;
    }
}

version (unittest)
{
    import std.conv : to;

    // writes down what it is asked
    private final class Noting : TableControl
    {
        string[] calls;

        long jump(size_t row, bool now) { calls ~= "jump " ~ row.to!string ~ " " ~ now.to!string; return 11; }
        wstring viewport() { calls ~= "viewport"; return `{"first":{}}`w; }
        void scrollTo(double row, double offset, double x) { calls ~= "scrollTo " ~ row.to!string ~ " " ~ offset.to!string ~ " " ~ x.to!string; }
        long scrollBy(double pixels, bool now) { calls ~= "scrollBy " ~ pixels.to!string ~ " " ~ now.to!string; return 12; }
        long render() { calls ~= "render"; return 13; }
        void pan(double pixels, double across) { calls ~= "pan " ~ pixels.to!string ~ " " ~ across.to!string; }
        void panEnd() { calls ~= "panEnd"; }
        void setWrap(bool bySciter) { calls ~= "setWrap " ~ bySciter.to!string; }
        void setLimits(size_t texts) { calls ~= "setLimits " ~ texts.to!string; }
        void setWheelScale(double scale) { calls ~= "setWheelScale " ~ scale.to!string; }
        void singleLine(bool on) { calls ~= "singleLine " ~ on.to!string; }
        void resetStats() { calls ~= "resetStats"; }
        void select(double x1, double y1, double x2, double y2) { calls ~= "select " ~ [x1, y1, x2, y2].to!string; }
        void selectWord(double x, double y, bool word) { calls ~= "selectWord " ~ x.to!string ~ " " ~ y.to!string ~ " " ~ word.to!string; }
        wstring copyText(bool wholeCellsInFull) { calls ~= "copyText " ~ wholeCellsInFull.to!string; return "text"w; }
        void copy(CopyTarget target, size_t row, size_t column) { calls ~= "copy " ~ target.to!string ~ " " ~ row.to!string ~ " " ~ column.to!string; }
        wstring hitTest(double x, double y) { calls ~= "hitTest " ~ x.to!string ~ " " ~ y.to!string; return `{"row":1}`w; }
        void contextPick(size_t row) { calls ~= "contextPick " ~ row.to!string; }
        void updateRow(size_t item) { calls ~= "updateRow " ~ item.to!string; }
        void updateCell(size_t item, size_t column) { calls ~= "updateCell " ~ item.to!string ~ " " ~ column.to!string; }
        void anchorApplied(size_t message, bool moved) { calls ~= "anchorApplied " ~ message.to!string ~ " " ~ moved.to!string; }
        wstring stats() { calls ~= "stats"; return "{}"w; }
        void showDemo(bool on) { calls ~= "showDemo " ~ on.to!string; }
    }
}

@("dispatch: each call reaches its method with its arguments, and answers what the method did")
unittest
{
    auto control = new Noting;
    ScriptResult result;
    assert(dispatch(control, "jump", ScriptArgs([500, 1]), result) && result == ScriptResult.ofNumber(11));
    assert(dispatch(control, "scrollBy", ScriptArgs([-80]), result) && result == ScriptResult.ofNumber(12));
    assert(dispatch(control, "render", ScriptArgs(), result) && result == ScriptResult.ofNumber(13));
    assert(dispatch(control, "copyText", ScriptArgs(), result) && result == ScriptResult.ofText("text"));
    assert(dispatch(control, "stats", ScriptArgs(), result) && result.kind == ScriptResult.Kind.text);
    dispatch(control, "select", ScriptArgs([1, 2, 3, 4]), result);
    assert(dispatch(control, "pan", ScriptArgs([-7.5]), result) && result.kind == ScriptResult.Kind.nothing);
    assert(dispatch(control, "pan", ScriptArgs([1, 4]), result));
    assert(dispatch(control, "panEnd", ScriptArgs(), result));
    assert(dispatch(control, "copyText", ScriptArgs([0]), result));
    assert(dispatch(control, "demo", ScriptArgs(), result) && dispatch(control, "demo", ScriptArgs([0]), result));
    assert(dispatch(control, "copy", ScriptArgs(), result) && dispatch(control, "copy", ScriptArgs([2, 7, 3]), result));
    assert(dispatch(control, "hitTest", ScriptArgs([5, 6]), result) && result == ScriptResult.ofText(`{"row":1}`w));
    assert(dispatch(control, "contextPick", ScriptArgs([4]), result));
    assert(dispatch(control, "updateRow", ScriptArgs([4]), result) && dispatch(control, "updateCell", ScriptArgs([4, 2]), result));
    assert(dispatch(control, "anchorApplied", ScriptArgs([9, 1]), result) && dispatch(control, "anchorApplied", ScriptArgs([8]), result));
    assert(dispatch(control, "copy", ScriptArgs([7, 1, 1]), result) && dispatch(control, "copy", ScriptArgs([2, -1, 1]), result), "no kind or row like that: known call, nothing copied");
    assert(control.calls == ["jump 500 true", "scrollBy -80 false", "render", "copyText true", "stats", "select [1, 2, 3, 4]",
        "pan -7.5 0", "pan 1 4", "panEnd", "copyText false", "showDemo true", "showDemo false",
        "copy text 0 0", "copy cell 7 3", "hitTest 5 6", "contextPick 4", "updateRow 4", "updateCell 4 2", "anchorApplied 9 true", "anchorApplied 8 false"]);
}

@("dispatch: viewport answers JSON, scrollTo leaves out the axis it is not given (NaN)")
unittest
{
    auto control = new Noting;
    ScriptResult result;
    assert(dispatch(control, "viewport", ScriptArgs(), result) && result == ScriptResult.ofText(`{"first":{}}`w));
    assert(dispatch(control, "scrollTo", ScriptArgs([12, 5, 40]), result) && result.kind == ScriptResult.Kind.nothing);
    assert(dispatch(control, "scrollTo", ScriptArgs([double.nan, 0, 7]), result));
    assert(dispatch(control, "scrollTo", ScriptArgs([3]), result));
    assert(control.calls == ["viewport", "scrollTo 12 5 40", "scrollTo nan 0 7", "scrollTo 3 0 nan"]);
}

@("dispatch: what a call leaves out is the default, a word is 0 and a cell 1, a value that is no number is the default")
unittest
{
    auto control = new Noting;
    ScriptResult result;
    dispatch(control, "setLimits", ScriptArgs(), result);
    dispatch(control, "setLimits", ScriptArgs([100]), result);
    dispatch(control, "setWheelScale", ScriptArgs(), result);
    dispatch(control, "selectWord", ScriptArgs([5, 6, 0]), result);
    dispatch(control, "selectWord", ScriptArgs([5, 6, 1]), result);
    dispatch(control, "setWrap", ScriptArgs([double.nan]), result);
    dispatch(control, "singleLine", ScriptArgs([1]), result);
    dispatch(control, "singleLine", ScriptArgs([0]), result);
    dispatch(control, "resetStats", ScriptArgs(), result);
    assert(control.calls == ["setLimits 3000", "setLimits 100", "setWheelScale 1", "selectWord 5 6 true",
        "selectWord 5 6 false", "setWrap false", "singleLine true", "singleLine false", "resetStats"]);
}

@("dispatch: a method it does not know is false and answers nothing")
unittest
{
    auto control = new Noting;
    ScriptResult result;
    assert(!dispatch(control, "teleport", ScriptArgs([1]), result));
    assert(result.kind == ScriptResult.Kind.nothing && control.calls.length == 0);
}

@("CurrentControl: a table that is detached leaves only if it is the one registered")
unittest
{
    CurrentControl current;
    auto a = new Noting, b = new Noting;
    assert(current.get is null);
    current.attach(a);
    current.attach(b);
    assert(current.get is b, "the one attached last");
    current.detach(a);
    assert(current.get is b, "another table's detach does not take the current one away");
    current.detach(b);
    assert(current.get is null);
    current.detach(b); // twice, or with nothing attached
    assert(current.get is null);
}
