//! What a log table tells the script and answers it, as the JSON the script parses (resources/log-table-view.js): a row the user
//! chose, a click on a clickable cell, a copy cut by its limit, the current row. Free of Sciter: the behavior
//! (ui/log_table_behavior) reads the facts off the table and sends the text.
module ui.table_messages;

import ptable.ports : Rect;
import std.json : JSONValue;

/// A row was selected by the user, the other table follows it: which table, the item, the message, and whether it may move on
string rowChosenJson(size_t table, size_t row, ulong id, bool delayed)
{
    JSONValue chosen = ["table": JSONValue(table), "row": JSONValue(row), "id": JSONValue(id), "delayed": JSONValue(delayed)];
    return chosen.toString;
}

/// A click on a cell of a clickable column: which table, the item, the message, the column, whether the row is anchored, and where the
/// cell is in the table (`area`, null: not known) for what the script shows by it
string cellClickedJson(size_t table, size_t item, ulong id, string column, bool anchored, const(Rect)* area)
{
    JSONValue click = ["table": JSONValue(table), "item": JSONValue(item), "id": JSONValue(id), "column": JSONValue(column),
        "anchored": JSONValue(anchored)];
    if (area !is null)
        click["rect"] = [area.x, area.y, area.w, area.h];
    return click.toString;
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

@("cellClickedJson: the cell and its message, with the place of the cell when it is known")
unittest
{
    const area = Rect(1, 2, 30, 16);
    auto json = parseOf(cellClickedJson(1, 7, 99, "anchor", true, &area));
    assert(json["table"].integer == 1 && json["item"].integer == 7 && json["id"].integer == 99 && json["column"].str == "anchor"
        && json["anchored"].boolean);
    assert(json["rect"].array.length == 4 && json["rect"][2].floating == 30);
    json = parseOf(cellClickedJson(1, 7, 99, "anchor", false, null));
    assert(!json["anchored"].boolean && "rect" !in json, "no place: none told");
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
