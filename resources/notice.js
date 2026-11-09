//! Notices: short non-modal popups next to the element they are about that
//! hide themselves after a few seconds (how they look and appear: popup.notice
//! in table.css).

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

// Hides the notice shown if it is `popup` (any if none given)
function hide(popup = shown?.popup) {
    if (!shown || shown.popup !== popup) return; // hidden already, or replaced
    shown.cleanup();
    shown = null;
    popup.state.popup = false;
    popup.remove();
}
