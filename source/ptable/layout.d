//! The columns of a table that can be shared: widths, visibility, pinning and the horizontal
//! scroll, kept by column id in an object of its own (`ColumnLayout`), and the placement of the
//! columns in a viewport from it (`placeColumns`). Tables that are given the same object show
//! the same widths and scroll; two objects can be linked (`linkLayouts`) to follow each other.
//! Pure: no Sciter, no log. See docs/stories/painted-table.md.
module ptable.layout;


import ptable.column : TableColumn;
import ptable.listeners : Listeners;

/// Where a column stands when the table scrolls horizontally
enum Pin : ubyte
{
    none, /// scrolls
    left, /// stays at the left edge
    right, /// stays at the right edge
}

/// What a table knows of a column when it lays them out
struct ColumnDef
{
    string id; /// stable: the layout is kept by it
    string title;
    bool flex; /// takes the room the other columns leave (the Payload), never less than its width in the layout
    bool selectable = true; /// its text can be selected and copied (a column of marks is not)
    bool clickable; /// its cells are for a click (the pointer over them is a hand); the host reacts to the click, the table picks nothing
    double minWidth = 24; /// the least width of the column, whatever the layout says (how its cells look is its column's style)
    /// A column of the title `title` and the least width `minWidth`
    this(string id, string title, double minWidth = 24, bool flex = false, bool selectable = true)
    {
        this.id = id;
        this.title = title;
        this.flex = flex;
        this.selectable = selectable;
        this.minWidth = minWidth;
    }
}

/// What changed in a layout
struct LayoutChange
{
    enum Kind : ubyte
    {
        width,
        visibility,
        pin,
        scroll,
    }

    Kind kind;
    string id; /// the column, empty for the scroll
}

alias LayoutListener = void delegate(const LayoutChange change);

/// The widths, visibility and pinning of columns by id, and the horizontal scroll
final class ColumnLayout
{
    private struct State
    {
        double width = 0; // set by the user (a dragged border)
        double fit = 0; // what the texts seen need: it only grows, and `resetFit` forgets it
        bool visible = true;
        Pin pin;
    }

    private State[string] _columns;
    private double _scrollX = 0;
    private Listeners!LayoutChange _listeners;
    private uint _revision;

    /// Counts every change: a table that painted at a revision knows it is stale
    uint revision() const pure nothrow @nogc @safe
    {
        return _revision;
    }

    /// The width of the column `id`: what the user set or what the texts need, the larger; 0 if nobody set it
    double width(string id) const pure nothrow @safe
    {
        if (auto state = id in _columns)
            return state.width > state.fit ? state.width : state.fit;
        return 0;
    }

    /// What the user set, 0 if nothing
    double explicitWidth(string id) const pure nothrow @safe
    {
        if (auto state = id in _columns)
            return state.width;
        return 0;
    }

    /// What the texts seen need, 0 if nothing
    double fitWidth(string id) const pure nothrow @safe
    {
        if (auto state = id in _columns)
            return state.fit;
        return 0;
    }

    private State* state(string id)
    {
        if (auto found = id in _columns)
            return found;
        _columns[id] = State.init;
        return id in _columns;
    }

    private void changed(LayoutChange.Kind kind, string id)
    {
        _revision++;
        _listeners.tell(LayoutChange(kind, id));
    }

    /// Sets the width exactly (the user dragged a border): what the texts needed is forgotten, the next longer text
    /// grows the column again
    void setWidth(string id, double width)
    {
        auto s = state(id);
        if (s.width == width && s.fit == 0)
            return;
        s.width = width;
        s.fit = 0;
        changed(LayoutChange.Kind.width, id);
    }

    /// Sets what the texts seen need (the same for a layout that follows another)
    void setFit(string id, double fit)
    {
        auto s = state(id);
        if (s.fit == fit)
            return;
        const before = width(id);
        s.fit = fit;
        if (width(id) != before)
            changed(LayoutChange.Kind.width, id);
    }

    /// The texts are to be measured again (the fonts changed): what they needed is forgotten, what the user set stays
    void resetFit()
    {
        foreach (id; ids())
            setFit(id, 0);
    }

    /// Makes the column at least `width` wide (a text longer than the column was seen): the width
    /// only grows. True if it did.
    bool grow(string id, double width)
    {
        if (!(width > this.width(id)))
            return false;
        setFit(id, width);
        return true;
    }

