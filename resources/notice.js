//! Notices: short non-modal popups next to the element they are about that
//! hide themselves after a few seconds (how they look and appear: popup.notice
//! in table.css).
import { pointInRect } from "geometry.js";

// The notice shown, null if none: a new one replaces it
let shown = null;

// Shows `text` by `owner` for `ms`. `at` places it: "below" (over the bottom
// of the owner, centred) or "right" (right of the owner, sliding out of it).
// `untilLeave`: hidden as soon as the mouse leaves the owner, too.
export function showNotice(owner, text, { at = "below", ms = 4000, untilLeave = false } = {}) {
    hide();
    const popup = Element.create(<popup class={"notice " + at}>{text}</popup>);
    document.body.append(popup);
    if (at === "right") owner.popup(popup, { anchorAt: 6, popupAt: 4 }); // its middle-left on the owner's middle-right
    else owner.popup(popup, { anchorAt: 2, popupAt: 2 }); // bottom-center on bottom-center
    const left = () => hide(popup);
    if (untilLeave) owner.addEventListener("mouseleave", left);
    shown = { popup, cleanup: () => { if (untilLeave) owner.removeEventListener("mouseleave", left); } };
    setTimeout(() => hide(popup), ms);
}

// Shows `text` right of a place that has no element of its own (a cell of the table drawn by D): `parent` is the element of the table,
// `rect` is [x, y, w, h] of the place in the parent's own coordinates, in dips. An empty element is put there, inside the parent, to own
// the popup: the owner of a popup that is not in the table takes the mouse from it (the table loses its hover and its cursor), a child of
// the table does not, as the cell of the old table. Sciter closes the popup by a press outside it (and the owner goes then: it hears
// `popupdismissed`); it is hidden too when the mouse leaves the place (a move of the mouse over the parent is checked, there is no
// element to leave) and after `ms`.
export function showNoticeAt(parent, rect, text, { ms = 2500 } = {}) {
    hide();
    const [x, y, w, h] = rect;
    const owner = Element.create(<div class="notice-owner" style={`position: absolute; left: ${x}dip; top: ${y}dip; width: ${w}dip; height: ${h}dip;`} />);
    parent.append(owner);
    const popup = Element.create(<popup class="notice right">{text}</popup>);
    document.body.append(popup);
    owner.popup(popup, { anchorAt: 6, popupAt: 4 }); // its middle-left on the owner's middle-right
    const moved = evt => { if (!pointInRect(evt.x, evt.y, rect)) hide(popup); };
    const dismissed = () => hide(popup);
    parent.addEventListener("mousemove", moved);
    owner.addEventListener("popupdismissed", dismissed);
    shown = {
        popup,
        cleanup: () => {
            parent.removeEventListener("mousemove", moved);
            owner.removeEventListener("popupdismissed", dismissed);
            owner.remove();
        },
    };
    setTimeout(() => hide(popup), ms);
}

// Hides the notice shown if it is `popup` (any if none given)
function hide(popup = shown?.popup) {
    if (!shown || shown.popup !== popup) return; // hidden already, or replaced
    shown.cleanup();
    shown = null;
    popup.state.popup = false;
    popup.remove();
}
