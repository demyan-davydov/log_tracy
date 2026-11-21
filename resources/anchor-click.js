//! What a click on an anchor cell of the log table makes of the backend's answer, as plain data (the script does the calls):
//! tests/js/anchor-click.test.mjs. The click says which message and whether it is anchored now; the answer of `setAnchor` is
//! { refused, pending, rows: { message, anchored, main, search } | null }.

// What the tables are told after `setAnchor` answered `answer` to a click `click` ({ id, anchored, rect }): `rows` for
// `onAnchorApplied`, or nothing: a refusal changed nothing, and an anchor that is pending is told when the pass applies it.
// A row that stayed in both views (`rows` null) is read again where it stands. A refusal has a `notice` to show by the cell
// (`click.rect`, [x, y, w, h] in the table; `text` of the refusal, made by `textOf(answer)`), none if the cell is not known.
export function anchorClickPlan(click, answer, textOf = () => "") {
    if (answer.refused) {
        const text = textOf(answer);
        return { rows: null, notice: click.rect && text ? { rect: click.rect, text } : null };
    }
    if (answer.pending) return { rows: null, notice: null };
    const rows = answer.rows ?? { message: click.id, anchored: !click.anchored, main: false, search: false };
    return { rows, notice: null };
}

// Whether the row of the message came into the view `search` (the results) or the main one, or left it
export function rowMoved(rows, search) {
    return search ? !!rows.search : !!rows.main;
}
