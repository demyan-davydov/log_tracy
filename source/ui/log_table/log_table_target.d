//! What the next log table (behavior `log-table`) is to show: a document and one of its views, and the
//! column layout the tables of a document share, so the main table and the search table of a document keep
//! the same widths, hidden columns and horizontal scroll. Free of Sciter.
module ui.log_table.log_table_target;

import ptable.layout : ColumnLayout;
import ui.log_table.log_look : defaultLogLook, LogLook;

/// The view the next log table shows, and the layouts of the documents
final class LogTableTarget
{
    private int _doc = -1;
    private bool _search;
    private size_t _id;
    private bool _singleLine;
    private ColumnLayout[int] _layouts;
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

    /// The layout of the columns of `doc`: one for both its tables
    ColumnLayout layoutOf(int doc)
    {
        if (auto have = doc in _layouts)
            return *have;
        return _layouts[doc] = new ColumnLayout;
    }

    /// The document is closed: its layout goes
    void forget(int doc)
    {
        _layouts.remove(doc);
    }
}

@("LogTableTarget: the tables of a document share one layout, those of another document do not")
unittest
{
    auto target = new LogTableTarget;
    const first = target.set(3, true);
    assert(target.doc == 3 && target.search && target.id == first);
    assert(target.set(3, false) != first && target.id != first, "every table has a number of its own");
    assert(!target.singleLine);
    target.singleLine = true;
    assert(target.singleLine, "the next table starts so");
    assert(target.layoutOf(3) is target.layoutOf(3));
    assert(target.layoutOf(3) !is target.layoutOf(4));
    auto old = target.layoutOf(3);
    target.forget(3);
    assert(target.layoutOf(3) !is old, "a closed document's layout is not kept");
}
