//! What the painted table shows now as the script reads it (`paintCall("view")`): the numbers by their names, as JSON. The table
//! (`ptable.table`) answers in plain data and knows no JSON.
module ui.view_json;

import ptable.ports : Size;
import ptable.scrollplace : CellPosition;

/// `{"size": {w, h}, "rows": [first, past the last], "first": cell, "last": cell}`, a cell is `{row, column, dy, dx}`
string viewJson(Size size, size_t[2] rows, CellPosition first, CellPosition last)
{
    import std.json : JSONValue;

    JSONValue cell(CellPosition at)
    {
        return JSONValue(["row": JSONValue(at.row), "column": JSONValue(at.column), "dy": JSONValue(at.dy), "dx": JSONValue(at.dx)]);
    }

    JSONValue v = JSONValue.emptyObject;
    v["size"] = JSONValue(["w": JSONValue(size.w), "h": JSONValue(size.h)]);
    v["rows"] = JSONValue([JSONValue(rows[0]), JSONValue(rows[1])]);
    v["first"] = cell(first);
    v["last"] = cell(last);
    return v.toString;
}

@("viewJson: the size, the rows in sight, the first and the last cell by their names")
unittest
{
    import std.json : JSONType, JSONValue, parseJSON;

    // a whole number is written without a point and read back as an integer
    double num(JSONValue value) { return value.type == JSONType.float_ ? value.floating : cast(double) value.integer; }

    const j = parseJSON(viewJson(Size(100, 99.5), [2, 9], CellPosition(2, 0, -8, -30.5), CellPosition(8, 1, 88, 40)));
    assert(num(j["size"]["w"]) == 100 && num(j["size"]["h"]) == 99.5);
    assert(j["rows"].array.length == 2 && j["rows"][0].integer == 2 && j["rows"][1].integer == 9);
    assert(j["first"]["row"].integer == 2 && j["first"]["column"].integer == 0 && num(j["first"]["dy"]) == -8 && num(j["first"]["dx"]) == -30.5);
    assert(j["last"]["row"].integer == 8 && j["last"]["column"].integer == 1 && num(j["last"]["dy"]) == 88 && num(j["last"]["dx"]) == 40);
}
