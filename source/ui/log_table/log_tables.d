//! The log tables of the window (`LogTables`): what a table shows and what the script hears of its mouse, read off its element
//! (`tableAttributesOf`, `hearsOf`), the tables the script
//! talks to by their numbers, and what they share: the column host of a document, so the main table and the search table of a
//! document keep the same columns, widths, hidden columns and horizontal scroll, fit to the rows of both; the look and the single-line
//! setting of the application. What the script asks of the log tables (`logTableCall`, `logTableSetLook`, ...) is done here: the
//! window only converts the values of Sciter. Free of Sciter.
module ui.log_table.log_tables;

import ptable.columnhost : ColumnHost;
import ptable.table : OverKinds;
import ui.log_table.log_columns : anchorColumnId, indexColumnId;
import ui.log_table.log_look : defaultLogLook, LogLook;
import ui.table_script : TableControl, TableRegistry;

/// What an element with `behavior: log-table` shows, as the script wrote it on the element (resources/log-table-view.js): the attributes
/// `doc` (the id of the document), `search` ("1": its search view, "0": its main view) and `table` (the number the script talks to the
/// table by, more than 0)
struct TableAttributes
{
    int doc;
    bool search;
    size_t id;
}

/// Reads the attributes of a log table's element (null or "": not there); false when one is missing or is not what it must be
bool tableAttributesOf(const(char)[] doc, const(char)[] search, const(char)[] table, out TableAttributes into)
{
    import std.conv : ConvException, to;

    if (search != "0" && search != "1")
        return false;
    try
    {
        const docId = doc.to!int;
        const id = table.to!size_t;
        if (docId < 0 || id == 0)
            return false;
        into = TableAttributes(docId, search == "1", id);
        return true;
    }
    catch (ConvException)
        return false;
}

/// Whether the attribute `detached` of a log table's element (null: not there) says the table starts out of its column host: the
/// script writes "1" while the table is not seen (a bottom panel collapsed), so a table attached after the script's `detach` call
/// (which then reached no table) is out of its host all the same
bool detachedOf(const(char)[] attribute)
{
    return attribute == "1";
}

@("detachedOf: \"1\" is detached, anything else or none is not")
unittest
{
    assert(detachedOf("1"));
    assert(!detachedOf(null));
    assert(!detachedOf("0"));
    assert(!detachedOf(""));
}

/// Reads the attribute `hears` of a log table's element: the kinds of things the script hears the mouse enter and leave (a handler of
/// the view asked: resources/log-table-view.js, `onPointer`), by space ("header cell"); none when it is not there. The element keeps
/// them so a table attached later (or again) hears what the script asked before
OverKinds hearsOf(const(char)[] hears)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;

    return OverKinds(hears.splitter(' ').canFind("header"), hears.splitter(' ').canFind("cell"));
}

@("tableAttributesOf: the document, the view and the number of a table as the script wrote them; one missing or wrong is no table")
unittest
{
    TableAttributes read;
    assert(tableAttributesOf("3", "1", "12", read) && read == TableAttributes(3, true, 12));
    assert(tableAttributesOf("0", "0", "1", read) && read == TableAttributes(0, false, 1));
    assert(!tableAttributesOf(null, "0", "1", read), "no document");
    assert(!tableAttributesOf("3", "", "1", read), "no view");
    assert(!tableAttributesOf("3", "yes", "1", read), "a view is 0 or 1");
    assert(!tableAttributesOf("3", "0", "x", read), "a number is a number");
    assert(!tableAttributesOf("3", "0", "0", read), "the numbers start at 1");
    assert(!tableAttributesOf("-1", "0", "2", read), "no document has a negative id");
}

@("hearsOf: the kinds of things whose enters and leaves the script hears, as it wrote them on the table's element; none if none")
unittest
{
    assert(hearsOf(null) == OverKinds(false, false));
    assert(hearsOf("header") == OverKinds(true, false));
    assert(hearsOf("header cell") == OverKinds.all);
    assert(hearsOf("cell") == OverKinds(false, true));
}

/// The log tables of the window: those the script talks to, by their numbers, and what they share
final class LogTables
{
    private bool _singleLine;
    private ColumnHost[int] _hosts;
    private LogLook _look;
    private TableRegistry _tables; // the tables attached, by their numbers

    /// Whether the rows of the log tables are one line high (the setting of the application): a table starts so
    bool singleLine() const { return _singleLine; }

    /// The setting of the single line changed: every table now, the next ones from the start
    void singleLine(bool on)
    {
        _singleLine = on;
        _tables.each((TableControl table) { table.singleLine(on); });
    }

