//! The look of the log table as the script gives it: a JSON object of CSS colors by the names of the fields of
//! `LogPalette`, a `scale` of the text, whether the Payload is `monospacePayload` and the `spacing` of the parts (`LogSpacing`, in dips). What the object does not say stays as it was; a color that does not parse
//! stays too. Free of Sciter. See docs/stories/painted-table.md.
module ui.log_table.look_json;

import ptable.ports : Color;
import ui.log_table.log_look : LogLook, LogPalette, LogSpacing, bodyFamily, logFonts, matchColorCount, monospaceFamily, monospacePayloadFont,
    textInk,
    LogFont, defaultLogLook;
import ui.look : FontSpec, Look, TextLook;

import std.conv : to;
import std.uni : icmp;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;
import std.traits : FieldNameTuple;

// The named colors of CSS (the whole list of CSS Color 4, `name=rrggbb`): Sciter gives a color of a theme as it is written, so
// `bisque` comes as `bisque` and not as `#ffe4c4`; `transparent` is handled apart
private enum string namedColorList = "aliceblue=f0f8ff antiquewhite=faebd7 aqua=00ffff aquamarine=7fffd4 azure=f0ffff beige=f5f5dc bisque=ffe4c4 black=000000 blanchedalmond=ffebcd blue=0000ff blueviolet=8a2be2 brown=a52a2a burlywood=deb887 cadetblue=5f9ea0 chartreuse=7fff00 chocolate=d2691e coral=ff7f50 cornflowerblue=6495ed cornsilk=fff8dc crimson=dc143c cyan=00ffff darkblue=00008b darkcyan=008b8b darkgoldenrod=b8860b darkgray=a9a9a9 darkgreen=006400 darkgrey=a9a9a9 darkkhaki=bdb76b darkmagenta=8b008b darkolivegreen=556b2f darkorange=ff8c00 darkorchid=9932cc darkred=8b0000 darksalmon=e9967a darkseagreen=8fbc8f darkslateblue=483d8b darkslategray=2f4f4f darkslategrey=2f4f4f darkturquoise=00ced1 darkviolet=9400d3 deeppink=ff1493 deepskyblue=00bfff dimgray=696969 dimgrey=696969 dodgerblue=1e90ff firebrick=b22222 floralwhite=fffaf0 forestgreen=228b22 fuchsia=ff00ff gainsboro=dcdcdc ghostwhite=f8f8ff gold=ffd700 goldenrod=daa520 gray=808080 green=008000 greenyellow=adff2f grey=808080 honeydew=f0fff0 hotpink=ff69b4 indianred=cd5c5c indigo=4b0082 ivory=fffff0 khaki=f0e68c lavender=e6e6fa lavenderblush=fff0f5 lawngreen=7cfc00 lemonchiffon=fffacd lightblue=add8e6 lightcoral=f08080 lightcyan=e0ffff lightgoldenrodyellow=fafad2 lightgray=d3d3d3 lightgreen=90ee90 lightgrey=d3d3d3 lightpink=ffb6c1 lightsalmon=ffa07a lightseagreen=20b2aa lightskyblue=87cefa lightslategray=778899 lightslategrey=778899 lightsteelblue=b0c4de lightyellow=ffffe0 lime=00ff00 limegreen=32cd32 linen=faf0e6 magenta=ff00ff maroon=800000 mediumaquamarine=66cdaa mediumblue=0000cd mediumorchid=ba55d3 mediumpurple=9370db mediumseagreen=3cb371 mediumslateblue=7b68ee mediumspringgreen=00fa9a mediumturquoise=48d1cc mediumvioletred=c71585 midnightblue=191970 mintcream=f5fffa mistyrose=ffe4e1 moccasin=ffe4b5 navajowhite=ffdead navy=000080 oldlace=fdf5e6 olive=808000 olivedrab=6b8e23 orange=ffa500 orangered=ff4500 orchid=da70d6 palegoldenrod=eee8aa palegreen=98fb98 paleturquoise=afeeee palevioletred=db7093 papayawhip=ffefd5 peachpuff=ffdab9 peru=cd853f pink=ffc0cb plum=dda0dd powderblue=b0e0e6 purple=800080 rebeccapurple=663399 red=ff0000 rosybrown=bc8f8f royalblue=4169e1 saddlebrown=8b4513 salmon=fa8072 sandybrown=f4a460 seagreen=2e8b57 seashell=fff5ee sienna=a0522d silver=c0c0c0 skyblue=87ceeb slateblue=6a5acd slategray=708090 slategrey=708090 snow=fffafa springgreen=00ff7f steelblue=4682b4 tan=d2b48c teal=008080 thistle=d8bfd8 tomato=ff6347 turquoise=40e0d0 violet=ee82ee wheat=f5deb3 white=ffffff whitesmoke=f5f5f5 yellow=ffff00 yellowgreen=9acd32";

