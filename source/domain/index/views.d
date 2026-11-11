//! ViewIndexes: the rows of the two views of a log over its records. The main view shows
//! every record, or those of the filter index when it is filtered; the search view, those
//! of the search index. Both indexes hold record numbers, ascending.
//!
//! Not thread-safe: its holder (LogIndex) synchronizes it. The entries of an index don't
//! move while it only grows (utils/chunked_array); clearing an index and the in-place
//! changes for an anchor (listAnchor, unlistAnchor) move or drop them.
module domain.index.views;

import domain.index.filter_index : FilterIndex;
import domain.index.search_index : SearchIndex;

struct ViewIndexes
{
    private FilterIndex _filterIndex; // the records the main view shows when it is filtered
    private SearchIndex _searchIndex; // the records the search view shows
    private bool _filtered; // the main view shows the filter index, not every record

    //! The main view shows the filter index from now on, every record if not `filtered`;
    //! both indexes are empty: what they showed goes
    void filterMain(bool filtered) nothrow @nogc
    {
        _filtered = filtered;
        _filterIndex.clear();
        _searchIndex.clear();
    }

    //! The search view is empty
    void clearSearch() nothrow @nogc
    {
        _searchIndex.clear();
    }

    //! The main view shows the filter index
    bool mainFiltered() const pure nothrow @nogc
    {
        return _filtered;
    }

    //! The rows of the main view over `records` records
    size_t mainLength(size_t records) const pure nothrow @nogc
    {
        return _filtered ? _filterIndex.length : records;
    }

    //! The rows of the search view
    size_t searchLength() const pure nothrow @nogc
    {
        return _searchIndex.length;
    }

    //! The record the main view shows at `position` < mainLength
    size_t mainRecordAt(size_t position) const pure nothrow @nogc
    {
        return _filtered ? cast(size_t) _filterIndex[position] : position;
    }

    //! The record the search view shows at `position` < searchLength
    size_t searchRecordAt(size_t position) const pure nothrow @nogc
    {
        return cast(size_t) _searchIndex[position];
    }

    //! Appends records the filter found to the main view, in order
    //! @return false if the index can't grow (2^32 entries, not enough memory)
    bool appendMain(const(FilterIndex.Type)[] records) nothrow @nogc
    {
        return _filterIndex.append(records);
    }

    //! Appends records the search found to the search view, in order
    //! @return false if the index can't grow
    bool appendSearch(const(SearchIndex.Type)[] records) nothrow @nogc
    {
        return _searchIndex.append(records);
    }

    //! @brief The position in the main view of the record `record` of `records`
    //! @return false if the view doesn't show it
    bool mainPositionOf(size_t record, size_t records, out size_t position) const pure nothrow @nogc
    {
        if (!_filtered)
        {
            position = record;
            return record < records;
        }
        return sortedPositionOf(_filterIndex, record, position);
    }

    //! @brief The position in the search view of the record `record`
    //! @return false if the view doesn't show it
    bool searchPositionOf(size_t record, out size_t position) const pure nothrow @nogc
    {
        return sortedPositionOf(_searchIndex, record, position);
    }

    //! @brief The row of the main view nearest to the record `record`: its own, or of the
    //! first record after it the view shows, else the last row
    //! @return false if the view is empty
    bool mainNearestOf(size_t record, size_t records, out size_t position) const pure nothrow @nogc
    {
        if (!_filtered)
            return nearestOf(record, records, position);
        return sortedNearestOf(_filterIndex, record, position);
    }

    //! The row of the search view nearest to the record `record`, as mainNearestOf
    bool searchNearestOf(size_t record, out size_t position) const pure nothrow @nogc
    {
        return sortedNearestOf(_searchIndex, record, position);
    }

    //! @brief Appends to the search view the anchored records `anchored` (ascending) the
    //! main view shows at the positions [from, to)
    //! @param listed - set if there were any
    //! @return false if the index can't grow
    bool listAnchors(const(size_t)[] anchored, size_t from, size_t to, size_t records, out bool listed) nothrow @nogc
    {
        foreach (record; anchored)
        {
            size_t position;
            if (!mainPositionOf(record, records, position) || position < from || position >= to)
                continue;
            if (!_searchIndex.append(cast(SearchIndex.Type) record))
                return false;
            listed = true;
        }
        return true;
    }

