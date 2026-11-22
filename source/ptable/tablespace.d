//! The room a table has and how it is divided: its size, the fonts it draws in and the regions (the header, the rows,
//! the footer, the margins) that follow from both and from the margins left and right of the column host. They change together (a resize,
//! a new look, other margins) and are made again only when one of them did, so the table asks this unit instead of keeping the three and their staleness itself.
//! Pure. See docs/stories/painted-table.md.
module ptable.tablespace;

import ptable.painter : Painter;
import ptable.regions : Regions, SideMargins, regionsOf;
import ptable.tablefonts : TableFonts;

/// What `TableSpace.refresh` made again
struct SpaceRefresh
{
    bool fontsLoaded; /// the metrics of the fonts were read: what depends on them is stale
    bool regionsMade; /// the regions were made again: the places of the columns are stale
}

struct TableSpace
{
    private TableFonts _fonts;
    private double _width = 0, _height = 0;
    private Regions _regions;
    private SideMargins _sides; // the margins left and right the regions were made with
    private bool _stale = true;
    private bool _sized; // given a size by `resize` (a table never drawn has none: not 0)

    /// The fonts and the geometry the painter asked for (read only: `restyle` and `refresh` change them)
    ref const(TableFonts) fonts() const return nothrow { return _fonts; }

    double width() const nothrow { return _width; }
    double height() const nothrow { return _height; }

    /// Whether the table was given a size (`resize`): before it, its width of 0 is no room, only not known yet
    bool sized() const nothrow { return _sized; }

    /// The parts of the table's area: the header, the rows, the footer, the margins
    ref const(Regions) regions() const return nothrow { return _regions; }

    /// The size of the table; false if it is the same. `widthChanged` says the width differs (the wrapped rows change their heights)
    bool resize(double newWidth, double newHeight, out bool widthChanged)
    {
        widthChanged = newWidth != _width;
        _sized = true;
        if (!widthChanged && newHeight == _height)
            return false;
        _width = newWidth;
        _height = newHeight;
        _stale = true;
        return true;
    }

    /// The look changed: the painter's geometry is asked again and the fonts are read again
    void restyle(Painter painter)
    {
        _fonts.restyle(painter);
        _stale = true;
    }

    /// The tallest title or group head is `height` high: the header (and a group's plate) grows to it if the painter left that to the
    /// fonts; true if it did, the regions are made again by `refresh`
    bool fitHeader(double height)
    {
        if (!_fonts.fitHeader(height))
            return false;
        _stale = true;
        return true;
    }

    /// Makes the geometry if it was not, and the regions if the size, the geometry or the margins left and right `sides` (the column
    /// host's) changed
    SpaceRefresh refresh(SideMargins sides = SideMargins.init)
    {
        SpaceRefresh result;
        if (!_fonts.loaded)
        {
            _fonts.load();
            result.fontsLoaded = true;
        }
        if (_stale || sides != _sides)
        {
            _stale = false;
            _sides = sides;
            _regions = regionsOf(_width, _height, _fonts.geometry, sides);
            result.regionsMade = true;
        }
        return result;
    }
}

@("TableSpace: the fonts are read and the regions made once, again only after a resize or a restyle")
unittest
{
    TableSpace space;
    space.restyle(new Painter);
    bool widthChanged;
    assert(space.resize(400, 200, widthChanged) && widthChanged);
    auto first = space.refresh();
    assert(first.fontsLoaded && first.regionsMade);
    assert(space.regions.rows.w == 400 && space.regions.header.h == 21);
    const again = space.refresh();
    assert(!again.fontsLoaded && !again.regionsMade, "nothing changed");
    assert(!space.resize(400, 200, widthChanged) && !widthChanged, "the same size");
    assert(space.resize(400, 300, widthChanged) && !widthChanged, "the height only");
    const afterResize = space.refresh();
    assert(!afterResize.fontsLoaded && afterResize.regionsMade && space.regions.rows.h == 300 - 21);
    space.restyle(new Painter);
    const afterRestyle = space.refresh();
    assert(afterRestyle.fontsLoaded && afterRestyle.regionsMade);
}

@("TableSpace: other margins left and right make the regions again, the same ones do not")
unittest
{
    TableSpace space;
    space.restyle(new Painter);
    bool widthChanged;
    space.resize(400, 200, widthChanged);
    space.refresh();
    const sides = SideMargins(20, 10);
    assert(space.refresh(sides).regionsMade && space.regions.rows.x == 20 && space.regions.rows.w == 370);
    assert(!space.refresh(sides).regionsMade, "the same margins");
    assert(space.refresh().regionsMade && space.regions.rows.w == 400, "none again");
}
