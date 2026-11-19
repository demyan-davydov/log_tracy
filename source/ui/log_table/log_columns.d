//! The columns of the log table that draw more than text: the anchors (the color of the filter rule filling the cell, a circle with the
//! anchor, the faint one over a cell with none, the sign of a refusal), the Index (the color of the filter rule behind the number) and the level (bold by the row's level, a badge for
//! a Fatal one, the color of the level). The log table makes them with the look; the table asks them (docs/stories/painted-table.md).
module ui.log_table.log_columns;

import ptable.column : CellInput, DrawState, TableColumn;
import ptable_text.columnstyle : alignedX, Halign;
import ptable.layout : ColumnDef;
import ptable.ports : Canvas, Color, FontId, Rect;
import ptable_text.measurer : TextMeasurer;
import log_core.log_level : LogLevel;
import log_core.rule_filter : RuleId;
import ui.log_table.marks : marksOf;
import ui.log_table.log_look : LogFont, LogLook, levelFontOf, levelInkOf;
import ui.log_table.text_column : TextColumn;

import std.algorithm.comparison : max;
import std.math : round;

/// The column of the anchor marks: it has no text, a click on it sets or clears the anchor of the message
final class AnchorColumn : TextColumn
{
    private bool delegate() _anchorsFull;
    private bool delegate(RuleId, out Color) _ruleColor;

    /// `anchorsFull` says whether no room is left for another anchor, asked of the document only when it matters (a cell with none under the
    /// mouse or pressed), so what it answers is the truth; null: there is always room. `ruleColor` gives the color of a filter rule; null: none
    this(ColumnDef def, LogLook look, bool delegate() anchorsFull, bool delegate(RuleId, out Color) ruleColor = null, TextMeasurer measurer = null)
    {
        super(def, look, measurer);
        _anchorsFull = anchorsFull;
        _ruleColor = ruleColor;
    }

    // The color of the filter rule the record matches fills the cell; an anchor is in a grey circle (the colors of the theme) in the middle of
    // it; the mouse over a cell with none shows a faint one with no circle, or the sign of a refusal when none can be set, and a big sign while
    // the button is down on it
    override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        fillBack(canvas, state);
        const palette = look.palette;
        const style = this.style.cell;
        const area = state.area;
        const spot = spotOf(cell, area, state.clip);
        auto measurer = this.measurer;
        const marks = marksOf(cell);
        Color rule;
        if (marks.rule.isValid() && _ruleColor !is null && _ruleColor(marks.rule, rule))
            canvas.fillRect(area, rule); // the color of the filter rule the record matches fills the cell, on a selected row too (ux.md 27)
        const anchored = marks.anchored;
        const full = !anchored && (state.hover || state.pressed) && _anchorsFull !is null && _anchorsFull();
        double widthOf(FontId font, const(wchar)[] text) { return measurer !is null ? measurer.width(font, text) : 0; }
        if (full && state.pressed)
        {
            const mark = "⊘"w;
            const body = cellMetrics, sign = measurer !is null ? measurer.metrics(LogFont.sign) : body;
            const middle = spot.baseline + (body.descent - body.ascent) / 2; // of the line of the cell
            const x = alignedAcross(widthOf(LogFont.sign, mark), area, state.clip);
            canvas.drawText(LogFont.sign, mark, x, middle + (sign.ascent - sign.descent) / 2, palette.anchorRefused);
            return;
        }
        if (!anchored && !state.hover)
            return;
        const mark = full ? "⊘"w : "⚓"w;
        const markWidth = widthOf(spot.font, mark);
        const x = alignedAcross(markWidth, area, state.clip);
        if (anchored)
        {
            // the middle of the cell, moved as the mark is when it is kept in view
            const metrics = cellMetrics, moved = x - alignedX(style.halign, area.x, area.w, markWidth, style.left(sidePad), style.right(sidePad));
            canvas.fillCircle(area.x + area.w / 2 + moved, spot.baseline + (metrics.descent - metrics.ascent) / 2, 7.5 * unit, palette.anchorFill,
                palette.anchorLine);
        }
        canvas.drawText(spot.font, mark, x, spot.baseline, anchored ? inkOf(false) : full ? palette.anchorRefused : palette.anchorFaint);
    }
}

/// The Index column: the number of the message, with the color of the filter rule it matches behind it, fading out from the left edge
final class IndexColumn : TextColumn
{
    private bool delegate(RuleId, out Color) _ruleColor;

    /// `ruleColor` gives the color of a filter rule a record matches; null: none is shown
    this(ColumnDef def, LogLook look = null, bool delegate(RuleId, out Color) ruleColor = null, TextMeasurer measurer = null)
    {
        super(def, look, measurer);
        _ruleColor = ruleColor;
    }

    // A gradient from the left edge fading out at about a third of the cell, the background of the row stays (ux.md 27); the bands of the steps
    // are drawn with a falling alpha
    override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        fillBack(canvas, state);
        const rule = marksOf(cell).rule;
        Color color;
        if (rule.isValid() && _ruleColor !is null && _ruleColor(rule, color))
        {
            enum steps = 8;
            const area = state.area;
            const bandWidth = area.w / 3 / steps;
            foreach (i; 0 .. steps)
                canvas.fillRect(Rect(area.x + i * bandWidth, area.y, bandWidth + 0.5, area.h),
                    Color(color.r, color.g, color.b, cast(ubyte)(220 - i * 220 / steps)));
        }
        drawText(canvas, cell, state, inkOf(state.row.selected));
    }
}

/// The level column: the louder levels are bold and in the color of the level, a Fatal one is a badge
final class LevelColumn : TextColumn
{
    this(ColumnDef def, LogLook look, TextMeasurer measurer = null)
    {
        super(def, look, measurer);
    }

    /// The bold font must have the metrics of the column's (the same size): the row's height does not depend on its data
    protected override FontId fontOf(ref const CellInput cell) const
    {
        return levelFontOf(marksOf(cell).level);
    }

    override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        fillBack(canvas, state);
        if (cell.data is null || cell.data.text.length == 0)
            return;
        const palette = look.palette;
        const selected = state.row.selected;
        const level = marksOf(cell).level;
        if (level == LogLevel.Fatal && !selected)
        {
            // the badge grows with the font: its paddings are fractions of the line
            const spot = spotOf(cell, state.area, state.clip);
            const side = round(4 * unit), inset = max(1.0, round(unit));
            const width = measurer !is null ? measurer.width(spot.font, cell.data.text) : 0;
            canvas.fillRect(Rect(spot.x - side, spot.top + inset, round(width) + 2 * side, spot.line - 2 * inset), palette.fatalBg);
        }
        drawText(canvas, cell, state, levelInkOf(palette, level, selected));
    }
}
