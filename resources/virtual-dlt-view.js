console.log("Loading virtual-dlt-view.js...");
import { VirtualList } from "virtual-select.js";
import { VirtualSelect } from "virtual-select.js";

// select with virtual data source
export class VirtualDltTBody extends VirtualSelect {
    //list; // array of items

    this(props) {
        super.this(props);
        super.selectedItems = new Set();
    }

    // View index (position in the current table) - mandatory for Shift-selection and Arrows
    indexOf(item) {
        return item[2]; // idx_viewIndex is 2
    }

    // Stable global record index - identifier for the logic (Set)
    keyOf(item) {
        return item[3]; // idx_absolute_index is 3
    }


    /*renderItem(item, isCurrent, isSelected) {
        return <tr state-current={isCurrent} state-checked={isSelected}>
            <td>{item.index}</td>
            <td>{item.offset}</td>
            <td>{item.timestamp}</td>
            <td>{item.ecu}</td>
            <td>{item.appId}</td>
            <td>{item.ctxId}</td>
            <td>{item.length}</td>
            <td>{item.type}</td>
            <td class={`level-${item.level.toLowerCase()}`}>{item.level}</td>
            <td>{item.payload}</td>
        </tr>
    }*/

    renderItem(item, isCurrent, isSelected) {
        if (isCurrent || isSelected) {
            console.log("--- renderItem called for item:", item[3], "isCurrent:", isCurrent, "isSelected:", isSelected);
        }

        //
        const currentKey = this.currentItem ? this.indexOf(this.currentItem) : null;
        isCurrent = currentKey !== null && this.indexOf(item) === currentKey;
        const selectedKey = this.selectedItems ? this.indexOf(this.selectedItems) : null;
        isSelected = selectedKey !== null && this.indexOf(item) === selectedKey;

        if (isCurrent || isSelected) {
            console.log("--- [2] renderItem called for item:", item[3], "isCurrent:", isCurrent, "isSelected:", isSelected);
        }

        // Array layout from D backend asSciterArray(index, DocumentItem):
        const idx_anchor = 0;
        const idx_filterMask = 1;
        const idx_viewIndex = 2;
        const idx_absolute_index = 3;
        const idx_timestamp_seconds = 4;
        const idx_timestamp_microseconds = 5;
        const idx_rel_timestamp_10000 = 6;
        const idx_ecuId = 7;
        const idx_appId = 8;
        const idx_ctxId = 9;
        const idx_level = 10;
        const idx_type = 11;
        const idx_messageId = 12;
        const idx_payload = 13;

        const timestamp = function (seconds, microseconds) {
            seconds = Number(seconds);
            microseconds = Number(microseconds);
            if (seconds === 0 && microseconds === 0) return "-";
            const date = new Date(seconds * 1000);
            const year = date.getFullYear();
            const month = String(date.getMonth() + 1).padStart(2, '0');
            const day = String(date.getDate()).padStart(2, '0');
            const hour = String(date.getHours()).padStart(2, '0');
            const minute = String(date.getMinutes()).padStart(2, '0');
            const second = String(date.getSeconds()).padStart(2, '0');
            const us = String(microseconds).padStart(3, '0');
            return `${year}/${month}/${day} ${hour}:${minute}:${second}.${us}`;
        }(item[idx_timestamp_seconds], item[idx_timestamp_microseconds]);

        const relTimestamp = function (timeUnits) {
            timeUnits = Number(timeUnits);
            if (timeUnits === 0) return "-";
            // DLT relative time is basically in 0.1ms units
            const second = Math.floor(timeUnits / 10000);
            const fraction = String(timeUnits % 10000).padStart(4, '0');
            return `${second}.${fraction}`;
        }(item[idx_rel_timestamp_10000]);

        const logLevel = function (levelAsInt) {
            switch (levelAsInt) {
                case 0x1: return "Fatal";
                case 0x2: return "Error";
                case 0x3: return "Warn";
                case 0x4: return "Info";
                case 0x5: return "Debug";
                case 0x6: return "Verbose";
                default: return "unknown";
            }
        }(item[idx_level]);

        const messageType = function (typeAsInt) {
            switch (typeAsInt) {
                case 0x0: return "LOG";
                case 0x1: return "APP";
                case 0x2: return "NW";
                case 0x3: return "CTRL";
                default: return "unknown";
            }
        }(item[idx_type]);

        return <tr state-current={isCurrent} state-checked={isSelected} view-index={item[idx_viewIndex]}>
            <td class="anchor" has-anchor={item[idx_anchor] ? "true" : "false"} msg-index={item[idx_absolute_index]}></td>
            <td>{item[idx_absolute_index]}</td>
            <td>{timestamp}</td>
            <td>{relTimestamp}</td>
            <td>{item[idx_ecuId]}</td>
            <td>{item[idx_appId]}</td>
            <td>{item[idx_ctxId]}</td>
            <td>{messageType}</td>
            <td class={logLevel}>{logLevel}</td>
            <td selectable>{item[idx_payload]}</td>
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