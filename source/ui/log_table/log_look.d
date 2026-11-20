//! The look of the log table apart from who draws it: its fonts (`LogFont`), its colors (`LogPalette`, named by a style through
//! `LogColor`), its spacing (`LogSpacing`) and the look that joins them (`LogLook`), the ink and the font of a level. The painter
//! and the columns of the log read it; the script fills it from the CSS of the themes (resources/log-table-look.js). Free of Sciter.
module ui.log_table.log_look;

import log_core.log_level : LogLevel;
import ptable_text.columnstyle : ColorId, noColor;
import ptable.ports : Color, FontId;
import ui.look : FontSpec, Look, TextLook;

/// The fonts of the table (`FontId`s): the family and the size by role; a host turns them into its fonts
enum LogFont : FontId
{
    body, /// the Payload and the levels: 10pt, the system's font
    aux, /// the other cells: 8pt Courier New
    header, /// the titles: 10pt Courier New
    bodyBold, /// the louder levels
    sign, /// the sign of a refusal pressed on: the body font made big (19pt)
}

/// The fonts by `LogFont`
immutable(FontSpec)[] logFonts = [
    FontSpec("system-ui, 'Segoe UI', sans-serif"w, 10, false, false),
    FontSpec("'Courier New', Courier, monospace"w, 8, false, true),
    FontSpec("'Courier New', Courier, monospace"w, 10, false, true),
    FontSpec("system-ui, 'Segoe UI', sans-serif"w, 10, true, false),
    FontSpec("system-ui, 'Segoe UI', sans-serif"w, 19, false, false),
];

enum Color textInk = Color(0x33, 0x33, 0x33);

/// The text of the log table for the Sciter layer: its fonts and ink
TextLook logTextLook()
{
    return TextLook(logFonts, textInk, LogFont.body);
}

/// The look the log table has by default: the light theme
LogLook defaultLogLook()
{
    return new LogLook(logTextLook());
}

/// The colors, by default those of the light theme (resources/theme-light.css): the script gives the theme's
struct LogPalette
{
    Color ink = Color(0x33, 0x33, 0x33), selectedInk = Color(0, 0, 0); // the text, and the text of a selected row
    Color row = Color(255, 255, 255), stripe = Color(0xf4, 0xf4, 0xf4), selected = Color(0xb0, 0xd2, 0xf8);
    Color found = Color(0xee, 0xe6, 0xd4), foundStripe = Color(0xe7, 0xdf, 0xcd), header = Color(0xff, 0xe4, 0xc4);
    Color border = Color(0xd0, 0xd0, 0xd0), textSelected = Color(0x7f, 0xdc, 0x94);
    Color currentRow = Color(0x3b, 0x82, 0xd6); // the frame of the row the keys move from (--border-row-current)
    Color currentRowInactive = Color(0x8a, 0xa4, 0xc2); // the same while the table has not the focus (--border-row-current-inactive)
    Color fatalBg = Color(0xc2, 0x12, 0x3a), fatalText = Color(255, 255, 255), error = Color(255, 0, 0);
    Color warn = Color(0xff, 0x8c, 0x00), info = Color(0, 0x80, 0), debug_ = Color(0x88, 0x88, 0x88);
    // a group of rows (a day): the ground of its margin, its lines, the plate of its head and the plate's ink
    Color groupBand = Color(255, 255, 255), groupLine = Color(0xd0, 0xd0, 0xd0);
    Color groupPlate = Color(0xff, 0xe4, 0xc4), groupInk = Color(0x33, 0x33, 0x33);
    // the circle of an anchor (--bg-anchor, --anchor-border-color)
    Color anchorFill = Color(0xd6, 0xd6, 0xd6), anchorLine = Color(0xb0, 0xb0, 0xb0);
    Color anchorFaint = Color(0xb0, 0xb0, 0xb0); // the anchor shown over a cell with none (--anchor-faint), no circle
    Color anchorRefused = Color(0xc7, 0x5b, 0x5b); // the sign shown over a cell with none when no anchor can be set (--anchor-refused)
    /// The colors of the search chips, by their place in the query (--match-color-N, `matchColorCount` of them, the chip repeats them).
    /// Not in `LogColor`: a style never names one, the data of a fragment does (its `extra`)
    Color[matchColorCount] match = [
        Color(0xff, 0xb2, 0xb2), Color(0xa4, 0xec, 0xd9), Color(0xff, 0xeb, 0x8c), Color(0xfb, 0xab, 0xd9), Color(0xac, 0xeb, 0xb8),
        Color(0xff, 0xd0, 0xa2), Color(0xa2, 0xde, 0xfa), Color(0xab, 0xc2, 0xff), Color(0xc0, 0xaf, 0xfa), Color(0xe0, 0xb0, 0xf5),
        Color(0xe2, 0xfa, 0x97), Color(0xf2, 0xc7, 0xa8), Color(0xd4, 0xe0, 0xb3), Color(0xb8, 0xdb, 0xe3), Color(0xd2, 0xc5, 0xe6),
        Color(0xea, 0xd6, 0xb7)];
}

