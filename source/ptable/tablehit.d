//! What a point of the table hits, as the owner of a menu (the host's script) needs to know it: the part of the table, the row and
//! the column under the point, whether the row is picked, whether some text is selected, the text under the point; and what a copy
//! from such an address copies. The table answers (`Table.hitTest`) and copies from an address; it builds no menu and knows no menu
//! item. Pure. See docs/stories/painted-table.md.
module ptable.tablehit;

/// What a copy copies
enum CopyTarget : ubyte
{
    text, /// the text selected (the rows picked if none is selected)
    rows, /// the rows picked, the text selected ignored
    cell, /// the cell at an address (a row and a column)
}

/// What a point is on
enum HitKind : ubyte
{
    header, /// a column's title: a column, no row
    footer, /// the footer: neither
    cell, /// a cell of a row: a row and a column; `text` if the point is on the characters
    free, /// no row: below the rows, in a margin or the padding, a table with no rows; the column is the one under x
}

/// The text under the point: where, and the word
struct HitText
{
    long offset; /// the character in the text of the cell
    wstring word; /// the word it is in
}

/// The pointer the host shows over a point of the table
enum PointerKind : ubyte
{
    arrow, /// the ordinary one
    hand, /// over a cell of a clickable column
}

/// What is at a point of the table
struct TableHit
{
    HitKind kind;
    size_t row; /// of a cell
    string column; /// the id of the column under x ("" if the table has none): stable when the columns are reordered or hidden
    size_t columnIndex; /// its index in the model's columns: for the call that follows this one, not to be kept
    bool picked; /// the row is one of the rows picked
    bool hasText; /// some text is selected (a click keeps it); not that the point is on it
    bool onText; /// the point is on the characters of a cell
    HitText text; /// of `onText`

    /// As the script reads it: always an object, the fields of the kind only
    string toJson() const
    {
        import std.conv : to;
        import std.json : JSONValue;

        JSONValue v = ["kind": JSONValue(kindName)];
        v["column"] = column;
        v["index"] = columnIndex;
        v["hasText"] = hasText;
        if (kind == HitKind.cell)
        {
            v["row"] = row;
            v["picked"] = picked;
            if (onText)
                v["text"] = ["offset": JSONValue(text.offset), "word": JSONValue(text.word.to!string)];
        }
        return v.toString;
    }

    private string kindName() const
    {
        final switch (kind)
        {
        case HitKind.header: return "header";
        case HitKind.footer: return "footer";
        case HitKind.cell: return "cell";
        case HitKind.free: return "free";
        }
    }
}

@("TableHit: a cell is told with its row, column, whether it is picked and the text under the point")
unittest
{
    import std.json : parseJSON;

    TableHit hit;
    hit.kind = HitKind.cell;
    hit.row = 5;
    hit.column = "time";
    hit.columnIndex = 2;
    hit.picked = true;
    hit.onText = true;
    hit.text = HitText(3, "say \"hi\""w);
    const j = parseJSON(hit.toJson);
    assert(j["kind"].str == "cell" && j["row"].integer == 5 && j["column"].str == "time" && j["index"].integer == 2);
    assert(j["picked"].boolean && !j["hasText"].boolean);
    assert(j["text"]["offset"].integer == 3 && j["text"]["word"].str == "say \"hi\"", "quotes survive");
}

@("TableHit: a header has a column and no row, free space and the footer too; a cell off the text has no text")
unittest
{
    import std.json : parseJSON;

    TableHit hit;
    hit.kind = HitKind.header;
    hit.column = "level";
    auto j = parseJSON(hit.toJson);
    assert(j["kind"].str == "header" && j["column"].str == "level" && "row" !in j.object && "picked" !in j.object);
    hit.kind = HitKind.free;
    assert(parseJSON(hit.toJson)["kind"].str == "free");
    hit.kind = HitKind.cell;
    j = parseJSON(hit.toJson);
    assert("row" in j.object && "text" !in j.object);
}