private bool namedColor(string text, out string hex)
{
    import std.algorithm.iteration : splitter;
    import std.string : indexOf;

    if (icmp(text, "transparent") == 0)
    {
        hex = "#00000000";
        return true;
    }
    foreach (entry; namedColorList.splitter(' '))
    {
        const eq = entry.indexOf('=');
        if (eq > 0 && eq == cast(ptrdiff_t) text.length && icmp(text, entry[0 .. eq]) == 0)
        {
            hex = "#" ~ entry[eq + 1 .. $];
            return true;
        }
    }
    return false;
}

/// A CSS color of the forms `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`, `rgba(r, g, b, a)` and a CSS color name;
/// false for another
bool parseCssColor(string text, out Color color)
{
    import std.algorithm.searching : startsWith, endsWith;
    import std.array : split;

    text = text.strip;
    string named;
    if (namedColor(text, named))
        return parseCssColor(named, color);
    try
    {
        if (text.startsWith('#'))
        {
            auto hex = text[1 .. $];
            ubyte at(size_t i, size_t digits)
            {
                auto part = hex[i * digits .. (i + 1) * digits];
                return cast(ubyte) (digits == 1 ? part.to!ubyte(16) * 17 : part.to!ubyte(16));
            }

            if (hex.length == 3 || hex.length == 4)
                color = Color(at(0, 1), at(1, 1), at(2, 1), hex.length == 4 ? at(3, 1) : 255);
            else if (hex.length == 6 || hex.length == 8)
                color = Color(at(0, 2), at(1, 2), at(2, 2), hex.length == 8 ? at(3, 2) : 255);
            else
                return false;
            return true;
        }
        const open = text.startsWith("rgba(") ? 5 : text.startsWith("rgb(") ? 4 : 0;
        if (open == 0 || !text.endsWith(')'))
            return false;
        auto parts = text[open .. $ - 1].split(',');
        if (parts.length != (open == 5 ? 4 : 3))
            return false;
        ubyte channel(string p) { return cast(ubyte) (p.strip.to!double + 0.5).to!int.clamp255; }
        color = Color(channel(parts[0]), channel(parts[1]), channel(parts[2]), 255);
        if (parts.length == 4)
            color.a = cast(ubyte) (parts[3].strip.to!double * 255 + 0.5).to!int.clamp255;
        return true;
    }
    catch (Exception)
        return false;
}

private int clamp255(int v)
{
    return v < 0 ? 0 : v > 255 ? 255 : v;
}

/// `base` with the colors the JSON object names (a field of `LogPalette` by name), and the text scale it gives (0: none)
LogPalette paletteFromJson(LogPalette base, string json, out double scale)
{
    scale = 0;
    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception)
        return base;
    if (root.type != JSONType.object)
        return base;
    auto result = base;
    static foreach (name; FieldNameTuple!LogPalette)
    {
        static if (is(typeof(__traits(getMember, result, name)) == Color))
        if (auto value = name in root.object)
        {
            Color color;
            if (value.type == JSONType.string && parseCssColor(value.str, color))
                __traits(getMember, result, name) = color;
        }
    }
    if (auto value = "match" in root.object)
    {
        if (value.type == JSONType.array)
            foreach (i, entry; value.array)
            {
                Color color;
                if (i < matchColorCount && entry.type == JSONType.string && parseCssColor(entry.str, color))
                    result.match[i] = color;
            }
    }
    if (auto value = "scale" in root.object)
    {
        if (value.type == JSONType.float_)
            scale = value.floating;
        else if (value.type == JSONType.integer)
            scale = value.integer;
    }
    return result;
}

