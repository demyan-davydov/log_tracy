//! ptable: a table that draws its rows itself, as a package of its own (docs/stories/painted-table.md).
//! It knows nothing of logs, documents or Sciter and imports only `std`: the data comes in through
//! `TableModel`, the columns are shared through `ColumnLayout`, the look is a `Painter`, and the
//! canvas and the clipboard are interfaces (`ports`) the application implements. What a column of
//! text is (its style, its lines, its words, its measuring) is the package `ptable_text`. A test keeps the boundary (tests/js/ptable-boundary.test.mjs): the package can move
//! to a repository of its own as it is.
module ptable;

public import ptable.column;
public import ptable.columnhost;
public import ptable.layout;
public import ptable.listeners;
public import ptable.lookchange;
public import ptable.memory;
public import ptable.model;
public import ptable.painter;
public import ptable.ports;
public import ptable.regions;
public import ptable.rowcache;
public import ptable.scrollbar;
public import ptable.table;
public import ptable.scrollplace;
public import ptable.viewport;
public import ptable.rowlayout;
public import ptable.selection;
