//! What of the look of a table changed, so the table drops only what depends on it: a change of colors is a
//! repaint, a change of fonts or their sizes is a new measure of everything (heights, wraps, widths). The look
//! itself is the host's (ui/look): the core hears only the kind of the change.
module ptable.lookchange;

/// The kinds of a change of the look; or-able
enum LookChange : ubyte
{
    colors = 1, /// only the paint differs: nothing measured is stale
    metrics = 2, /// the fonts, their sizes or the geometry differ: what was measured is stale
}
