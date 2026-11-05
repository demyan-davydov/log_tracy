// The menu bar of the window on Windows and Linux (macOS: the native menu),
// drawn from the menu the backend describes (backend.menu().menus, built by
// source/ui/app_menu.d): a Sciter `behavior: menu-bar` (menu-bar.css). Its
// items, their shortcuts and mnemonics run the commands given to `run`.
//
// Mnemonics are handled here, not by Sciter's accesskey: Alt+letter opens an
// entry of the bar, a letter in an open menu chooses its item. As in Windows,
// their letters are underlined only once Alt was pressed (class "cues").
import { commandOfKey, shortcutsOf, mnemonicParts, mnemonicOf } from "menu-shortcuts.js";

// The label with its mnemonic letter in <u>
function labelOf(item) {
    const parts = mnemonicParts(item);
    return parts ? [parts.before, <u>{parts.key}</u>, parts.after] : [item.label];
}

// A <menu> carries the path of its items in the bar ("0", "0.3"): menuAt finds them
function menuOf(items, path) {
    return <menu path={path}>{items.map((item, i) => itemOf(item, `${path}.${i}`))}</menu>;
}

function itemOf(item, path) {
    if (item.separator) return <hr />;
    if (item.items) return <li>{labelOf(item)}{menuOf(item.items, path)}</li>;
    return <li command={item.command}>
        {labelOf(item)}
        {item.shortcut ? <span class="accesskey">{item.shortcut.text}</span> : []}
    </li>;
}

function menuAt(bar, path) {
    let items = bar;
    for (const i of path.split(".").map(Number)) items = items[i].items;
    return items;
}

// Opens the menu of a bar entry or a submenu item `li`
const openMenuOf = li => li.popup(li.$("menu"), { anchorAt: li.parentElement.id === "menu-bar" ? 1 : 3, popupAt: 7 });

// Shows `bar` in `host` and handles it: a click on an item, its shortcut or its
// mnemonic calls run(command)
export function showMenuBar(host, bar, run) {
    host.innerHTML = "";
    host.append(<ul id="menu-bar">
        {bar.map((entry, i) => <li><caption>{labelOf(entry)}</caption>{menuOf(entry.items, `${i}`)}</li>)}
    </ul>);
    host.style.display = "block";
    const strip = host.$("#menu-bar");
    host.on("click", "li[command]", (evt, item) => run(item.getAttribute("command")));

    const closeMenus = () => { for (const menu of host.$$("menu:popup")) menu.state.popup = false; };
    const choose = li => {
        if (li.$("menu")) return openMenuOf(li);
        closeMenus();
        run(li.getAttribute("command"));
    };
    const cues = on => host.classList.toggle("cues", on);

    // Before the element in focus, as the accelerators of a native menu: an
    // editor doesn't take Ctrl+O or Alt+F away from the menu
    const shortcuts = shortcutsOf(bar);
    document.addEventListener("keydown", evt => {
        if (evt.code === "AltLeft" || evt.code === "AltRight") return cues(true);
        const open = host.$$("menu:popup").pop(); // the innermost
        let target = null;
        if (open) {
            const i = mnemonicOf(menuAt(bar, open.getAttribute("path")), evt, false);
            if (i >= 0) target = () => choose(open.children[i]);
        } else {
            const i = mnemonicOf(bar, evt, true);
            if (i >= 0) target = () => { cues(true); openMenuOf(strip.children[i]); };
        }
        const command = target ? null : commandOfKey(shortcuts, evt);
        if (!target && !command) return;
        evt.preventDefault();
        evt.stopPropagation();
        if (target) target();
        else run(command);
    }, { capture: true });
    document.addEventListener("mousedown", () => cues(false), { capture: true });
    host.on("popupdismissed", () => { if (!host.$$("menu:popup").length) cues(false); });
}