    bool visible(string id) const pure nothrow @safe
    {
        if (auto s = id in _columns)
            return s.visible;
        return true;
    }

    void setVisible(string id, bool visible)
    {
        auto s = state(id);
        if (s.visible == visible)
            return;
        s.visible = visible;
        changed(LayoutChange.Kind.visibility, id);
    }

    Pin pin(string id) const pure nothrow @safe
    {
        if (auto s = id in _columns)
            return s.pin;
        return Pin.none;
    }

    void setPin(string id, Pin pin)
    {
        auto s = state(id);
        if (s.pin == pin)
            return;
        s.pin = pin;
        changed(LayoutChange.Kind.pin, id);
    }

    double scrollX() const pure nothrow @nogc @safe
    {
        return _scrollX;
    }

    /// Sets the scroll; a table clamps it to what its columns allow when it places them
    void setScrollX(double scrollX)
    {
        if (_scrollX == scrollX)
            return;
        _scrollX = scrollX;
        changed(LayoutChange.Kind.scroll, "");
    }

    /// Calls `listener` after every change; the handle is for `unsubscribe`
    size_t subscribe(LayoutListener listener)
    {
        return _listeners.add(listener);
    }

    void unsubscribe(size_t handle)
    {
        _listeners.remove(handle);
    }

    // The ids the layout holds a state of
    private string[] ids() const
    {
        return _columns.keys;
    }
}

/// What `linkLayouts` keeps the same in two layouts (flags, or-ed)
enum Linked : uint
{
    widths = 1,
    visibility = 2,
    pinning = 4,
    scroll = 8,
    all = 15,
}

/// Makes `b` follow `a` and `a` follow `b` in what `what` says, for the columns both know. Returns a
/// function that cuts the link.
void delegate() linkLayouts(ColumnLayout a, ColumnLayout b, uint what = Linked.all)
{
    bool copying; // a change made by the link is not copied back

    void copyWidth(ColumnLayout from, ColumnLayout to, string id)
    {
        to.setWidth(id, from.explicitWidth(id));
        to.setFit(id, from.fitWidth(id));
    }

    void copy(ColumnLayout from, ColumnLayout to, LayoutChange change)
    {
        if (copying)
            return;
        copying = true;
        scope (exit)
            copying = false;
        final switch (change.kind)
        {
        case LayoutChange.Kind.width:
            if (what & Linked.widths)
                copyWidth(from, to, change.id);
            break;
        case LayoutChange.Kind.visibility:
            if (what & Linked.visibility)
                to.setVisible(change.id, from.visible(change.id));
            break;
        case LayoutChange.Kind.pin:
            if (what & Linked.pinning)
                to.setPin(change.id, from.pin(change.id));
            break;
        case LayoutChange.Kind.scroll:
            if (what & Linked.scroll)
                to.setScrollX(from.scrollX);
            break;
        }
    }

    // `b` starts as `a` is
    copying = true;
    foreach (id; a.ids())
    {
        if (what & Linked.widths)
            copyWidth(a, b, id);
        if (what & Linked.visibility)
            b.setVisible(id, a.visible(id));
        if (what & Linked.pinning)
            b.setPin(id, a.pin(id));
    }
    if (what & Linked.scroll)
        b.setScrollX(a.scrollX);
    copying = false;
    const ha = a.subscribe((const LayoutChange c) { copy(a, b, c); });
    const hb = b.subscribe((const LayoutChange c) { copy(b, a, c); });
    return () { a.unsubscribe(ha); b.unsubscribe(hb); };
}

/// Where a column stands in the viewport
struct Placement
{
    string id;
    double x = 0; /// from the left edge of the viewport
    double width = 0;
    Pin area; /// the area it is in (none: the scrolling middle)
    size_t defIndex; /// the place of the column among the definitions it was placed from: no lookup by `id` per cell
}

/// All the columns of a viewport
struct Placements
{
    Placement[] columns;
    double leftWidth = 0, rightWidth = 0; /// the pinned areas
    double middleWidth = 0; /// the viewport left to the scrolling columns
    double contentWidth = 0; /// what the scrolling columns need
    double scrollX = 0; /// the scroll after the clamp
    double maxScrollX = 0;
}

