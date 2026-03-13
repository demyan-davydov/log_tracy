console.log("Loading virtual-dlt-view.js...");
import { VirtualSelect } from "virtual-select.js";

// select with virtual data source
export class VirtualDltTBody extends VirtualSelect {
    //list; // array of items

    this(props) {
        super.this(props);
    }

    indexOf(item) {
        return item.index;
    }

    // overridable
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
        //console.log("--- renderItem called for item:", item);

        // Array layout from D backend asSciterArray(index, DocumentItem):
        const idx_index = 0;
        const idx_offset = 1;
        const idx_length = 2;
        const idx_timestamp = 3;
        const idx_ecu = 4;
        const idx_appId = 5;
        const idx_ctxId = 6;
        const idx_level = 7;
        const idx_type = 8;
        const idx_messageId = 9;
        const idx_payload = 10;

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

        return <tr state-current={isCurrent} state-checked={isSelected}>
            <td>{item[idx_index]}</td>
            <td>{item[idx_offset]}</td>
            <td>{item[idx_timestamp]}</td>
            <td>{item[idx_ecu]}</td>
            <td>{item[idx_appId]}</td>
            <td>{item[idx_ctxId]}</td>
            <td>{item[idx_length]}</td>
            <td>{messageType}</td>
            <td class={logLevel}>{logLevel}</td>
            <td>{item[idx_payload]}</td>
        </tr>
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
        console.log("VirtualMainViewTBody constructor");
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
        console.log("VirtualSearchViewTBody constructor");
    }

    itemAt(at) {
        return Window.this.xcall("getSearchViewItem", at);
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getSearchViewCount");
        return totalLogs;
    }
}