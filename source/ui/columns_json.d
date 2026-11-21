//! The columns of a log as JSON for the script (the Settings arrange them), free of Sciter. The values of the columns are read by
//! log_core/column_values.
module ui.columns_json;

import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message : TimeKind;

import std.json : JSONValue;

//! @brief The columns of a log of the format `formatId` (FormatInfo.id) as
//! JSON for the script (the Settings arrange them): a column is found by the
//! ids of its format and of the column
string columnsJson(const(ColumnInfo)[] columns, string formatId)
{
    import std.conv : to;

    JSONValue[] result;
    foreach (ref column; columns)
    {
        JSONValue c = [
            "id": JSONValue(column.id),
            "format": JSONValue(formatId),
            "title": JSONValue(column.title),
            "kind": JSONValue(column.kind.to!string),
        ];
        if (column.kind == ColumnKind.Time)
            c["timeKind"] = JSONValue(column.timeKind.to!string);
        if (column.kind == ColumnKind.Duration)
            c["unitsPerSecond"] = JSONValue(column.unitsPerSecond);
        if (column.kind == ColumnKind.Enum)
            c["labels"] = JSONValue(column.labels);
        if (column.byLevel)
            c["byLevel"] = JSONValue(true);
        result ~= c;
    }
    return JSONValue(result).toString();
}

@("columnsJson: a column colored by the level says so")
unittest
{
    import std.algorithm.searching : canFind, count;

    const json = columnsJson([
        ColumnInfo("status", "Status", ColumnKind.Integer, 0, TimeKind.None, 0, null, true),
        ColumnInfo("bytes", "Bytes", ColumnKind.Integer, 1),
    ], "access-log");
    assert(json.canFind(`"byLevel":true`), json);
    assert(json.count(`"byLevel"`) == 1, "only for the flagged column");
}

@("columnsJson: every column names its format, the look of a column is left to the style")
unittest
{
    import std.algorithm.searching : canFind, count;

    const json = columnsJson([
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ], "dlt");
    assert(json.count(`"format":"dlt"`) == 2, json);
    assert(!json.canFind(`"width"`), json);
}