    /// The table `control` attached as `id`: the script talks to it from now on; it hears the enters and leaves of `hears`, what the
    /// script asked on its element before (`hearsOf`)
    void attached(size_t id, TableControl control, OverKinds hears = OverKinds.init)
    {
        _tables.attach(id, control);
        control.hearOver(hears);
    }

    /// The table `control` is gone (whatever its number)
    void detached(TableControl control)
    {
        _tables.detach(control);
    }

    /// The table of the number `id`, null if there is none (not attached yet, or no more)
    TableControl table(size_t id)
    {
        return _tables.get(id);
    }

    /// The look of the application from the script (JSON of resources/log-table-look.js): every table has it, one not attached yet too
    void setLook(string json)
    {
        import ui.log_table.look_json : applyLookJson;

        applyLookJson(look, json);
    }

    /// The names of the CSS variables of the least widths of the columns the script reads into the look, as a JSON array
    string minWidthNames() const
    {
        import std.json : JSONValue;
        import ui.log_table.column_widths : minWidthVariables;

        return JSONValue(minWidthVariables()).toString;
    }

    /// The look every log table has: one for the application, its change reaches all the tables
    LogLook look()
    {
        if (_look is null)
            _look = defaultLogLook();
        return _look;
    }

    /// The column host of `doc`: one for both its tables
    ColumnHost hostOf(int doc)
    {
        import ptable.layout : Pin;

        if (auto have = doc in _hosts)
            return *have;
        auto host = new ColumnHost;
        foreach (id; [anchorColumnId, indexColumnId]) // the first two columns of every log table stay when the columns scroll
            host.layout.setPin(id, Pin.left);
        return _hosts[doc] = host;
    }

    /// The document is closed: its host goes
    void documentClosed(int doc)
    {
        _hosts.remove(doc);
    }
}

@("LogTables: the tables of a document share one column host, those of another document do not")
unittest
{
    auto target = new LogTables;
    assert(!target.singleLine);
    target.singleLine = true;
    assert(target.singleLine, "the next table starts so");
    assert(target.hostOf(3) is target.hostOf(3), "both tables of a document settle their widths in one host");
    assert(target.hostOf(3) !is target.hostOf(4));
    auto old = target.hostOf(3);
    target.documentClosed(3);
    assert(target.hostOf(3) !is old, "a closed document's host is not kept");
}

@("LogTables: the host of a document pins the anchor and the Index columns at the left")
unittest
{
    import ptable.layout : Pin;

    auto target = new LogTables;
    auto host = target.hostOf(1);
    assert(host.layout.pin("anchor") == Pin.left && host.layout.pin("index") == Pin.left, "they stay when the columns scroll");
    assert(host.layout.pin("time") == Pin.none, "the columns of the format scroll");
}

@("LogTables: the setting of the single line reaches every table attached, and a table attached later starts so")
unittest
{
    import std.typecons : BlackHole;

    static class Told : BlackHole!TableControl
    {
        bool[] lines;
        override void singleLine(bool on) { lines ~= on; }
    }

    auto tables = new LogTables;
    auto a = new Told, b = new Told, gone = new Told;
    tables.attached(1, a);
    tables.attached(2, b);
    tables.attached(3, gone);
    tables.detached(gone);
    tables.singleLine(true);
    assert(a.lines == [true] && b.lines == [true] && gone.lines.length == 0, "the tables there are, not one gone");
    assert(tables.singleLine, "the next table starts so");
    assert(tables.table(1) is a && tables.table(3) is null && tables.table(9) is null);
}

@("LogTables: a table attached hears the enters and leaves the script asked for on its element before it attached")
unittest
{
    import std.typecons : BlackHole;

    static class Told : BlackHole!TableControl
    {
        OverKinds[] heard;
        override void hearOver(OverKinds kinds) { heard ~= kinds; }
    }

    auto tables = new LogTables;
    auto a = new Told;
    tables.attached(1, a, OverKinds(true, false));
    assert(a.heard == [OverKinds(true, false)]);
}

@("LogTables: the look the script sends is the look every table has; the names of the least widths are a JSON array")
unittest
{
    import std.json : parseJSON;

    auto tables = new LogTables;
    auto look = tables.look;
    import ptable.ports : Color;

    tables.setLook(`{"row": "#010203"}`);
    assert(tables.look is look, "one look for the application, changed in place");
    assert(look.palette.row == Color(1, 2, 3));
    const names = parseJSON(tables.minWidthNames());
    assert(names.array.length > 4 && names[0].str.length > 0);
}

