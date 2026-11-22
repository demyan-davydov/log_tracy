//! A popup by a place of an element that has no element of its own (a title or a cell of the log table, drawn by D).
//! Free of state: each caller keeps the popups it shows (notice.js, the tip of a title in log-table-view.js).

// Shows `popup` by `rect` ([x, y, w, h] in the own coordinates of `parent`, in dips): an empty element is put there, inside the parent,
// to own the popup (the owner of a popup that is not in the table takes the mouse from it: the table loses its hover and its cursor, a
// child of the table does not). `anchorAt` and `popupAt` as `Element.popup` takes them (the points of the numeric keypad). Sciter
// closes the popup by a press outside it or when the window loses the focus: `onDismissed()` is called then. Returns the function that
// closes it, which does nothing the second time.
export function popupAtRect(parent, rect, popup, { anchorAt, popupAt, onDismissed = () => {} }) {
    const [x, y, w, h] = rect;
    const owner = Element.create(<div class="popup-owner" style={`position: absolute; left: ${x}dip; top: ${y}dip; width: ${w}dip; height: ${h}dip;`} />);
    parent.append(owner);
    document.body.append(popup);
    owner.popup(popup, { anchorAt, popupAt });
    let open = true;
    const close = () => {
        if (!open) return;
        open = false;
        owner.removeEventListener("popupdismissed", dismissed);
        popup.state.popup = false;
        popup.remove();
        owner.remove();
    };
    const dismissed = () => { close(); onDismissed(); };
    owner.addEventListener("popupdismissed", dismissed);
    return close;
}
