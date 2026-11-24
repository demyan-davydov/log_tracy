//! What a log table tells the script and answers it, as the JSON the script parses (resources/log-table-view.js): a row the user
//! chose, what the mouse did to a title or a cell, a copy cut by its limit, the current row. Free of Sciter: the behavior
//! (ui/log_table_behavior) reads the facts off the table and sends the text.
module ui.table_messages;

import ptable.ports : Rect;
import ptable.table : PointerAction, PointerMessage, PointerTarget, TargetKind;
import std.json : JSONValue;

/// A row was selected by the user, the other table follows it: which table, the item, the message, and whether it may move on
string rowChosenJson(size_t table, size_t row, ulong id, bool delayed)
{
    JSONValue chosen = ["table": JSONValue(table), "row": JSONValue(row), "id": JSONValue(id), "delayed": JSONValue(delayed)];
    return chosen.toString;
}

/// What the behavior reads for a `PointerMessage` before it tells the script
struct PointerReads
{
    bool row; /// the message of the cell and whether it is anchored: a click on a cell only (an enter comes at every frame of a scroll)
    bool place; /// where the thing is: not for a leave nor a cancel, which name the thing as it was entered or pressed (its row may be another by now)
}

/// What the behavior reads for `event`
PointerReads readsOf(in PointerMessage event) pure nothrow @nogc @safe
{
    return PointerReads(event.action == PointerAction.click && event.target.kind == TargetKind.cell, event.action != PointerAction.leave && event.action != PointerAction.cancel);
}

/// What the mouse did to a thing of a table (`ptable` `PointerMessage`): which table, `type` enter / leave / down / up / click / cancel, `kind` header / cell, the
/// column (`column` its id, `index` its index in the model's columns), of a cell its `row`, and its message `id` with whether it is
/// `anchored` when the behavior read them (`id` null: not read, it reads them for a click on a cell, and tells no click on a row that is gone), and where the thing is in the table
/// (`rect`; `area` null: not known or not told)
string pointerJson(size_t table, in PointerMessage event, string column, const(ulong)* id, bool anchored, const(Rect)* area)
{
    import std.conv : to;

    JSONValue v = ["table": JSONValue(table), "type": JSONValue(event.action.to!string), "column": JSONValue(column),
        "index": JSONValue(event.target.column)];
    v["kind"] = event.target.kind == TargetKind.cell ? "cell" : "header";
    if (event.target.kind == TargetKind.cell)
    {
        v["row"] = event.target.row;
        if (id !is null)
        {
            v["id"] = *id;
            v["anchored"] = anchored;
        }
    }
    if (area !is null)
        v["rect"] = [area.x, area.y, area.w, area.h];
    return v.toString;
}

/// A copy of rows stopped at the limit of the copy: how many rows of how many went to the clipboard
string copyCutJson(size_t table, size_t copied, size_t total)
{
    JSONValue cut = ["table": JSONValue(table), "copied": JSONValue(copied), "total": JSONValue(total)];
    return cut.toString;
}

/// The current row of a table and its message; "null" when it has none
string currentRowJson(bool has, long row, ulong id)
{
    return has ? JSONValue(["row": JSONValue(row), "id": JSONValue(id)]).toString : "null";
}

@("rowChosenJson: the table, the row, the message and whether it may move on")
unittest
{
    const json = parseOf(rowChosenJson(2, 15, 1234, true));
    assert(json["table"].integer == 2 && json["row"].integer == 15 && json["id"].integer == 1234 && json["delayed"].boolean);
}

@("readsOf: a click on a cell reads its row, a leave reads nothing, an enter and a click its place")
unittest
{
    alias ev = (PointerAction action, PointerTarget target) => PointerMessage(action, target);
    assert(readsOf(ev(PointerAction.click, PointerTarget.cell(1, 0))) == PointerReads(true, true));
    assert(readsOf(ev(PointerAction.click, PointerTarget.header(0))) == PointerReads(false, true), "a title has no row");
    assert(readsOf(ev(PointerAction.enter, PointerTarget.cell(1, 0))) == PointerReads(false, true));
    assert(readsOf(ev(PointerAction.leave, PointerTarget.cell(1, 0))) == PointerReads(false, false));
    assert(readsOf(ev(PointerAction.leave, PointerTarget.header(0))) == PointerReads(false, false));
    assert(readsOf(ev(PointerAction.cancel, PointerTarget.cell(1, 0))) == PointerReads(false, false), "the cell of the press may be another one by now");
}

@("pointerJson: a cell clicked, with its message and its place when they are known")
unittest
{
    const area = Rect(1, 2, 30, 16);
    const ulong id = 99;
    const click = PointerMessage(PointerAction.click, PointerTarget.cell(7, 2));
    auto json = parseOf(pointerJson(1, click, "anchor", &id, true, &area));
    assert(json["table"].integer == 1 && json["type"].str == "click" && json["kind"].str == "cell" && json["column"].str == "anchor"
        && json["index"].integer == 2 && json["row"].integer == 7 && json["id"].integer == 99 && json["anchored"].boolean);
    assert(json["rect"].array.length == 4 && json["rect"][2].floating == 30);
    json = parseOf(pointerJson(1, click, "anchor", null, false, null));
    assert("id" !in json && "anchored" !in json && "rect" !in json, "the row is gone, no place: none told");
}

@("pointerJson: a title entered and left: its column, no row")
unittest
{
    const area = Rect(40, 0, 30, 21);
    auto json = parseOf(pointerJson(3, PointerMessage(PointerAction.enter, PointerTarget.header(4)), "ecu", null, false, &area));
    assert(json["type"].str == "enter" && json["kind"].str == "header" && json["column"].str == "ecu" && json["index"].integer == 4
        && "row" !in json && "id" !in json && json["rect"][0].floating == 40);
    json = parseOf(pointerJson(3, PointerMessage(PointerAction.leave, PointerTarget.header(4)), "ecu", null, false, &area));
    assert(json["type"].str == "leave");
}

@("copyCutJson: how many rows went to the clipboard of how many")
unittest
{
    const json = parseOf(copyCutJson(3, 120, 5000));
    assert(json["table"].integer == 3 && json["copied"].integer == 120 && json["total"].integer == 5000);
}

@("currentRowJson: the row and its message, null when there is none")
unittest
{
    const json = parseOf(currentRowJson(true, 42, 4242));
    assert(json["row"].integer == 42 && json["id"].integer == 4242);
    assert(currentRowJson(false, 0, 0) == "null");
}

version (unittest)
{
    private JSONValue parseOf(string text)
    {
        import std.json : parseJSON;

        return parseJSON(text);
    }
}