/// The layout data of a column: the definition itself, or the one a column object holds
ref const(ColumnDef) defOf(return ref const ColumnDef def) pure nothrow @nogc @safe
{
    return def;
}

/// ditto
ref const(ColumnDef) defOf(const TableColumn column) pure nothrow @nogc @safe
{
    return column.def;
}

/// Places the visible `columns` (in their order) in a viewport of `viewportWidth`: the pinned ones at
/// the edges, the others between them scrolled by the layout's scroll, a flex column filling the
/// room that is left.
Placements placeColumns(C)(const(C)[] columns, const ColumnLayout layout, double viewportWidth, double originX = 0)
{
    import std.algorithm.comparison : max, min;

    struct Item
    {
        const(ColumnDef)* def;
        double width;
        size_t index;
    }

    Item[] left, middle, right;
    foreach (index, ref column; columns)
    {
        const def = &defOf(column);
        if (!layout.visible(def.id))
            continue;
        auto item = Item(def, max(layout.width(def.id), def.minWidth), index);
        // a flex column scrolls with the middle: it takes what the others leave, which a pinned one could not
        final switch (def.flex ? Pin.none : layout.pin(def.id))
        {
        case Pin.left: left ~= item; break;
        case Pin.right: right ~= item; break;
        case Pin.none: middle ~= item; break;
        }
    }
    double sum(Item[] items)
    {
        double total = 0;
        foreach (i; items)
            total += i.width;
        return total;
    }

    Placements result;
    result.leftWidth = sum(left);
    result.rightWidth = sum(right);
    result.middleWidth = max(0.0, viewportWidth - result.leftWidth - result.rightWidth);
    // the flex column takes what the others of the middle leave
    double fixedMiddle = 0;
    foreach (i; middle)
        if (!i.def.flex)
            fixedMiddle += i.width;
    foreach (ref i; middle)
        if (i.def.flex)
            i.width = max(i.width, result.middleWidth - fixedMiddle);
    result.contentWidth = sum(middle);
    result.maxScrollX = max(0.0, result.contentWidth - result.middleWidth);
    result.scrollX = max(0.0, min(layout.scrollX, result.maxScrollX));

    double x = originX;
    foreach (i; left)
    {
        result.columns ~= Placement(i.def.id, x, i.width, Pin.left, i.index);
        x += i.width;
    }
    x = originX + result.leftWidth - result.scrollX;
    foreach (i; middle)
    {
        result.columns ~= Placement(i.def.id, x, i.width, Pin.none, i.index);
        x += i.width;
    }
    x = originX + viewportWidth - result.rightWidth;
    foreach (i; right)
    {
        result.columns ~= Placement(i.def.id, x, i.width, Pin.right, i.index);
        x += i.width;
    }
    return result;
}

version (unittest)
{
    private LayoutChange[] changesOf(ColumnLayout layout, void delegate() act)
    {
        LayoutChange[] seen;
        const handle = layout.subscribe((const LayoutChange c) { seen ~= c; });
        act();
        layout.unsubscribe(handle);
        return seen;
    }
}

@("ColumnLayout: a width is exact when set and only grows when grown")
unittest
{
    auto layout = new ColumnLayout;
    assert(layout.width("a") == 0, "nobody set it");
    layout.setWidth("a", 50);
    assert(layout.width("a") == 50);
    assert(!layout.grow("a", 40), "a narrower text does not shrink it");
    assert(layout.width("a") == 50);
    assert(layout.grow("a", 70) && layout.width("a") == 70);
    layout.setWidth("a", 30);
    assert(layout.width("a") == 30, "the user may shrink it");
}

@("ColumnLayout: what the texts need is forgotten by resetFit, what the user set is not; a drag forgets the texts' need")
unittest
{
    auto layout = new ColumnLayout;
    layout.setWidth("a", 50);
    layout.grow("a", 70);
    layout.grow("b", 30);
    assert(layout.explicitWidth("a") == 50 && layout.fitWidth("a") == 70 && layout.width("a") == 70);
    LayoutChange[] seen;
    layout.subscribe((const LayoutChange c) { seen ~= c; });
    layout.resetFit();
    assert(layout.width("a") == 50 && layout.width("b") == 0, "the font got smaller: the columns can too");
    assert(seen.length == 2, "each column that changed is told");
    layout.grow("a", 80);
    layout.setWidth("a", 60);
    assert(layout.width("a") == 60 && layout.fitWidth("a") == 0);
}

