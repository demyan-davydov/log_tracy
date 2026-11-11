//! The tabs of the window: the documents they show, in their order, and the active one. The
//! documents themselves are in `domain/document_store`, each held by its tab. Free of Sciter.
module ui.document_tabs;

import domain.document_id : DocumentId;

import std.algorithm : countUntil, remove;
import std.array : insertInPlace;

struct DocumentTabs
{
    private DocumentId[] _ids; // in the order of the tabs
    private size_t _active; // a position in _ids; past the end: no tab

    /// A tab for the document `docId`, after the others; not made active
    void add(DocumentId docId)
    {
        assert(!has(docId), "a document has one tab");
        _ids ~= docId;
    }

    /// Makes the tab of `docId` the active one. Returns: false if there is none
    bool activate(DocumentId docId)
    {
        const idx = indexOf(docId);
        if (idx == -1)
            return false;
        _active = idx;
        return true;
    }

    /// Removes the tab of `docId`. Closing the active tab makes its right neighbour active,
    /// the left one if it was the last. Returns: false if there is none
    bool remove(DocumentId docId)
    {
        const idx = indexOf(docId);
        if (idx == -1)
            return false;
        _ids = _ids.remove(idx);
        // _active is a position: a tab closed before it shifts it
        if (idx < _active)
            _active--;
        if (_active >= _ids.length && _active > 0)
            _active = _ids.length - 1;
        return true;
    }

    /// Moves the tab of `docId` to position `index`; the active tab stays active.
    /// Returns: false if there is no such tab or position
    bool move(DocumentId docId, size_t index)
    {
        const idx = indexOf(docId);
        if (idx == -1 || index >= _ids.length)
            return false;
        const current = active;
        _ids = _ids.remove(idx);
        _ids.insertInPlace(index, docId);
        if (current.isValid)
            _active = indexOf(current);
        return true;
    }

    /// The document of the active tab, an invalid id if there is no tab
    DocumentId active() const pure nothrow @nogc
    {
        return _active < _ids.length ? _ids[_active] : DocumentId.init;
    }

    /// True if the document `docId` has a tab
    bool has(DocumentId docId) const pure nothrow @nogc
    {
        return indexOf(docId) != -1;
    }

    /// The documents of the tabs, in their order
    const(DocumentId)[] ids() const pure nothrow @nogc
    {
        return _ids;
    }

    /// The number of tabs
    size_t length() const pure nothrow @nogc
    {
        return _ids.length;
    }

    private ptrdiff_t indexOf(DocumentId docId) const pure nothrow @nogc
    {
        return _ids.countUntil(docId);
    }
}

version (unittest)
{
    import domain.document_id : DocumentIdGenerator;

    private DocumentId[] newIds(size_t n)
    {
        DocumentIdGenerator generator;
        DocumentId[] ids;
        foreach (i; 0 .. n)
            ids ~= generator.popId();
        return ids;
    }
}

@("DocumentTabs: add, activate, move, remove")
unittest
{
    const ids = newIds(2);
    DocumentTabs tabs;
    assert(tabs.length == 0 && !tabs.active.isValid);

    tabs.add(ids[0]);
    tabs.add(ids[1]);
    assert(tabs.ids == ids);
    assert(tabs.active == ids[0], "the first tab until another is activated");
    assert(tabs.activate(ids[1]) && tabs.active == ids[1]);

    assert(tabs.move(ids[1], 0));
    assert(tabs.ids == [ids[1], ids[0]]);

    assert(tabs.remove(ids[1]));
    assert(tabs.length == 1 && tabs.active == ids[0]);
    assert(!tabs.has(ids[1]) && !tabs.remove(ids[1]) && !tabs.activate(ids[1]));

    tabs.remove(ids[0]);
    assert(!tabs.active.isValid);
}

@("DocumentTabs: moving a tab keeps the active one active")
unittest
{
    const ids = newIds(3);
    const a = ids[0], b = ids[1], c = ids[2];
    DocumentTabs tabs;
    foreach (id; ids)
        tabs.add(id);

    tabs.activate(b);
    tabs.move(b, 0); // the active one moved: a tab dragged to the front
    assert(tabs.active == b);
    tabs.move(c, 0); // another one moved across it
    assert(tabs.active == b);
    tabs.move(c, 2); // and back behind it
    assert(tabs.active == b);
    tabs.activate(a);
    tabs.move(a, 2);
    assert(tabs.active == a);
    assert(!tabs.move(a, 3), "no such position");
}

@("DocumentTabs: closing a tab before the active one keeps the active one active")
unittest
{
    const ids = newIds(3);
    const a = ids[0], b = ids[1], c = ids[2];
    DocumentTabs tabs;
    foreach (id; ids)
        tabs.add(id);

    tabs.activate(b);
    tabs.remove(a);
    assert(tabs.active == b);
    // closing the active one makes its right neighbour active, the last one the left
    tabs.remove(b);
    assert(tabs.active == c);
    tabs.add(a);
    tabs.activate(a);
    tabs.remove(a);
    assert(tabs.active == c);
}
