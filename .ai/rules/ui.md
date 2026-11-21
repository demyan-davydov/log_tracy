# UI Code Rules

## Scope

Applies to everything the user sees: script, CSS, markup, and backend code on the path of a
table row. UX decisions are in `.ai/rules/ux.md`, visual standards (spacing, radii,
typography) in `docs/ui-guidelines.md`.

## Red Flag: Heavy Work per Table Row

Anything done per row of a log table (reading the row from the document, the cells of its columns,
rule matching, match ranges, drawing) is hot: a fast scroll renders very
many rows. Keep it cheap:

- skip work entirely when nothing needs it (no matcher, no search: null, not computed);
- check cheap conditions first, compare substrings by code units (no auto-decoding);
- no allocation per row where a reused buffer will do.

Measure before and after optimizing (`scripts/utils/bench_rows.d`, `docs/performance.md`, roughly
100–140 ns/row of per-row work against decode).

## Red Flag: Hiding a Log Table

Never hide a log table itself with `display: none`. The tables of a document share one column host
(`ptable/columnhost`), whose room of the columns is the least width its tables tell: a hidden table
told 0 wide narrows the columns of the other one. Status views cover a table instead
(`.status-view.overlay`); the table under a status stays in its host and keeps taking part in the
fitting of the widths (taking it out by `Table.detach` is in `docs/backlog.md`).

## Red Flag: Restyling Existing UI Unasked

Don't change the layout or CSS of existing UI unless the change was asked for, even when a
screenshot or a review finding suggests a problem (e.g. a translated label looks cut). Report
what was noticed and leave the decision to the user. Review findings about layout are
mentioned, not applied.

## Styling

- Colors are theme variables in `resources/theme-light.css` and `theme-dark.css`; every new
  color goes to both themes.
- New and edited CSS sizes are in `pt` first, then `dip`; `px` only where device pixels are
  meant. Lines and borders are in `dip`, not `1px`. Existing `px` values are not rewritten
  unasked.
- A column's look (width) is in `resources/table.css` by `col-<column id>` /
  `col-<format id>-<column id>`, not in the format.
- Prefer CSS to JS for animation.

## Text Selection in Tables

No `selectable` in a log table: it is drawn by D, which selects text itself (`ptable`: `selection`, `rowhits`).
