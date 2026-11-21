//! The least widths of the columns of the log table as the CSS of the application gives them: a variable of `.log-table-view` for the
//! columns that every table has (`--column-min-width-anchor`, `-index`, `-payload`), one for each column of each format
//! (`--column-min-width-<format>-<column>`, the ids the settings know: `--column-min-width-dlt-time`) and `--column-min-width` for a
//! column no variable names. A width is of the content of a cell, as `min-width` in CSS: the paddings of the cell and the line between
//! the columns come on top. The script reads the variables by the names this module lists and tells D the widths by their keys
//! (the name without the prefix, `default` for the plain one). Free of Sciter. See docs/stories/painted-table.md.
module ui.log_table.column_widths;

import log_core.log_format : ColumnKind;
import ui.log_table.log_columns : anchorColumnId, indexColumnId;

/// The start of the names of the variables
enum minWidthPrefix = "column-min-width";

/// The key of the width of a column no variable names
enum defaultKey = "default";

/// The width the columns have when the CSS gives none: the anchor and the Index and the columns of the formats a glyph or a few, the Payload a little
/// more than that (it takes the rest of the room, and a table of any width keeps a few characters of it)
enum double anchorMinWidth = 24, indexMinWidth = 24, columnMinWidth = 24, payloadMinWidth = 58;

/// The name of the CSS variable of a key (`dlt-time`, `anchor`, `default`)
string minWidthVariable(string key)
{
    return key == defaultKey ? minWidthPrefix : minWidthPrefix ~ "-" ~ key;
}

/// The key of a column of a format: the format and the column, `dlt-time`
string columnMinWidthKey(string formatId, string columnId)
{
    return formatId ~ "-" ~ columnId;
}

/// The key a name of a variable has (the other way round of `minWidthVariable`); empty if it is not a name of the kind
string minWidthKeyOf(string variable)
{
    import std.algorithm.searching : skipOver;

    if (variable == minWidthPrefix)
        return defaultKey;
    if (!variable.skipOver(minWidthPrefix ~ "-") || variable.length == 0)
        return "";
    return variable;
}

/// The width of the column of `key`: its own, else the default one, else `fallback`
double minWidthOf(const double[string] widths, string key, double fallback)
{
    if (auto own = key in widths)
        return *own;
    if (auto plain = defaultKey in widths)
        return *plain;
    return fallback;
}

/// The names of all the variables the script reads: the default, the columns every table has, and the column of each format but the
/// Payload (the one of every table)
string[] minWidthVariables()
{
    import formats.registry : formatColumns, formatInfos;

    string[] names = [minWidthVariable(defaultKey), minWidthVariable(anchorColumnId), minWidthVariable(indexColumnId), minWidthVariable("payload")];
    foreach (format; formatInfos())
        foreach (ref column; formatColumns(format.id))
            if (column.kind != ColumnKind.Payload)
                names ~= minWidthVariable(columnMinWidthKey(format.id, column.id));
    return names;
}

@("minWidthVariable, minWidthKeyOf: the plain name is the default one, the others carry their key")
unittest
{
    assert(minWidthVariable(defaultKey) == "column-min-width" && minWidthVariable("anchor") == "column-min-width-anchor");
    assert(minWidthVariable("dlt-time") == "column-min-width-dlt-time");
    assert(columnMinWidthKey("dlt", "time") == "dlt-time");
    foreach (key; [defaultKey, "anchor", "dlt-time"])
        assert(minWidthKeyOf(minWidthVariable(key)) == key);
    assert(minWidthKeyOf("bg-row") == "" && minWidthKeyOf("column-min-width-") == "");
}

@("minWidthOf: its own width, else the default one, else the fallback")
unittest
{
    const double[string] none;
    assert(minWidthOf(none, "dlt-time", 24) == 24);
    const widths = [defaultKey: 30.0, "anchor": 20.0];
    assert(minWidthOf(widths, "anchor", 24) == 20 && minWidthOf(widths, "dlt-time", 24) == 30, "the default one for a column with none of its own");
}

@("minWidthVariables: the default, the columns every table has, and every column of every format but the Payload, each once")
unittest
{
    import std.algorithm.searching : canFind, count;

    const names = minWidthVariables();
    foreach (name; ["column-min-width", "column-min-width-anchor", "column-min-width-index", "column-min-width-payload",
        "column-min-width-dlt-time", "column-min-width-dlt-ecu", "column-min-width-logcat-tag"])
        assert(names.canFind(name), name);
    assert(!names.canFind("column-min-width-dlt-payload"), "the Payload is the same in every format");
    foreach (name; names)
        assert(names.count(name) == 1, name ~ " is listed twice");
}

@("minWidthVariables: every least width the CSS of the application gives is of a name D knows: a mistyped one would be read by nobody")
unittest
{
    import std.algorithm.searching : canFind;
    import std.regex : ctRegex, matchAll;

    enum css = import("table.css");
    const names = minWidthVariables();
    size_t found;
    foreach (m; matchAll(css, ctRegex!`--(column-min-width[\w-]*)\s*:`))
    {
        ++found;
        assert(names.canFind(m[1]), "table.css gives --" ~ m[1] ~ ", a name D does not read");
    }
    assert(found > 0, "the variables are found in table.css");
}
