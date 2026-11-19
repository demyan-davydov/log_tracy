//! What the model of the log table attaches to rows and cells for its columns and painter (the `Extra` of
//! ptable): the marks of a row (`LogMarks`), packed and read here only, and the color of a filter rule as
//! written. The table never reads them; the model writes them and the columns read them. Free of Sciter.
module ui.log_table.marks;

import log_core.log_level : LogLevel;
import log_core.rule_filter : RuleId;
import ptable.column : CellInput;
import ptable.model : Extra;
import ptable.ports : Color;

/// What the log table knows of a record beyond the texts of its cells: its level, whether the search found it, whether it has an
/// anchor, the first filter rule with a color it matches. The row and the cells of the anchor, the Index and the level carry it; the
/// columns and the painter read it by its fields (`marksOf`). How it is packed into the `Extra` of ptable is known here only.
struct LogMarks
{
    LogLevel level;
    bool found; /// the current search found it
    bool anchored; /// it has an anchor
    RuleId rule; /// the first filter rule with a color it matches; not valid: none
}

/// The marks as the extra data of a row or a cell
Extra packMarks(LogMarks marks) pure nothrow @nogc @safe
{
    return Extra((cast(ulong) marks.level & levelBits) | (marks.found ? foundBit : 0) | (marks.anchored ? anchoredBit : 0)
        | (cast(ulong) marks.rule.toInt << ruleShift));
}

// How the marks are packed: the level in the low bits, a bit each for found and anchored, the rule in the high half
private enum ulong levelBits = 0x7, foundBit = 0x8, anchoredBit = 0x10;
private enum ruleShift = 32;

/// The marks the extra data `extra` carries (`packMarks`); none: `LogMarks.init`
LogMarks marksOf(Extra extra) pure nothrow @nogc @safe
{
    const bits = extra.bits;
    return LogMarks(cast(LogLevel)(bits & levelBits), (bits & foundBit) != 0, (bits & anchoredBit) != 0, RuleId(cast(uint)(bits >> ruleShift)));
}

/// The marks of a cell (none: `LogMarks.init`)
LogMarks marksOf(ref const CellInput cell) pure nothrow @nogc @safe
{
    return cell.data !is null ? marksOf(cell.data.extra) : LogMarks.init;
}

@("packMarks, marksOf: the marks come back as they were packed, every field apart; no data is no marks")
unittest
{
    foreach (level; [LogLevel.None, LogLevel.Fatal, LogLevel.Verbose])
        foreach (found; [false, true])
            foreach (anchored; [false, true])
                foreach (rule; [RuleId.init, RuleId(1), RuleId(uint.max)])
                {
                    const marks = LogMarks(level, found, anchored, rule);
                    assert(marksOf(packMarks(marks)) == marks);
                }
    assert(marksOf(Extra.init) == LogMarks.init);
    const CellInput none;
    assert(marksOf(none) == LogMarks.init, "a cell with no data has no marks");
}

/// The color of a filter rule "#rrggbb"; false for an empty or a wrong text
bool ruleColorOf(const(char)[] text, out Color color) pure nothrow @nogc @safe
{
    if (text.length != 7 || text[0] != '#')
        return false;
    uint rgb = 0;
    foreach (c; text[1 .. $])
    {
        uint digit;
        if (c >= '0' && c <= '9')
            digit = c - '0';
        else if (c >= 'a' && c <= 'f')
            digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            digit = c - 'A' + 10;
        else
            return false;
        rgb = rgb * 16 + digit;
    }
    color = Color((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    return true;
}

@("ruleColorOf: a color of a rule as written, a wrong one is none")
unittest
{
    Color color;
    assert(ruleColorOf("#ff8000", color) && color == Color(0xFF, 0x80, 0x00));
    assert(ruleColorOf("#FF8000", color) && color == Color(0xFF, 0x80, 0x00));
    assert(!ruleColorOf("", color) && !ruleColorOf("ff8000", color) && !ruleColorOf("#ff80zz", color));
}
