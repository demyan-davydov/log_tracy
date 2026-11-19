//! What the layers of the painted table share about how they look: a font as a host needs to make it
//! (`FontSpec`), the text of a table (`TextLook`: its fonts, ink and the font the line height is read
//! from), and the look of a table (`Look`: its text, the colors and the spacing of the layer that paints it, and who
//! hears them change). Free of Sciter and of the log: the Sciter layer (ui/sciter_table/host) reads it, the log layer
//! (ui/log_table/log_look) fills it, the glue (ui/painted_table) joins them.
module ui.look;

import ptable.listeners : Listeners;
import ptable.lookchange : LookChange;
import ptable.ports : Color, FontId;

/// What a host needs to make a font
struct FontSpec
{
    wstring family;
    double sizePt;
    bool bold;
    bool monospace; /// every glyph of it is as wide as "0": a width is the count of units times it
}

/// The text of a table: the fonts by `FontId`, the ink the text is measured in and the font the line height is read from
struct TextLook
{
    immutable(FontSpec)[] fonts;
    Color ink;
    FontId lineFont;
}

/// A layer whose look has no spacing of its own
struct NoSpacing
{
}

/// The look of a table: its text, the palette of the layer that paints it (a struct of colors the
/// layer defines) and its spacing (a struct of sizes in dips, the room of its parts), and the listeners that hear it
/// change. One source of truth: the painters, the scroll bar and the text cache read it, and a change tells them what
/// kind it was (`LookChange`).
final class Look(Palette, Spacing = NoSpacing)
{
    private TextLook _text;
    private Palette _palette;
    private Spacing _spacing;
    private Listeners!LookChange _listeners;

    this(TextLook text, Palette palette = Palette.init)
    {
        _text = text;
        _palette = palette;
    }

    ref const(TextLook) text() const { return _text; }
    ref const(Palette) palette() const { return _palette; }
    ref const(Spacing) spacing() const { return _spacing; }

    /// The colors changed: the listeners are told `colors`
    void setPalette(Palette palette)
    {
        _palette = palette;
        _listeners.tell(LookChange.colors);
    }

    /// The sizes changed: the listeners are told `metrics` (the rows are measured again)
    void setSpacing(Spacing spacing)
    {
        _spacing = spacing;
        _listeners.tell(LookChange.metrics);
    }

    /// The fonts changed: the listeners are told `metrics`
    void setText(TextLook text)
    {
        _text = text;
        _listeners.tell(LookChange.metrics);
    }

    /// Calls `listener` after every change, in the order of the subscriptions; the handle is for `unsubscribe`
    size_t subscribe(void delegate(const LookChange) listener)
    {
        return _listeners.add(listener);
    }

    void unsubscribe(size_t handle)
    {
        _listeners.remove(handle);
    }
}

@("Look: the listeners hear the kind of the change in the order they came")
unittest
{
    struct Colors { int ink = 1; }

    auto look = new Look!Colors(TextLook(null, Color(1, 2, 3), 0));
    LookChange[] seen;
    int[] order;
    const first = look.subscribe((const LookChange c) { seen ~= c; order ~= 1; });
    look.subscribe((const LookChange c) { order ~= 2; });
    look.setPalette(Colors(5));
    assert(look.palette.ink == 5 && seen == [LookChange.colors] && order == [1, 2]);
    look.setText(TextLook(null, Color(9, 9, 9), 0));
    assert(look.text.ink.r == 9 && seen == [LookChange.colors, LookChange.metrics]);
    look.unsubscribe(first);
    look.setPalette(Colors(6));
    assert(seen.length == 2);
}

@("Look: the spacing of a layer is its own; a change of it is a change of the metrics, the rows are measured again")
unittest
{
    struct Colors { int ink = 1; }
    struct Room { double pad = 6; }

    auto look = new Look!(Colors, Room)(TextLook(null, Color(1, 2, 3), 0));
    assert(look.spacing.pad == 6);
    LookChange[] seen;
    look.subscribe((const LookChange c) { seen ~= c; });
    look.setSpacing(Room(4));
    assert(look.spacing.pad == 4 && seen == [LookChange.metrics]);
}
