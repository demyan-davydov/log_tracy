//! What the next painted table (behavior `paint-rows`) is to show: a document and one of its views, and the
//! column layout the tables of a document share, so the main table and the search table of a document keep
//! the same widths, hidden columns and horizontal scroll. Free of Sciter.
module ui.log_table.paint_target;

import ptable.layout : ColumnLayout;
import ui.log_table.log_look : defaultLogLook, LogLook;

/// The view the next painted table shows, and the layouts of the documents
final class PaintTarget
{
    private int _doc = -1;
    private bool _search;
    private ColumnLayout[int] _layouts;
    private LogLook _look;

    /// The next painted table shows the view of the document `doc`
    void set(int doc, bool search)
    {
        _doc = doc;
        _search = search;
    }

    int doc() const { return _doc; }
    bool search() const { return _search; }

    /// The look every painted table has: one for the application, its change reaches all the tables
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

@("PaintTarget: the tables of a document share one layout, those of another document do not")
unittest
{
    auto target = new PaintTarget;
    target.set(3, true);
    assert(target.doc == 3 && target.search);
    assert(target.layoutOf(3) is target.layoutOf(3));
    assert(target.layoutOf(3) !is target.layoutOf(4));
    auto old = target.layoutOf(3);
    target.forget(3);
    assert(target.layoutOf(3) !is old, "a closed document's layout is not kept");
}
