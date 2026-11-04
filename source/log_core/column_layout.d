//! The layout of the columns of a log table chosen by the user for a format:
//! the order of the movable columns and which of them are shown. The Index
//! column (not a column of the format) stays first, Payload stays last and
//! is always shown: neither is in a layout.
module log_core.column_layout;

import log_core.log_format : ColumnInfo, ColumnKind;

import std.algorithm : canFind, countUntil, filter, map;
import std.array : array, insertInPlace;

//! A movable column in a layout
struct ColumnState
{
    string id; // ColumnInfo.id
    bool visible = true;
}

//! @returns the ids of the columns that can be moved and hidden: all but Payload
string[] movableIds(const(ColumnInfo)[] columns)
{
    return columns.filter!(c => c.kind != ColumnKind.Payload).map!(c => c.id[]).array;
}

//! @brief Merges two orders of ids: `base` as it is, then each id of `extra`
//! it lacks right after the id that precedes it in `extra` (at the start if
//! none does). Used to place the columns a layout doesn't know (added to the
//! format later, of another variant) next to their neighbours in the format.
string[] mergeOrder(const(string)[] base, const(string)[] extra)
{
    string[] result = base.dup;
    size_t next = 0; // where an id with no predecessor in the result goes
    foreach (i, id; extra)
    {
        const at = result.countUntil(id);
        if (at >= 0)
        {
            next = at + 1;
            continue;
        }
        result.insertInPlace(next, id);
        ++next;
    }
    return result;
}

//! @brief The layout of the movable columns `ids` (in the order of the
//! format) as `layout` arranges them: every one of `ids` once, in the order
//! of the layout, those it doesn't know at their place by the format and
//! shown. The ids of the layout that aren't in `ids` are kept: they are
//! columns of another variant of the format.
ColumnState[] fullLayout(const(string)[] ids, const(ColumnState)[] layout)
{
    ColumnState[] known; // the layout without duplicates
    foreach (state; layout)
        if (!known.canFind!(k => k.id == state.id))
            known ~= state;
    ColumnState[] result;
    foreach (id; mergeOrder(known.map!(k => k.id).array, ids))
    {
        const at = known.countUntil!(k => k.id == id);
        result ~= at >= 0 ? known[at] : ColumnState(id);
    }
    return result;
}

//! @brief The columns of the table for `columns` of a format: the movable
//! ones as `layout` arranges and shows them, Payload last.
const(ColumnInfo)[] arrangeColumns(const(ColumnInfo)[] columns, const(ColumnState)[] layout)
{
    if (layout.length == 0)
        return columns;
    const(ColumnInfo)[] result;
    foreach (state; fullLayout(movableIds(columns), layout))
    {
        if (!state.visible)
            continue;
        const at = columns.countUntil!(c => c.id == state.id && c.kind != ColumnKind.Payload);
        if (at >= 0) // not a column of another variant
            result ~= columns[at];
    }
    result ~= columns.filter!(c => c.kind == ColumnKind.Payload).array;
    return result;
}

//! @returns true if `layout` shows the movable columns `ids` as they are
//! without a layout: in their order, all of them
bool isDefaultLayout(const(ColumnState)[] layout, const(string)[] ids)
{
    return fullLayout(ids, layout) == fullLayout(ids, null);
}

version (unittest)
{
    private ColumnInfo column(string id, ColumnKind kind = ColumnKind.Text)
    {
        return ColumnInfo(id, id, kind);
    }

    private const(ColumnInfo)[] sample()
    {
        return [column("time", ColumnKind.Time), column("app"), column("ctx"),
            column("level", ColumnKind.Level), column("payload", ColumnKind.Payload)];
    }

    private const(string)[] ids(const(ColumnInfo)[] columns)
    {
        return columns.map!(c => c.id[]).array;
    }
}

