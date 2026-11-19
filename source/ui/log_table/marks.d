//! What the model of the log table attaches to rows and columns for its painter (the `Extra` of the
//! painted table, ptable): the level and the marks of a row, the role of a column. The table never
//! reads them; the model writes them and the painter reads them. Free of Sciter.
module ui.log_table.marks;

import log_core.log_format : ColumnKind;
import log_core.log_level : LogLevel;

/// The bits of `RowData.extra.bits` of a row of the log
enum ulong levelMask = 0x7; /// the `LogLevel`
enum ulong foundMark = 0x8; /// the search found the record
enum ulong anchoredMark = 0x10; /// the record has an anchor

/// The extra data of the Index cell: the color of the filter rule the record matches, if it has one (a flag and
/// "#rrggbb" as 0xRRGGBB); the painter shows it as a gradient in that cell only
enum ulong ruleColorFlag = 0x1000000;

/// The extra data of an Index cell for a color "#rrggbb" ("" or a wrong text: none)
ulong ruleColorBits(const(char)[] color) pure nothrow @nogc @safe
{
    if (color.length != 7 || color[0] != '#')
        return 0;
    ulong rgb = 0;
    foreach (c; color[1 .. $])
    {
        uint digit;
        if (c >= '0' && c <= '9')
            digit = c - '0';
        else if (c >= 'a' && c <= 'f')
            digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            digit = c - 'A' + 10;
        else
            return 0;
        rgb = rgb * 16 + digit;
    }
    return ruleColorFlag | rgb;
}

LogLevel levelOf(ulong bits) pure nothrow @nogc @safe
{
    return cast(LogLevel)(bits & levelMask);
}

@("levelOf: the level is the low bits")
unittest
{
    assert(levelOf(LogLevel.Warn | foundMark | anchoredMark) == LogLevel.Warn);
}

@("ruleColorBits: a color of a rule as the bits of the Index cell, a wrong one is none")
unittest
{
    assert(ruleColorBits("#ff8000") == (ruleColorFlag | 0xFF8000));
    assert(ruleColorBits("#FF8000") == ruleColorBits("#ff8000"));
    assert(ruleColorBits("") == 0 && ruleColorBits("ff8000") == 0 && ruleColorBits("#ff80zz") == 0);
}