    //! @brief An anchored record is listed in place: in the main view if it is filtered,
    //! in the search view if `search`
    void listAnchor(size_t record, bool search) nothrow @nogc
    {
        const value = cast(SearchIndex.Type) record;
        if (_filtered)
            _filterIndex.insertSorted(value);
        if (search)
            _searchIndex.insertSorted(value);
    }

    //! @brief A record no longer anchored leaves in place the views it doesn't match by
    //! itself: the main view unless `inMain`, the search view unless `inSearch`
    void unlistAnchor(size_t record, bool inMain, bool inSearch) nothrow @nogc
    {
        const value = cast(SearchIndex.Type) record;
        if (!inMain)
            _filterIndex.removeSorted(value);
        if (!inSearch)
            _searchIndex.removeSorted(value);
    }

    //! Memory the indexes have taken, in bytes
    size_t reservedBytes() const pure nothrow @nogc
    {
        return _filterIndex.reservedBytes + _searchIndex.reservedBytes;
    }
}

//! `position` (a row of `count`), or the last row past them; false if there are none
private bool nearestOf(size_t position, size_t count, out size_t nearest) pure nothrow @nogc @safe
{
    if (count == 0)
        return false;
    nearest = position < count ? position : count - 1;
    return true;
}

//! The nearest position of `record` in an index of record numbers sorted ascending
private bool sortedNearestOf(Index)(ref const(Index) index, size_t record, out size_t position)
{
    const bound = record > Index.Type.max ? index.length : index.lowerBound(cast(Index.Type) record);
    return nearestOf(bound, index.length, position);
}

//! The position of `record` in an index of record numbers sorted ascending
private bool sortedPositionOf(Index)(ref const(Index) index, size_t record, out size_t position)
{
    if (record > Index.Type.max)
        return false;
    position = index.lowerBound(cast(Index.Type) record);
    return position < index.length && index[position] == record;
}

@("ViewIndexes: the main view shows every record until it is filtered")
unittest
{
    ViewIndexes views;
    size_t position;
    assert(views.mainLength(5) == 5 && views.mainRecordAt(3) == 3);
    assert(views.mainPositionOf(4, 5, position) && position == 4);
    assert(!views.mainPositionOf(5, 5, position));
    assert(views.mainNearestOf(9, 5, position) && position == 4, "past the end: the last row");

    views.filterMain(true);
    assert(views.appendMain([1u, 4, 7]));
    assert(views.mainLength(10) == 3 && views.mainRecordAt(1) == 4);
    assert(views.mainPositionOf(7, 10, position) && position == 2);
    assert(!views.mainPositionOf(5, 10, position), "filtered out");
    assert(views.mainNearestOf(5, 10, position) && position == 2, "the first shown after it");
}

@("ViewIndexes: a filter or a reset of the main view empties both views")
unittest
{
    ViewIndexes views;
    views.filterMain(true);
    assert(views.appendMain([1u]) && views.appendSearch([1u]));
    views.filterMain(false);
    assert(views.mainLength(3) == 3 && views.searchLength == 0);
}

@("ViewIndexes: the anchors of a range of the main view are listed in the search view")
unittest
{
    ViewIndexes views;
    views.filterMain(true);
    assert(views.appendMain([2u, 5, 8, 9]));
    bool listed;
    // 5 and 9 are shown at positions 1 and 3, 6 isn't shown
    assert(views.listAnchors([5, 6, 9], 0, 3, 10, listed));
    assert(listed && views.searchLength == 1 && views.searchRecordAt(0) == 5);
    listed = false;
    assert(views.listAnchors([5, 6, 9], 3, 4, 10, listed));
    assert(listed && views.searchLength == 2 && views.searchRecordAt(1) == 9);
}

@("ViewIndexes: an anchor is listed and unlisted in place")
unittest
{
    ViewIndexes views;
    views.filterMain(true);
    assert(views.appendMain([2u, 8]) && views.appendSearch([8u]));
    views.listAnchor(5, true);
    assert(views.mainLength(10) == 3 && views.mainRecordAt(1) == 5);
    assert(views.searchLength == 2 && views.searchRecordAt(0) == 5);
    views.unlistAnchor(5, false, true);
    assert(views.mainLength(10) == 2, "it doesn't match the filter");
    assert(views.searchLength == 2, "it matches the search");
}
