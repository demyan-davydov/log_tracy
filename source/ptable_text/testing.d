//! What the tests of the text package share: a measurer with fixed numbers and one whose fonts have a line of their own, and the text column
//! of a test (`TestText`, a `TextCell` with the paddings of the defaults). Only in a unit test build.
module ptable_text.testing;

version (unittest)
{
    import ptable.layout : ColumnDef;
    import ptable.column : TableColumn;
    import ptable.ports : FontId;
    import ptable_text.columnstyle : ColumnStyle;
    import ptable_text.measurer : FontMetrics, TextMeasurer;
    import ptable_text.textcell : TextCell;

    /// Every glyph 10 dips wide, a line `line` high (14), the ascent 3 less than the line, never wraps by itself
    final class FakeMeasurer : TextMeasurer
    {
        double line = 14;
        int metricReads; /// how many times the metrics were asked

        FontMetrics metrics(FontId font)
        {
            ++metricReads;
            return FontMetrics(line - 3, 3, line);
        }

        double width(FontId font, const(wchar)[] text) { return text.length * 10.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    /// A measurer whose fonts have a line of their own: the font number is the line, the ascent three less
    final class Sized : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(font - 3, 3, font); }
        double width(FontId font, const(wchar)[] text) { return text.length * 10.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    /// A column of plain text for the tests: font 0 everywhere, the metrics read when it is made (`lookChanged` reads them again)
    class TestText : TextCell
    {
        /// `measurer` null: one of fixed numbers (`FakeMeasurer`)
        this(ColumnDef def, TextMeasurer measurer = null)
        {
            super(def, measurer !is null ? measurer : new FakeMeasurer);
            lookChanged();
        }
    }

    /// A `TestText` of each of `defs`, in their order, measuring by `measurer` (null: `FakeMeasurer`), each in the style of the same place in
    /// `styles` (none: the default)
    TableColumn[] withText(const(ColumnDef)[] defs, TextMeasurer measurer = null, const(ColumnStyle)[] styles = null)
    {
        auto columns = new TableColumn[defs.length];
        foreach (i, ref def; defs)
        {
            auto column = new TestText(def, measurer);
            if (i < styles.length)
                column.style = styles[i];
            column.lookChanged();
            columns[i] = column;
        }
        return columns;
    }

    /// The style of a column of a test (a `TestText`)
    ref ColumnStyle styleOf(TableColumn column)
    {
        return (cast(TestText) column).style;
    }
}
