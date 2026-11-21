//! ptable_text: the text columns of the log table, a package of its own over `ptable`. It knows the style of a text column
//! (`ColumnStyle`), how a text is broken into lines and where a point or a click falls in it, the measuring of text the host does (`TextMeasurer`),
//! and `TextCell`, the column of text the log's columns are made of. It imports only `ptable` and `std`; `ptable` never imports it
//! (tests/js/ptable-boundary.test.mjs). See docs/stories/painted-table.md.
module ptable_text;

public import ptable_text.columnstyle;
public import ptable_text.measurer;
public import ptable_text.textcell;
public import ptable_text.texthit;
public import ptable_text.wordpick;
public import ptable_text.wrap;