/// The most room a part of the table takes by the styles (dips): a value past it is a mistake of a style
enum double maxSpacing = 40;

// Whether two spacings are the same: the sizes and the least widths
private bool sameSpacing(const LogSpacing a, const LogSpacing b)
{
    static foreach (name; FieldNameTuple!LogSpacing)
        if (__traits(getMember, a, name) != __traits(getMember, b, name))
            return false;
    return true;
}

// A copy of a spacing that shares nothing with it (the table of the least widths is its own)
private LogSpacing copyOf(const LogSpacing base)
{
    LogSpacing result;
    static foreach (name; FieldNameTuple!LogSpacing)
    {
        static if (is(typeof(__traits(getMember, LogSpacing.init, name)) == double))
            __traits(getMember, result, name) = __traits(getMember, base, name);
        else
            __traits(getMember, result, name) = __traits(getMember, base, name).dup;
    }
    return result;
}

/// `base` with the sizes the JSON object's "spacing" names (a field of `LogSpacing` by name, in dips), each held from 0 to
/// `maxSpacing`; what is not a number stays as it was
LogSpacing spacingFromJson(const LogSpacing base, string json)
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception)
        return copyOf(base);
    if (root.type != JSONType.object)
        return copyOf(base);
    const spacing = "spacing" in root.object;
    if (spacing is null || spacing.type != JSONType.object)
        return copyOf(base);
    auto result = copyOf(base);
    static foreach (name; FieldNameTuple!LogSpacing)
    {
        static if (is(typeof(__traits(getMember, LogSpacing.init, name)) == double))
        if (auto value = name in spacing.object)
        {
            double size = double.nan;
            if (value.type == JSONType.float_)
                size = value.floating;
            else if (value.type == JSONType.integer)
                size = value.integer;
            if (size == size) // a number
                __traits(getMember, result, name) = size < 0 ? 0 : size > maxSpacing ? maxSpacing : size;
        }
    }
    return result;
}

/// The most a least width of a column may be
enum double maxMinWidth = 600;

/// `base` with the least widths the JSON object's "minWidths" names (by the keys of `column_widths`, in dips of the CSS), each times the
/// "scale" of the text the object says (none: 1) and held from 0 to `maxMinWidth`; what is not a number is left out, what the object does
/// not name stays as it was
double[string] minWidthsFromJson(const double[string] base, string json)
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception)
        return base.dup;
    if (root.type != JSONType.object)
        return base.dup;
    auto result = base.dup;
    const widths = "minWidths" in root.object;
    if (widths is null || widths.type != JSONType.object)
        return result;
    double scale = 1;
    if (auto value = "scale" in root.object)
        scale = clampScale(value.type == JSONType.float_ ? value.floating : value.type == JSONType.integer ? cast(double) value.integer : 1);
    foreach (key, value; widths.object)
    {
        double size = double.nan;
        if (value.type == JSONType.float_)
            size = value.floating;
        else if (value.type == JSONType.integer)
            size = value.integer;
        if (size == size && size >= 0)
        {
            const scaled = size * scale;
            result[key] = scaled > maxMinWidth ? maxMinWidth : scaled;
        }
    }
    return result;
}

/// The text of the log table with the sizes of its fonts times `scale` (1: as it is), the Payload in `monospacePayloadFont` if `monospacePayload`
TextLook scaledTextLook(double scale, bool monospacePayload = false)
{
    auto fonts = new FontSpec[logFonts.length];
    foreach (i, spec; logFonts)
    {
        fonts[i] = i == LogFont.payload && monospacePayload ? monospacePayloadFont : spec;
        fonts[i].sizePt = fonts[i].sizePt * scale;
    }
    return TextLook(cast(immutable) fonts, textInk, LogFont.payload);
}

/// The text scale the table accepts: the settings offer 80 to 200 percent, a value far outside is a mistake of the script
enum double minScale = 0.5, maxScale = 4.0;

private double clampScale(double scale)
{
    return scale < minScale ? minScale : scale > maxScale ? maxScale : scale;
}

