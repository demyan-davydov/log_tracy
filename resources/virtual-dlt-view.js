console.log("Loading virtual-dlt-view.js...");
import { VirtualList } from "virtual-select.js";
import { VirtualSelect } from "virtual-select.js";

// Columns of the active document, from Window.xcall("getColumns"):
// [{ id, title, kind, width, timeKind?, unitsPerSecond?, labels? }]
let columns = [];

// Sets the columns the rows are rendered with; the table header is rebuilt by
// the caller (see renderHeader)
export function setColumns(newColumns) {
    columns = newColumns;
}

// The header row of a log table for the current columns
export function renderHeader() {
    return <tr>
        <th width="20px">⚓</th>
        <th width="80px">Index</th>
        {columns.map(c => <th width={c.width ? `${c.width}px` : "*"}>{c.title}</th>)}
    </tr>;
}

const pad = (value, digits) => String(value).padStart(digits, "0");

// Time cell: microseconds since the epoch (or since boot), null if none
function formatTime(us, timeKind) {
    if (us === null || us === undefined) return "-";
    const seconds = Math.floor(us / 1e6);
    const fraction = pad(us - seconds * 1e6, 6);
    if (timeKind === "SinceBoot") return `${seconds}.${fraction}`;
    if (us === 0) return "-"; // no time recorded
    const date = new Date(seconds * 1000);
    // Absolute is a moment, shown in the user's zone; Local* is the wall-clock
    // time of the source stored as if it were UTC, shown as is
    const local = timeKind !== "Absolute";
    const [year, month, dayOfMonth, hours, minutes, secs] = local
        ? [date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()]
        : [date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes(), date.getSeconds()];
    const day = `${pad(month + 1, 2)}/${pad(dayOfMonth, 2)}`;
    const time = `${pad(hours, 2)}:${pad(minutes, 2)}:${pad(secs, 2)}`;
    if (timeKind === "LocalNoYear") return `${day} ${time}.${fraction}`;
    return `${year}/${day} ${time}.${fraction}`;
}

// Duration cell: a number in 1/unitsPerSecond of a second
function formatDuration(units, unitsPerSecond) {
    units = Number(units);
    if (units === 0) return "-";
    const digits = Math.round(Math.log10(unitsPerSecond));
    return `${Math.floor(units / unitsPerSecond)}.${pad(units % unitsPerSecond, digits)}`;
}

const levelNames = ["", "Fatal", "Error", "Warn", "Info", "Debug", "Verbose"];

function renderCell(column, value) {
    if (value === null && column.kind !== "Time")
        return <td class="aux"></td>; // the record has no such field
    switch (column.kind) {
        case "Time": return <td class="aux">{formatTime(value, column.timeKind)}</td>;
        case "Level": {
            if (!value) return <td class="aux"></td>; // LogLevel.None: the record has no level
            const level = levelNames[value] ?? "unknown";
            return <td class={`level-${level.toLowerCase()}`}>{level}</td>;
        }
        case "Payload": return <td selectable>{value}</td>;
        case "Integer": return <td class="aux">{String(value)}</td>;
        case "Hex": return <td class="aux">{value}</td>; // formatted by the backend: all 64 bits
        case "Duration": return <td class="aux">{formatDuration(value, column.unitsPerSecond)}</td>;
        case "Enum": return <td class="aux">{column.labels?.[value] ?? "unknown"}</td>;
        default: return <td class="aux">{value}</td>; // Text
    }
}

// select with virtual data source
export class VirtualDltTBody extends VirtualSelect {
    //list; // array of items

    this(props) {
        super.this(props);
        // keyOf() of the selected items. Not called for the tbody bound by CSS
        // `prototype:`, so selectedKeys may be undefined: guard every use
        this.selectedKeys = new Set();
    }

    // The selection, to be restored by restoreSelection() while the list shows
    // the same content: currentItem refers to a position in the view
    saveSelection() {
        return { currentItem: this.currentItem, selectedKeys: new Set(this.selectedKeys ?? []) };
    }

    // Restores a selection from saveSelection(); null clears the selection.
    // Takes effect on the next render of the rows.
    restoreSelection(selection) {
        this.currentItem = selection ? selection.currentItem : null;
        this.selectedKeys = new Set(selection ? selection.selectedKeys : []);
    }

    // View index (position in the current table) - mandatory for Shift-selection and Arrows
    indexOf(item) {
        return item?.[2]; // idx_viewIndex is 2; null: no such row
    }

    // Stable global record index - identifier for the logic (Set)
    keyOf(item) {
        return item?.[3]; // idx_absolute_index is 3
    }


    renderItem(item, isCurrent, isSelected) {
        // No such row (any more): the backend returns null, e.g. the view just
        // changed. An empty row keeps the rows in place until the next render.
        if (!item) return <tr />;

        const currentKey = this.currentItem ? this.indexOf(this.currentItem) : null;
        isCurrent = currentKey !== null && this.indexOf(item) === currentKey;
        isSelected = this.selectedKeys?.has(this.keyOf(item)) ?? false;

        // Row layout from D backend asSciterRow(): the fixed cells, then a
        // cell per column of the document (see setColumns)
        const idx_anchor = 0;
        const idx_viewIndex = 2;
        const idx_absolute_index = 3;
        const idx_firstColumn = 4;

        return <tr state-current={isCurrent} state-checked={isSelected} view-index={item[idx_viewIndex]}>
            <td class="anchor" has-anchor={item[idx_anchor] ? "true" : "false"} msg-index={item[idx_absolute_index]}></td>
            <td class="aux">{item[idx_absolute_index]}</td>
            {columns.map((column, i) => renderCell(column, item[idx_firstColumn + i]))}
        </tr>
    }

    // Re-renders the rows currently on screen with fresh data from the backend.
    // render() doesn't update existing rows when the number of items is
    // unchanged (Sciter ignores the returned rows), so after any change of the
    // data (a new search or filter result, an anchor) call this after
    // componentUpdate(). When the number of items changes, render() clears the
    // rows itself and there is nothing left to refresh here.
    refreshVisibleRows() {
        const total = this.totalItems();
        for (const row of this.children) {
            const viewIndex = Number(row.getAttribute("view-index"));
            if (!(viewIndex < total)) continue; // no view-index, or past the end
            const item = this.itemAt(viewIndex);
            if (item) row.patch(this.renderItem(item, false, false));
        }
    }

    renderList(items) // overridable
    {
        return items;
        //return <tbody {...this.attributes}>{items}</tbody>;
    }
}

export class VirtualMainViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return Window.this.xcall("getMainViewItem", at);
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getMainViewCount");
        return totalLogs;
    }
}

export class VirtualSearchViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return Window.this.xcall("getSearchViewItem", at);
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getSearchViewCount");
        return totalLogs;
    }
}