//! The measuring of text a text column asks of its host: the metrics of a font, the width of a text, the lines the host wraps itself.
//! The tests give it fakes (`ptable_text.testing`), the application a Sciter implementation.
module ptable_text.measurer;

import ptable.ports : FontId;

/// The vertical metrics of a font, in dips
struct FontMetrics
{
    double ascent = 0, descent = 0, lineHeight = 0;
}

/// Measures text in a font. A text column never measures by itself: wraps, hit tests and the widths
/// come from here.
interface TextMeasurer
{
    FontMetrics metrics(FontId font);

    /// The width of `text` in one line (spaces at its end count)
    double width(FontId font, const(wchar)[] text);

    /// The lines `text` takes in `width` when the measurer wraps it itself (the text engine of the host,
    /// which knows scripts the table's own wrap does not), or -1 if it does not: then the column wraps
    /// by the advances of the glyphs. A measurer that answers is drawn with `Canvas.drawParagraph`.
    int wrappedLines(FontId font, const(wchar)[] text, double width);
}
