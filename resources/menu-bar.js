// The menu bar of the window on Windows and Linux (macOS: the native menu),
// drawn from the menu the backend describes (backend.menuBar(), built by
// source/ui/app_menu.d): a Sciter `behavior: menu-bar` (menu-bar.css). Its
// items and their shortcuts run the commands given to `run`.
import { commandOfKey, shortcutsOf } from "menu-shortcuts.js";

function itemOf(item) {
    if (item.separator) return <hr />;
    if (item.items) return <li>{item.label}<menu>{item.items.map(itemOf)}</menu></li>;
    return <li command={item.command}>
        {item.label}
        {item.shortcut ? <span class="accesskey">{item.shortcut.text}</span> : []}
    </li>;
}

// Shows `bar` in `host` and handles it: a click on an item or its shortcut
// calls run(command)
export function showMenuBar(host, bar, run) {
    host.innerHTML = "";
    host.append(<ul id="menu-bar">
        {bar.map(entry => <li><caption>{entry.label}</caption><menu>{entry.items.map(itemOf)}</menu></li>)}
    </ul>);
    host.style.display = "block";
    host.on("click", "li[command]", (evt, item) => run(item.getAttribute("command")));
    // Before the element in focus, as the accelerators of a native menu: an
    // editor doesn't take Ctrl+O away from the menu
    const shortcuts = shortcutsOf(bar);
    document.addEventListener("keydown", evt => {
        const command = commandOfKey(shortcuts, evt);
        if (!command) return;
        evt.preventDefault();
        evt.stopPropagation();
        run(command);
    }, { capture: true });
}