/// Whether the JSON of the look says the Payload is monospace (`monospacePayload`: true); off if it says nothing of it or not a bool
bool monospacePayloadFromJson(string json)
{
    try
    {
        const root = parseJSON(json);
        if (root.type == JSONType.object)
            if (const value = "monospacePayload" in root.object)
                if (value.type == JSONType.true_ || value.type == JSONType.false_)
                    return value.boolean;
    }
    catch (Exception)
    {
    }
    return false;
}

/// Applies what the script read of the theme to the look of the application: the colors by the names of the palette,
/// the `scale` of the text, whether the Payload is monospace and the `spacing`. The fonts come whole with the scale: the
/// Payload is monospace only if the JSON says so beside it, and a JSON without a scale leaves the fonts as they are (the
/// script sends both, `collectLook`). A change is told only if there is one (a listener hears no change that is none).
void applyLookJson(LogLook look, string json)
{
    auto spacing = spacingFromJson(look.spacing, json);
    spacing.minWidths = minWidthsFromJson(look.spacing.minWidths, json);
    if (!sameSpacing(spacing, look.spacing))
        look.setSpacing(spacing);
    double scale;
    const palette = paletteFromJson(look.palette, json, scale);
    if (scale > 0)
    {
        const text = scaledTextLook(clampScale(scale), monospacePayloadFromJson(json));
        if (text.fonts != look.text.fonts)
            look.setText(text);
    }
    if (palette != look.palette)
        look.setPalette(palette);
}

@("parseCssColor: hex and rgb forms, nothing else")
unittest
{
    Color c;
    assert(parseCssColor("#fff", c) && c == Color(255, 255, 255, 255));
    assert(parseCssColor(" #b0d2f8 ", c) && c == Color(0xb0, 0xd2, 0xf8, 255));
    assert(parseCssColor("#11223380", c) && c == Color(0x11, 0x22, 0x33, 0x80));
    assert(parseCssColor("rgb(1, 2, 3)", c) && c == Color(1, 2, 3, 255));
    assert(parseCssColor("rgba(60, 60, 60, 0.45)", c) && c == Color(60, 60, 60, 115));
    assert(parseCssColor("bisque", c) && c == Color(0xff, 0xe4, 0xc4, 255) && parseCssColor(" White ", c) && c == Color(255, 255, 255, 255));
    assert(parseCssColor("transparent", c) && c.a == 0);
    assert(parseCssColor("LightGray", c) && c == Color(0xd3, 0xd3, 0xd3, 255) && parseCssColor("gold", c) && c == Color(0xff, 0xd7, 0, 255));
    assert(parseCssColor("rebeccapurple", c) && c == Color(0x66, 0x33, 0x99, 255) && parseCssColor("yellowgreen", c) && c == Color(0x9a, 0xcd, 0x32, 255));
    assert(!parseCssColor("notacolor", c) && !parseCssColor("gol", c) && !parseCssColor("#12", c) && !parseCssColor("rgb(1,2)", c) && !parseCssColor("", c));
}

@("paletteFromJson: the named colors change, the others and the wrong ones stay; the scale comes apart")
unittest
{
    const base = LogPalette.init;
    double scale;
    const changed = paletteFromJson(base, `{"row": "#000000", "stripe": "nonsense", "warn": "rgb(1,2,3)", "scale": 1.5}`, scale);
    assert(changed.row == Color(0, 0, 0) && changed.stripe == base.stripe && changed.warn == Color(1, 2, 3));
    assert(scale == 1.5);
    assert(paletteFromJson(base, "not json", scale) == base && scale == 0);
    paletteFromJson(base, `{"scale": 2}`, scale);
    assert(scale == 2);
}

@("scaledTextLook: every font is as large as its size times the scale")
unittest
{
    const look = scaledTextLook(1.25);
    assert(look.fonts.length == logFonts.length && look.fonts[LogFont.payload].sizePt == 12.5 && look.fonts[LogFont.level].sizePt == 10);
    assert(look.fonts[LogFont.level].family == logFonts[LogFont.level].family);
}

