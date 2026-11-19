//! The room a table has and how it is divided: its size, the fonts it draws in and the regions (the header, the rows,
//! the footer, the padding) that follow from both. They change together (a resize, a new look) and are made again
//! only when one of them did, so the table asks this unit instead of keeping the three and their staleness itself.
//! Pure. See docs/stories/painted-table.md.
module ptable.tablespace;

import ptable.painter : Painter;
import ptable.regions : Regions, regionsOf;
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
    private bool _stale = true;

    /// The fonts and the geometry the painter asked for (read only: `restyle` and `refresh` change them)
    ref const(TableFonts) fonts() const return nothrow { return _fonts; }

    double width() const nothrow { return _width; }
    double height() const nothrow { return _height; }

    /// The parts of the table's area: the header, the rows, the footer, the padding
    ref const(Regions) regions() const return nothrow { return _regions; }

    /// The size of the table; false if it is the same. `widthChanged` says the width differs (the wrapped rows change their heights)
    bool resize(double newWidth, double newHeight, out bool widthChanged)
    {
        widthChanged = newWidth != _width;
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

    /// Makes the geometry if it was not, and the regions if the size or the geometry changed
    SpaceRefresh refresh()
    {
        SpaceRefresh result;
        if (!_fonts.loaded)
        {
            _fonts.load();
            result.fontsLoaded = true;
        }
        if (_stale)
        {
            _stale = false;
            _regions = regionsOf(_width, _height, _fonts.geometry);
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
