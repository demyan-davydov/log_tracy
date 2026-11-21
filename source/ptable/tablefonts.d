//! The geometry the painter asks for, with what it leaves to the columns made of them: a header of a height of 0 is as high as the
//! tallest title (`fitHeader`), a group's margin of less than 0 as high as the header. Made again after a change of the look. Pure;
//! the table only asks it.
module ptable.tablefonts;

import ptable.painter : Painter, TableGeometry;


struct TableFonts
{
    TableGeometry geometry;
    private bool _loaded;
    // what the painter left to the fonts (0 or less): then the title and the head of a group stand centered by their own font
    private bool _headerHeightAuto, _groupHeightAuto;

    /// The geometry the painter gives now (a change of the look): the metrics are to be read again
    void restyle(Painter painter)
    {
        geometry = painter.geometry();
        _loaded = false;
    }

    /// The metrics are read
    bool loaded() const
    {
        return _loaded;
    }

    /// Makes what the painter left to the fonts (0 or less): the header waits for its titles (`fitHeader`), a group's margin is as high as
    /// the header
    void load()
    {
        _loaded = true;
        _headerHeightAuto = geometry.headerHeight <= 0;
        _groupHeightAuto = geometry.groupHeight < 0;
        if (_headerHeightAuto)
            geometry.headerHeight = 0; // as high as the tallest title: `fitHeader` makes it so when the columns are read
        if (_groupHeightAuto)
            geometry.groupHeight = geometry.headerHeight; // a margin is a band like the header
    }

    /// The tallest title or group head is `height` high (`TableColumn.measureHeader`): a header the painter left to the fonts is as
    /// high as it, and so is a group's margin plate. True if it grew.
    bool fitHeader(double height)
    {
        if (!_headerHeightAuto || !_loaded)
            return false;
        if (height <= geometry.headerHeight)
            return false;
        geometry.headerHeight = height;
        if (_groupHeightAuto)
            geometry.groupHeight = height;
        return true;
    }
}

version (unittest)
{

    private final class Auto : Painter
    {
        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.headerHeight = 0;
            return g;
        }
    }
}

@("TableFonts: a header left to the fonts waits for its titles")
unittest
{
    TableFonts fonts;
    assert(!fonts.loaded);
    fonts.restyle(new Auto);
    fonts.load();
    assert(fonts.loaded && fonts.geometry.headerHeight == 0, "no title yet");
}

@("TableFonts: a painter's own header numbers stay, and a restyle makes the geometry again")
unittest
{
    TableFonts fonts;
    fonts.restyle(new Painter);
    fonts.load();
    assert(fonts.geometry.headerHeight == 21, "the default of the painter");
    fonts.restyle(new Painter);
    assert(!fonts.loaded, "a restyle: the geometry is to be made again");
}

@("TableFonts: a group margin left to the fonts is as high as the header")
unittest
{
    static final class Groups : Painter
    {
        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.groupHeight = -1;
            g.headerHeight = 0;
            return g;
        }
    }

    TableFonts fonts;
    fonts.restyle(new Groups);
    fonts.load();
    assert(fonts.fitHeader(22) && fonts.geometry.groupHeight == 22, "as high as the header the titles make");

    fonts.restyle(new Painter);
    fonts.load();
    assert(fonts.geometry.groupHeight == 0, "no grouping stays none");
}

@("TableFonts: a header left to the fonts grows to the tallest title; a painter's own numbers stay")
unittest
{
    TableFonts fonts;
    fonts.restyle(new Auto);
    fonts.load();
    assert(fonts.fitHeader(22) && fonts.geometry.headerHeight == 22, "the tallest title");
    assert(!fonts.fitHeader(16) && fonts.geometry.headerHeight == 22, "a shorter one: nothing");
    assert(fonts.fitHeader(36) && fonts.geometry.headerHeight == 36);

    fonts.restyle(new Painter);
    fonts.load();
    assert(!fonts.fitHeader(30 + 2 * 3) && fonts.geometry.headerHeight == 21, "the painter's own header height stays");
}