@("movableIds: every column but Payload")
unittest
{
    assert(movableIds(sample()) == ["time", "app", "ctx", "level"]);
    assert(movableIds([column("payload", ColumnKind.Payload)]).length == 0);
}

@("mergeOrder: an id the base lacks goes after its predecessor in the other order")
unittest
{
    assert(mergeOrder(["a", "c"], ["a", "b", "c"]) == ["a", "b", "c"]);
    assert(mergeOrder(["c", "a"], ["a", "b", "c"]) == ["c", "a", "b"], "after a, wherever a is");
    assert(mergeOrder(["a"], ["b", "a"]) == ["b", "a"], "no predecessor: at the start");
    assert(mergeOrder(["a"], ["b", "c"]) == ["b", "c", "a"], "a run of new ids keeps its order");
    assert(mergeOrder([], ["a", "b"]) == ["a", "b"]);
    assert(mergeOrder(["a", "b"], []) == ["a", "b"]);
}

@("arrangeColumns: no layout shows the columns of the format")
unittest
{
    assert(ids(arrangeColumns(sample(), null)) == ["time", "app", "ctx", "level", "payload"]);
}

@("arrangeColumns: the order and the visibility of the layout, Payload last")
unittest
{
    const layout = [ColumnState("level"), ColumnState("time"), ColumnState("app", false), ColumnState("ctx")];
    assert(ids(arrangeColumns(sample(), layout)) == ["level", "time", "ctx", "payload"]);
}

@("arrangeColumns: Payload stays last and shown whatever the layout says")
unittest
{
    const layout = [ColumnState("payload", false), ColumnState("ctx"), ColumnState("app"),
        ColumnState("time"), ColumnState("level")];
    assert(ids(arrangeColumns(sample(), layout)) == ["ctx", "app", "time", "level", "payload"]);
}

@("arrangeColumns: a column the layout doesn't know is shown next to its neighbour")
unittest
{
    const layout = [ColumnState("ctx"), ColumnState("time"), ColumnState("level", false)];
    assert(ids(arrangeColumns(sample(), layout)) == ["ctx", "time", "app", "payload"]);
}

@("arrangeColumns: columns of another variant in the layout are skipped")
unittest
{
    const layout = [ColumnState("tid"), ColumnState("level"), ColumnState("time"), ColumnState("app"),
        ColumnState("ctx")];
    assert(ids(arrangeColumns(sample(), layout)) == ["level", "time", "app", "ctx", "payload"]);
}

@("arrangeColumns: keeps the ColumnInfo of the format")
unittest
{
    const columns = arrangeColumns(sample(), [ColumnState("level"), ColumnState("time")]);
    assert(columns[0].kind == ColumnKind.Level);
    assert(columns[$ - 1].kind == ColumnKind.Payload);
}

@("fullLayout: every column once, in the order of the layout, unknown ones shown")
unittest
{
    const layout = [ColumnState("level", false), ColumnState("tid"), ColumnState("app")];
    assert(fullLayout(["time", "app", "ctx", "level"], layout) == [ColumnState("time"),
        ColumnState("level", false), ColumnState("tid"), ColumnState("app"), ColumnState("ctx")]);
    assert(fullLayout(["a", "b"], null) == [ColumnState("a"), ColumnState("b")]);
    assert(fullLayout(["a"], [ColumnState("a", false), ColumnState("a")]) == [ColumnState("a", false)],
        "a duplicate in the layout is dropped");
}

@("isDefaultLayout: only the order of the format with all columns shown")
unittest
{
    const ids = ["time", "app"];
    assert(isDefaultLayout(null, ids));
    assert(isDefaultLayout([ColumnState("time"), ColumnState("app")], ids));
    assert(!isDefaultLayout([ColumnState("app"), ColumnState("time")], ids));
    assert(!isDefaultLayout([ColumnState("time"), ColumnState("app", false)], ids));
    assert(isDefaultLayout([ColumnState("time")], ids), "app in its default place, shown");
}