@("scaledTextLook: the Payload is in the body font, or in the monospace one of the levels at 10pt, scaled as the others")
unittest
{
    const plain = scaledTextLook(1);
    assert(plain.fonts[LogFont.payload].family == bodyFamily && !plain.fonts[LogFont.payload].monospace);
    const mono = scaledTextLook(1.25, true);
    assert(mono.fonts[LogFont.payload].family == mono.fonts[LogFont.level].family && mono.fonts[LogFont.payload].monospace);
    assert(mono.fonts[LogFont.payload].sizePt == 12.5 && !mono.fonts[LogFont.payload].bold);
    assert(mono.fonts[LogFont.level] == scaledTextLook(1.25).fonts[LogFont.level], "the levels are as they were");
}

@("logFonts: the levels are always monospace, in a family of their own and the Payload's, the louder ones bold")
unittest
{
    assert(logFonts[LogFont.level].monospace && logFonts[LogFont.levelBold].monospace && logFonts[LogFont.levelBold].bold);
    assert(logFonts[LogFont.level].family == logFonts[LogFont.levelBold].family && logFonts[LogFont.level].family != monospaceFamily);
    assert(logFonts[LogFont.level].sizePt == logFonts[LogFont.aux].sizePt && logFonts[LogFont.levelBold].sizePt == logFonts[LogFont.aux].sizePt,
        "as large as the other columns, the bold one too: it has the metrics of the column's");
}

@("applyLookJson: the fonts come with the scale, the monospace Payload with them (off when not said); no scale, the fonts stay")
unittest
{
    import ptable.lookchange : LookChange;

    auto look = defaultLogLook();
    LookChange[] seen;
    look.subscribe((const LookChange c) { seen ~= c; });
    applyLookJson(look, `{"scale": 1.5, "monospacePayload": true}`);
    assert(seen == [LookChange.metrics] && look.text.fonts[LogFont.payload].monospace);
    assert(look.text.fonts[LogFont.payload].sizePt == 15 && look.text.fonts[LogFont.level].sizePt == 12);
    applyLookJson(look, `{"scale": 1.5, "monospacePayload": true}`);
    applyLookJson(look, `{"monospacePayload": false}`);
    assert(seen.length == 1 && look.text.fonts[LogFont.payload].monospace, "the same: nothing; no scale: the fonts stay");
    applyLookJson(look, `{"scale": 1.5}`);
    assert(seen.length == 2 && !look.text.fonts[LogFont.payload].monospace, "not said: off");
    applyLookJson(look, `{"scale": 1.5, "monospacePayload": 1}`);
    assert(seen.length == 2, "a value not a bool is off");
}

@("paletteFromJson: the colors of the chips come as an array, a wrong one or a missing one keeps the color it had")
unittest
{
    double scale;
    const base = LogPalette.init;
    const changed = paletteFromJson(base, `{"match": ["#010203", "nonsense", 5, "#0a0b0c"]}`, scale);
    assert(changed.match[0] == Color(1, 2, 3) && changed.match[3] == Color(0xa, 0xb, 0xc));
    assert(changed.match[1] == base.match[1] && changed.match[2] == base.match[2], "a wrong entry stays");
    assert(changed.match[4 .. $] == base.match[4 .. $], "a short array leaves the rest");
    string longer = `{"match": [`;
    foreach (i; 0 .. matchColorCount + 3)
        longer ~= `"#000001",`;
    const wide = paletteFromJson(base, longer ~ `"#000001"]}`, scale);
    assert(wide.match[matchColorCount - 1] == Color(0, 0, 1), "what is past the count is dropped");
    assert(paletteFromJson(base, `{"match": "#000000"}`, scale) == base, "not an array");
}

@("paletteFromJson: the ink and the colors of the levels pass the same way")
unittest
{
    double scale;
    const changed = paletteFromJson(LogPalette.init, `{"ink": "#d4d4d4", "selectedInk": "#fff", "error": "#ff4d4d", "info": "#60c060", "debug_": "#888", "fatalBg": "#b3173f", "fatalText": "#fff", "warn": "#ffaa00"}`, scale);
    assert(changed.ink == Color(0xd4, 0xd4, 0xd4) && changed.selectedInk == Color(255, 255, 255));
    assert(changed.error == Color(0xff, 0x4d, 0x4d) && changed.info == Color(0x60, 0xc0, 0x60) && changed.warn == Color(0xff, 0xaa, 0));
    assert(changed.debug_ == Color(0x88, 0x88, 0x88) && changed.fatalBg == Color(0xb3, 0x17, 0x3f) && changed.fatalText == Color(255, 255, 255));
}

