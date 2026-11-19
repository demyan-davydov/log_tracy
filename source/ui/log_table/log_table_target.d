//! What the next log table (behavior `log-table`) is to show: a document and one of its views, and the
//! column host the tables of a document share, so the main table and the search table of a document keep
//! the same columns, widths, hidden columns and horizontal scroll, fit to the rows of both. Free of Sciter.
module ui.log_table.log_table_target;

import ptable.columnhost : ColumnHost;
import ui.log_table.log_look : defaultLogLook, LogLook;

/// The view the next log table shows, and the column hosts of the documents
final class LogTableTarget
{
    private int _doc = -1;
    private bool _search;
    private size_t _id;
    private bool _singleLine;
    private ColumnHost[int] _hosts;
    private LogLook _look;

    /// The next log table shows the view of the document `doc`; answers the number it gets (the script talks to a table by it): a new one each time
    size_t set(int doc, bool search)
    {
        _doc = doc;
        _search = search;
        return ++_id;
    }

    int doc() const { return _doc; }
    bool search() const { return _search; }

    /// The number of the table the target was last set for
    size_t id() const { return _id; }

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
        if (auto have = doc in _hosts)
            return *have;
        return _hosts[doc] = new ColumnHost;
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
    const first = target.set(3, true);
    assert(target.doc == 3 && target.search && target.id == first);
    assert(target.set(3, false) != first && target.id != first, "every table has a number of its own");
    assert(!target.singleLine);
    target.singleLine = true;
    assert(target.singleLine, "the next table starts so");
    assert(target.hostOf(3) is target.hostOf(3), "both tables of a document settle their widths in one host");
    assert(target.hostOf(3) !is target.hostOf(4));
    auto old = target.hostOf(3);
    target.forget(3);
    assert(target.hostOf(3) !is old, "a closed document's host is not kept");
}