@("linkLayouts: the widths the texts need follow too, and so does their reset")
unittest
{
    auto a = new ColumnLayout, b = new ColumnLayout;
    linkLayouts(a, b);
    a.grow("x", 90);
    assert(b.width("x") == 90 && b.explicitWidth("x") == 0, "the need is copied as a need");
    b.resetFit();
    assert(a.width("x") == 0);
}

@("ColumnLayout: visibility, pinning and the scroll, with their defaults")
unittest
{
    auto layout = new ColumnLayout;
    assert(layout.visible("x") && layout.pin("x") == Pin.none && layout.scrollX == 0);
    layout.setVisible("x", false);
    layout.setPin("x", Pin.left);
    layout.setScrollX(12.5);
    assert(!layout.visible("x") && layout.pin("x") == Pin.left && layout.scrollX == 12.5);
    assert(layout.visible("y"), "another column is untouched");
}

@("ColumnLayout: every real change is told to the listeners and counted, the same value is not a change")
unittest
{
    auto layout = new ColumnLayout;
    const before = layout.revision;
    auto seen = changesOf(layout, () {
        layout.setWidth("a", 10);
        layout.setWidth("a", 10); // the same
        layout.setVisible("a", false);
        layout.setPin("a", Pin.right);
        layout.setScrollX(5);
        layout.setScrollX(5); // the same
        layout.grow("a", 5); // not wider
    });
    assert(seen == [LayoutChange(LayoutChange.Kind.width, "a"), LayoutChange(LayoutChange.Kind.visibility, "a"),
        LayoutChange(LayoutChange.Kind.pin, "a"), LayoutChange(LayoutChange.Kind.scroll, "")]);
    assert(layout.revision == before + 4);
    layout.setWidth("b", 1);
    assert(seen.length == 4, "an unsubscribed listener hears nothing");
}

@("linkLayouts: what is linked follows both ways, what is not stays, the link can be cut")
unittest
{
    auto a = new ColumnLayout, b = new ColumnLayout;
    auto cut = linkLayouts(a, b, Linked.widths | Linked.scroll);
    a.setWidth("x", 40);
    assert(b.width("x") == 40);
    b.grow("x", 60);
    assert(a.width("x") == 60, "the other way too");
    a.setScrollX(7);
    assert(b.scrollX == 7);
    a.setVisible("x", false);
    assert(b.visible("x"), "visibility was not linked");
    cut();
    a.setWidth("x", 99);
    assert(b.width("x") == 60, "cut");
}

@("linkLayouts: linked layouts do not loop and start in agreement")
unittest
{
    auto a = new ColumnLayout, b = new ColumnLayout;
    a.setWidth("x", 33);
    a.setScrollX(4);
    linkLayouts(a, b);
    assert(b.width("x") == 33 && b.scrollX == 4, "the second takes the state of the first");
    size_t calls;
    a.subscribe((const LayoutChange) { calls++; });
    b.setPin("x", Pin.left);
    assert(a.pin("x") == Pin.left && calls == 1, "one change, told once");
}

@("placeColumns: columns side by side in their order, a width at least the least one")
unittest
{
    auto layout = new ColumnLayout;
    layout.setWidth("a", 50);
    const columns = [ColumnDef("a", "A"), ColumnDef("b", "B", 30), ColumnDef("c", "C")];
    const p = placeColumns(columns, layout, 400);
    assert(p.columns.length == 3);
    assert(p.columns[0] == Placement("a", 0, 50, Pin.none, 0));
    assert(p.columns[1] == Placement("b", 50, 30, Pin.none, 1), "no width: the least");
    assert(p.columns[2].x == 80 && p.columns[2].width == 24);
    assert(p.maxScrollX == 0 && p.scrollX == 0);
}

