//! What a log table (behavior `log-table`) shows, read off its element (`tableAttributesOf`), and what the log tables share: the
//! column host of a document, so the main table and the search table of a document keep the same columns, widths, hidden columns
//! and horizontal scroll, fit to the rows of both; the look and the single-line setting of the application. Free of Sciter.
module ui.log_table.log_table_target;

import ptable.columnhost : ColumnHost;
import ui.log_table.log_columns : anchorColumnId, indexColumnId;
import ui.log_table.log_look : defaultLogLook, LogLook;

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

/// What the log tables share: the column host of each document, the look and the single-line setting of the application
final class LogTableTarget
{
    private bool _singleLine;
    private ColumnHost[int] _hosts;
    private LogLook _look;

    /// Whether the rows of the log tables are one line high (the setting of the application): the next log table starts so
    bool singleLine() const { return _singleLine; }

    /// ditto
    void singleLine(bool on) { _singleLine = on; }

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
    void forget(int doc)
    {
        _hosts.remove(doc);
    }
}

@("LogTableTarget: the tables of a document share one column host, those of another document do not")
unittest
{
    auto target = new LogTableTarget;
    assert(!target.singleLine);
    target.singleLine = true;
    assert(target.singleLine, "the next table starts so");
    assert(target.hostOf(3) is target.hostOf(3), "both tables of a document settle their widths in one host");
    assert(target.hostOf(3) !is target.hostOf(4));
    auto old = target.hostOf(3);
    target.forget(3);
    assert(target.hostOf(3) !is old, "a closed document's host is not kept");
}

@("LogTableTarget: the host of a document pins the anchor and the Index columns at the left")
unittest
{
    import ptable.layout : Pin;

    auto target = new LogTableTarget;
    auto host = target.hostOf(1);
    assert(host.layout.pin("anchor") == Pin.left && host.layout.pin("index") == Pin.left, "they stay when the columns scroll");
    assert(host.layout.pin("time") == Pin.none, "the columns of the format scroll");
}
