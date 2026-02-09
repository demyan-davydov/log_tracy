console.log("Loading virtual-dlt-view.js...");
import { VirtualSelect } from "virtual-select.js";

// select with virtual data source
export class VirtualDltTBody extends VirtualSelect {
    //list; // array of items

    this(props) {
        console.log("VirtualDltTBody.this", props);
        super.this(props);
    }

    itemAt(at) {
        const jsonStr = Window.this.xcall("getLogItem", at);
        return JSON.parse(jsonStr);
        //return this.list[at];
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getLogCount");
        return totalLogs;
        //return this.list.length;
    }

    indexOf(item) {
        console.log("indexOf: ", item);
        return item.index;
        //return this.list.indexOf(item);
    }

    // overridable
    renderItem(item, isCurrent, isSelected) {
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
    }

    renderList(items) // overridable
    {
        //return <tbody>{items}</tbody>;
        return items;
    }
}