@("applyLookJson: the listeners hear what changed and nothing when nothing did, a wrong text changes nothing")
unittest
{
    import ptable.lookchange : LookChange;
    import ui.log_table.log_look : defaultLogLook;

    auto look = defaultLogLook();
    LookChange[] seen;
    look.subscribe((const LookChange c) { seen ~= c; });
    applyLookJson(look, `{"row": "#000000"}`);
    assert(seen == [LookChange.colors] && look.palette.row == Color(0, 0, 0));
    applyLookJson(look, `{"row": "#000000"}`);
    assert(seen.length == 1, "the same color: no change");
    applyLookJson(look, `{"scale": 1.5}`);
    assert(seen == [LookChange.colors, LookChange.metrics] && look.text.fonts[LogFont.payload].sizePt == 15);
    applyLookJson(look, `{"scale": 1.5}`);
    applyLookJson(look, "not json");
    assert(seen.length == 2, "the same size and a wrong text: nothing");
}

@("applyLookJson: a text scale far outside what the settings offer is held to the limits")
unittest
{
    import ui.log_table.log_look : defaultLogLook;

    import ui.log_table.log_look : defaultLogLook;

    auto look = defaultLogLook();
    applyLookJson(look, `{"scale": 100000}`);
    assert(look.text.fonts[LogFont.payload].sizePt == 10 * maxScale);
    applyLookJson(look, `{"scale": 0.0001}`);
    assert(look.text.fonts[LogFont.payload].sizePt == 10 * minScale);
}

@("applyLookJson: the spacing of the groups changes the metrics once, the same one nothing; a pad is held from 0 to 40")
unittest
{
    import ptable.lookchange : LookChange;
    import ui.log_table.log_look : defaultLogLook;

    auto look = defaultLogLook();
    LookChange[] seen;
    look.subscribe((const LookChange c) { seen ~= c; });
    applyLookJson(look, `{"spacing": {"groupPadTop": 10, "groupPadBottom": 2.5}}`);
    assert(seen == [LookChange.metrics] && look.spacing.groupPadTop == 10 && look.spacing.groupPadBottom == 2.5);
    applyLookJson(look, `{"spacing": {"groupPadTop": 10}}`);
    assert(seen.length == 1, "the same: nothing");
    applyLookJson(look, `{"spacing": {"groupPadTop": 500, "groupPadBottom": -3}}`);
    assert(look.spacing.groupPadTop == 40 && look.spacing.groupPadBottom == 0, "held to the limits");
    applyLookJson(look, `{"spacing": {"groupPadTop": "a lot"}}`);
    assert(look.spacing.groupPadTop == 40, "no number: as it was");
    applyLookJson(look, `{"spacing": {"rowsMarginTop": 2, "rowsMarginBottom": 6}}`);
    assert(look.spacing.rowsMarginTop == 2 && look.spacing.rowsMarginBottom == 6, "the margins around the rows");
}

@("minWidthsFromJson: the least widths by their keys, times the scale; a wrong one is left out, the ones not named stay")
unittest
{
    double[string] base = ["anchor": 24.0, "dlt-ecu": 50.0];
    const changed = minWidthsFromJson(base, `{"scale": 1.5, "minWidths": {"anchor": 30, "dlt-time": 40.5, "bad": "x", "negative": -1}}`);
    assert(changed["anchor"] == 45 && changed["dlt-time"] == 60.75, "in dips, times the scale of the text");
    assert("bad" !in changed && "negative" !in changed, "no number, or below 0");
    assert(changed["dlt-ecu"] == 50, "not named: it stays");
    assert(minWidthsFromJson(base, `{"minWidths": {"anchor": 30}}`)["anchor"] == 30, "no scale: as it is");
    assert(minWidthsFromJson(base, "not json") == base && minWidthsFromJson(base, `{"minWidths": 5}`) == base);
}

@("applyLookJson: the least widths of the columns come into the spacing of the look")
unittest
{
    auto look = defaultLogLook();
    applyLookJson(look, `{"scale": 2, "minWidths": {"default": 10, "payload": 20}}`);
    assert(look.spacing.minWidths["default"] == 20 && look.spacing.minWidths["payload"] == 40);
}