@("placeColumns: the flex column fills what is left, never less than its width in the layout")
unittest
{
    auto layout = new ColumnLayout;
    layout.setWidth("a", 100);
    layout.setWidth("p", 150);
    const columns = [ColumnDef("a", "A"), ColumnDef("p", "Payload", 24, true)];
    auto p = placeColumns(columns, layout, 500);
    assert(p.columns[1] == Placement("p", 100, 400, Pin.none, 1), "the rest of 500");
    p = placeColumns(columns, layout, 200);
    assert(p.columns[1].width == 150, "not less than its own");
    assert(p.contentWidth == 250 && p.maxScrollX == 50);
}

@("placeColumns: a hidden column is left out and takes no room")
unittest
{
    auto layout = new ColumnLayout;
    layout.setWidth("a", 50);
    layout.setWidth("b", 60);
    layout.setWidth("c", 70);
    layout.setVisible("b", false);
    const p = placeColumns([ColumnDef("a", "A"), ColumnDef("b", "B"), ColumnDef("c", "C")], layout, 400);
    assert(p.columns.length == 2 && p.columns[1] == Placement("c", 50, 70, Pin.none, 2));
}

@("placeColumns: pinned columns stay at the edges while the middle scrolls, the scroll is clamped")
unittest
{
    auto layout = new ColumnLayout;
    foreach (id; ["l", "a", "b", "r"])
        layout.setWidth(id, 100);
    layout.setPin("l", Pin.left);
    layout.setPin("r", Pin.right);
    const columns = [ColumnDef("l", "L"), ColumnDef("a", "A"), ColumnDef("b", "B"), ColumnDef("r", "R")];
    layout.setScrollX(30);
    auto p = placeColumns(columns, layout, 300); // the middle: 100 px of 200 px of columns
    assert(p.leftWidth == 100 && p.rightWidth == 100 && p.middleWidth == 100);
    assert(p.contentWidth == 200 && p.maxScrollX == 100 && p.scrollX == 30);
    assert(p.columns[0] == Placement("l", 0, 100, Pin.left, 0));
    assert(p.columns[1] == Placement("a", 100 - 30, 100, Pin.none, 1), "scrolled left by 30");
    assert(p.columns[2].x == 170);
    assert(p.columns[3] == Placement("r", 200, 100, Pin.right, 3), "at the right edge");
    layout.setScrollX(1000);
    assert(placeColumns(columns, layout, 300).scrollX == 100, "clamped to the end");
    layout.setScrollX(-5);
    assert(placeColumns(columns, layout, 300).scrollX == 0, "and to the start");
}

@("placeColumns: a flex column is never pinned: it fills the middle")
unittest
{
    auto layout = new ColumnLayout;
    layout.setWidth("a", 50);
    layout.setPin("p", Pin.left);
    const p = placeColumns([ColumnDef("a", "A"), ColumnDef("p", "P", 24, true)], layout, 300);
    assert(p.leftWidth == 0 && p.columns[1] == Placement("p", 50, 250, Pin.none, 1));
}

@("placeColumns: a pinned column order is the table's: pinned left ones keep their order among themselves")
unittest
{
    auto layout = new ColumnLayout;
    foreach (id; ["a", "b", "c"])
        layout.setWidth(id, 10);
    layout.setPin("c", Pin.left);
    layout.setPin("a", Pin.left);
    const p = placeColumns([ColumnDef("a", "A"), ColumnDef("b", "B"), ColumnDef("c", "C")], layout, 100);
    assert(p.columns[0].id == "a" && p.columns[1].id == "c" && p.columns[2].id == "b", "pinned left first, in the table's order");
}

@("placeColumns: the columns stand from the origin, the pinned ones at its edges")
unittest
{
    auto layout = new ColumnLayout;
    foreach (id; ["l", "a", "r"])
        layout.setWidth(id, 50);
    layout.setPin("l", Pin.left);
    layout.setPin("r", Pin.right);
    const columns = [ColumnDef("l", "L"), ColumnDef("a", "A"), ColumnDef("r", "R")];
    const p = placeColumns(columns, layout, 300, 12); // 300 wide, its left edge 12 from the table's
    assert(p.columns[0].x == 12 && p.columns[1].x == 62 && p.columns[2].x == 12 + 300 - 50);
}

@("ColumnDef: a column made without the constructor has the least width of 24 too")
unittest
{
    ColumnDef plain;
    assert(plain.minWidth == 24 && ColumnDef("a", "A").minWidth == 24 && ColumnDef("a", "A", 40).minWidth == 40);
}
