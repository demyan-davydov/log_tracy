//! The viewport of the painted table as the script reads it (`paintCall("viewport")`): the numbers by their names, as JSON. The table
//! (`ptable.scrollplace.Viewport`) is plain data and knows no JSON.
module ui.viewport_json;

import ptable.layout : Pin;
import ptable.scrollplace : Viewport;
import ptable.viewport : ScrollMetrics;

/// `viewport` as a JSON object: `first` {row, offset}, `rows` and `columns` {total, visible, position}, `area` {x, y, w, h}, `slots` [{row, top, height}],
/// `places` [{id, x, width, pinned}]
string viewportJson(ref const Viewport viewport)
{
    import std.json : JSONValue;

    JSONValue metrics(const ScrollMetrics m)
    {
        return JSONValue(["total": JSONValue(m.total), "visible": JSONValue(m.visible), "position": JSONValue(m.position)]);
    }

    JSONValue v = JSONValue.emptyObject;
    v["first"] = JSONValue(["row": JSONValue(viewport.first.first), "offset": JSONValue(viewport.first.offset)]);
    v["rows"] = metrics(viewport.rows);
    v["columns"] = metrics(viewport.columns);
    const area = viewport.area;
    v["area"] = JSONValue(["x": JSONValue(area.x), "y": JSONValue(area.y), "w": JSONValue(area.w), "h": JSONValue(area.h)]);
    v["slots"] = JSONValue.emptyArray;
    foreach (ref slot; viewport.slots)
        v["slots"].array ~= JSONValue(["row": JSONValue(slot.index), "top": JSONValue(slot.top), "height": JSONValue(slot.height)]);
    v["places"] = JSONValue.emptyArray;
    foreach (ref place; viewport.places)
        v["places"].array ~= JSONValue(["id": JSONValue(place.id), "x": JSONValue(place.x), "width": JSONValue(place.width),
            "pinned": JSONValue(place.area != Pin.none)]);
    return v.toString;
}

@("viewportJson: as JSON the first row with its offset, the metrics of the rows and the columns, the area, the rows and the columns on the screen")
unittest
{
    import ptable.layout : Placement;
    import ptable.ports : Rect;
    import ptable.rowlayout : RowSlot, ViewState;
    import std.json : JSONType, JSONValue, parseJSON;

    // a whole number is written without a point and read back as an integer
    double num(JSONValue value) { return value.type == JSONType.float_ ? value.floating : cast(double) value.integer; }

    Viewport v;
    v.first = ViewState(7, 3.5);
    v.rows = ScrollMetrics(100, 6, 7.25);
    v.columns = ScrollMetrics(220, 100, 30);
    v.area = Rect(0, 21, 100, 100);
    v.slots = [RowSlot(7, -3.5, 16), RowSlot(8, 12.5, 16)];
    v.places = [Placement("n", -30, 70, Pin.none), Placement("text", 40, 150, Pin.right)];
    const j = parseJSON(viewportJson(v));
    assert(j["first"]["row"].integer == 7 && num(j["first"]["offset"]) == 3.5);
    assert(j["rows"]["total"].integer == 100 && num(j["rows"]["position"]) == 7.25 && num(j["columns"]["position"]) == 30);
    assert(num(j["area"]["y"]) == 21 && num(j["area"]["h"]) == 100);
    assert(j["slots"].array.length == 2 && j["slots"][0]["row"].integer == 7 && num(j["slots"][0]["top"]) == -3.5);
    assert(j["places"][0]["id"].str == "n" && !j["places"][0]["pinned"].boolean && j["places"][1]["pinned"].boolean);
    Viewport empty;
    empty.rows = empty.columns = ScrollMetrics(0, 0, 0);
    assert(parseJSON(viewportJson(empty))["slots"].array.length == 0, "nothing shown: empty lists");
}