/// How many colors the chips of a search have: resources/match-colors.js (`matchColorCount`) says the same, a test compares them
enum size_t matchColorCount = 16;

/// The colors of `LogPalette` a style names (a `ColorId`): 0 is none
enum LogColor : ColorId
{
    none = noColor,
    ink,
    selectedInk,
    row,
    stripe,
    selected,
    found,
    foundStripe,
    header,
    border,
    textSelected,
    currentRow,
    fatalBg,
    fatalText,
    error,
    warn,
    info,
    debug_,
    groupBand,
    groupLine,
    groupPlate,
    groupInk,
}

/// The color a style names by its `id`; `fallback` for none or an id that is not a `LogColor`
Color pick(ref const LogPalette palette, ColorId id, Color fallback)
{
    if (id == noColor || id > LogColor.max)
        return fallback;
    final switch (cast(LogColor) id)
    {
    case LogColor.none: return fallback;
    case LogColor.ink: return palette.ink;
    case LogColor.selectedInk: return palette.selectedInk;
    case LogColor.row: return palette.row;
    case LogColor.stripe: return palette.stripe;
    case LogColor.selected: return palette.selected;
    case LogColor.found: return palette.found;
    case LogColor.foundStripe: return palette.foundStripe;
    case LogColor.header: return palette.header;
    case LogColor.border: return palette.border;
    case LogColor.textSelected: return palette.textSelected;
    case LogColor.currentRow: return palette.currentRow;
    case LogColor.fatalBg: return palette.fatalBg;
    case LogColor.fatalText: return palette.fatalText;
    case LogColor.error: return palette.error;
    case LogColor.warn: return palette.warn;
    case LogColor.info: return palette.info;
    case LogColor.debug_: return palette.debug_;
    case LogColor.groupBand: return palette.groupBand;
    case LogColor.groupLine: return palette.groupLine;
    case LogColor.groupPlate: return palette.groupPlate;
    case LogColor.groupInk: return palette.groupInk;
    }
}

/// The ink of a level: the color of the level, on a selected row too
Color levelInkOf(ref const LogPalette palette, LogLevel level)
{
    final switch (level)
    {
    case LogLevel.Fatal: return palette.fatalText;
    case LogLevel.Error: return palette.error;
    case LogLevel.Warn: return palette.warn;
    case LogLevel.Info: return palette.info;
    case LogLevel.Debug:
    case LogLevel.Verbose: return palette.debug_;
    case LogLevel.None: return palette.ink;
    }
}

/// The font of a level: the louder ones are bold; it is the level of the row, not the name of it, that tells
FontId levelFontOf(LogLevel level)
{
    return level == LogLevel.Fatal || level == LogLevel.Error || level == LogLevel.Warn ? LogFont.bodyBold : LogFont.body;
}

/// The room of the parts of the log table, in dips (the CSS variables of `.log-table`, resources/log-table-look.js): above
/// and under the plate of the heads of a group of rows
struct LogSpacing
{
    double groupPadTop = 6, groupPadBottom = 0;
    double payloadPadLeft = 5.33; /// the room left of the Payload text and of its title (4pt), the other columns have the text column's own 3
    double[string] minWidths; /// the least widths of the columns in dips, by the keys of `ui.log_table.column_widths`, times the scale of the text
    /// The room above the first row and under the last one, always there (none by default)
    double rowsMarginTop = 0, rowsMarginBottom = 0;
    /// The room left and right of the rows: the column host's (`LogTable` gives it), the same for the tables of a document (none by default)
    double rowsMarginLeft = 0, rowsMarginRight = 0;
}

/// The look of the log table: its text, its colors and its spacing
alias LogLook = Look!(LogPalette, LogSpacing);

@("pick: every color a style can name is a color of the palette, none and an unknown id are the fallback")
unittest
{
    import std.traits : EnumMembers;

    LogPalette palette;
    const fallback = Color(1, 2, 3);
    palette.ink = Color(10, 0, 0);
    palette.groupInk = Color(0, 0, 20);
    assert(pick(palette, LogColor.ink, fallback) == Color(10, 0, 0) && pick(palette, LogColor.groupInk, fallback) == Color(0, 0, 20));
    foreach (id; EnumMembers!LogColor)
        if (id != LogColor.none)
            assert(pick(palette, id, fallback) != fallback || id == LogColor.none, "every member is mapped");
    assert(pick(palette, noColor, fallback) == fallback && pick(palette, 999, fallback) == fallback);
}

