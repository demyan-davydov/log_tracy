// The menu of the window on Windows and Linux (macOS: the native menu), drawn
// from the menu the backend describes (backend.menu(), built by
// source/ui/app_menu.d): a flat list behind a round button at the right of
// the tabs, as GNOME's main menu. Its items and their shortcuts run the
// commands given to `run`. The button is seen by the styles (main-menu.css,
// by the media variable ui-platform).
import { tr } from "i18n/i18n.js";
import { commandOfKey, shortcutsOf } from "menu-shortcuts.js";

function itemOf(item) {
    if (item.separator) return <hr />;
    return <li command={item.command}>
        {item.label}
        {item.shortcut ? <span class="accesskey">{item.shortcut.text}</span> : []}
    </li>;
}

// The menu shown: { items, run, shortcuts, button }; null until shown
let shown = null;

const closeMenu = button => { for (const menu of button.$$("menu:popup")) menu.state.popup = false; };

// Shows `items`, a flat list (commands and separators: a submenu isn't drawn),
// as the list of the menu button in `host` (its <button>, from the markup,
// out of the Tab order) and handles it: a press on the button opens the list
// or closes it, a click on an item or its shortcut calls run(command). Shown again
// (another language, another label), it replaces the list shown before; the
// handlers are set once and take the menu shown now. The button takes no
// focus: the keys stay where they were
export function showMainMenu(host, items, run) {
    const first = shown === null;
    const button = host.$("button");
    closeMenu(button);
    button.$("menu")?.remove();
    // the list is a child of its owner, as in Sciter's samples: its clicks
    // and its dismissal come up to the button
    button.append(<menu>{items.map(itemOf)}</menu>);
    button.setAttribute("title", tr("Main Menu"));
    shown = { items, run, shortcuts: shortcutsOf(items), button };
    if (first) handleMainMenu(button);
}

// Opens the list of the menu button, or closes it when open
function toggleMenu(button) {
    const list = button.$("menu"); // its own state: the tooltip of the button is a popup of the button too
    if (list.state.popup) closeMenu(button);
    else button.popup(list, { anchorAt: 3, popupAt: 9 }); // under the button, its right edge on the button's
}

// The handlers of the menu button, of the menu shown at the time of an event
function handleMainMenu(button) {
    button.on("click", "li[command]", (evt, item) => shown.run(item.getAttribute("command")));
    // a press on the button opens the list or closes it; a press on the list
    // is the list's (the click on an item still comes and runs it). Handled:
    // the focus stays where it was
    button.on("mousedown", evt => {
        if (!evt.target?.closest("menu")) toggleMenu(button);
        return true;
    });
    // Before the element in focus, as the accelerators of a native menu: an
    // editor doesn't take Ctrl+O away from the menu
    document.addEventListener("keydown", evt => {
        const command = commandOfKey(shown.shortcuts, evt);
        if (!command) return;
        evt.preventDefault();
        evt.stopPropagation();
        closeMenu(shown.button); // the list open, if it is: the command goes on without it
        shown.run(command);
    }, { capture: true });
}
