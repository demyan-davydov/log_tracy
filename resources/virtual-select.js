// A list that renders only the items on screen (behavior: virtual-list). The
// selection lives in the subclasses (see VirtualDltTBody).
import { navigationPast, growStep, navigationStep, fillStep } from "./list-navigation.js";

export class VirtualList extends Element {
    // Where the next render() scrolls to: a row number, "start" or "end"; null
    // keeps the scroll. render() runs posted by componentUpdate(), so a
    // navigation posted next to componentUpdate() would come before the one
    // render() posts itself and be overridden by it: set this instead.
    navigateTarget = null;
    styleSet;
    props;

    this(props) {
        const { renderItem, renderList, ...rest } = props;
        super.this?.(rest);
        this.props = rest;
        this.renderItem = renderItem || this.renderItem;
        this.renderList = renderList || this.renderList;
        this.styleset = props.styleset || (__DIR__ + "virtual-select.css#virtual-select");
    }

    itemAt(at) { // virtual function, must be overriden
        return null;
    }

    totalItems() { // virtual function, must be overriden
        return 0;
    }

    render() {
        const list = [];
        if (!this.vlist) return this.renderList(list);

        const firstIndex = this.vlist.firstBufferIndex;
        let lastIndex = this.vlist.lastBufferIndex;
        const firstVisibleIndex = firstIndex + this.vlist.firstVisibleItem?.elementIndex || 0;
        const lastVisibleIndex = firstIndex + this.vlist.lastVisibleItem?.elementIndex;

        const totalItems = this.totalItems();
        // ?? null: field initializers don't run for elements bound by CSS `prototype:`
        const target = this.navigateTarget ?? null;
        this.navigateTarget = null;

        if (this.vlist.itemsTotal != totalItems) { // number of items reduced, update scroll
            // The rendered rows belong to the old data set: drop them before the
            // navigation below requests the new ones, otherwise vlist keeps them
            this.clear();
            if (target !== null) {
                // No rows rendered: the target comes from outside the window
                this.post(() => {
                    this.navigateTo(target);
                });
                return this.renderList([]); // render empty list and request the asked navigation
            }

            if (firstVisibleIndex == 0) {
                this.post(() => {
                    this.navigateTo("start");
                });
                return this.renderList([]); // render empty list and request "from start" navigation
            }

            if (lastVisibleIndex >= totalItems) {
                this.post(() => {
                    this.navigateTo("end"); // the last row, see safeTarget
                });
                return this.renderList([]); // render empty list and request "from end" navigation
            }

            lastIndex = Math.min(totalItems, firstIndex + this.vlist.slidingWindowSize) - 1;
            this.post(() => {
                this.vlist.itemsAfter = totalItems - this.vlist.itemsBefore - this.children.length;
            });
        }

        for (let index = firstIndex; index <= lastIndex; ++index) {
            const item = this.itemAt(index);
            if (item) list.push(this.renderItem(item));
        }

        if (target !== null)
            this.post(() => {
                this.navigateToTop(target, totalItems);
            });
        return this.renderList(list);
    }

    // Scrolls so that the row `target` (or "start", "end") is the first on
    // screen, of `total` rows: a row vlist.navigateTo() would leave below the
    // top is first navigated past, see navigationPast()
    navigateToTop(target, total) {
        const vlist = this.vlist;
        if (!vlist) return;
        const firstBuffer = vlist.firstBufferIndex;
        const firstItem = vlist.firstVisibleItem;
        const past = navigationPast(target, {
            firstVisible: firstItem ? firstBuffer + firstItem.elementIndex : null,
            lastBuffer: vlist.lastBufferIndex,
            total,
            windowSize: vlist.slidingWindowSize,
        });
        if (past !== null) this.navigateTo(past);
        this.navigateTo(target);
    }

    // vlist.navigateTo(target) made safe, see navigationStep: the rows of a
    // view that grew are counted first, the target kept within the rows (a row
    // past the count crashes Sciter, "end" is the last row). Every navigation
    // of a list goes through here, never vlist.navigateTo or vlist.navigate.
    navigateTo(target) {
        const vlist = this.vlist;
        if (!vlist) return;
        const step = navigationStep(target, {
            total: this.totalItems(), before: vlist.itemsBefore, rendered: this.children.length, after: vlist.itemsAfter,
        });
        if (step.after !== null) vlist.itemsAfter = step.after;
        if (step.target !== null) vlist.navigateTo(step.target);
    }

    // Renders rows up to the window, see fillStep: a list whose window grew
    // shows a gap under its rows otherwise. The rows on screen stay as they are.
    fill() {
        const vlist = this.vlist;
        if (!vlist) return;
        const before = vlist.itemsBefore;
        const rendered = this.children.length;
        const step = fillStep({ before, rendered, after: vlist.itemsAfter, windowSize: vlist.slidingWindowSize });
        if (step === null) return;
        const rows = (from, to) => {
            const elements = [];
            for (let index = from; index < to; ++index) {
                const item = this.itemAt(index);
                if (!item) return null; // gone meanwhile: the list asks for what there is when scrolled
                elements.push(this.renderItem(item));
            }
            return elements;
        };
        const after = rows(before + rendered, before + rendered + step.append);
        const prepended = after && rows(step.before, before);
        if (!after || !prepended) return;
        if (after.length) this.append(after);
        if (prepended.length) this.prepend(prepended);
        vlist.itemsAfter = step.after;
        vlist.itemsBefore = step.before;
        // Rows before are rendered at the end of the rows only: the rows on screen
        // were pushed down by them, the last row goes back to the bottom
        if (prepended.length) this.navigateTo("end");
    }

    // The list has more items after the ones it had (totalItems() grew, the
    // items it had are the same): they are counted, and rendered if the list
    // has room; the rows on screen stay as they are, see growStep(). A list it
    // can't grow in place is rebuilt (componentUpdate).
    grow() {
        const vlist = this.vlist;
        if (!vlist) return;
        const total = this.totalItems();
        const before = vlist.itemsBefore;
        const rendered = this.children.length;
        const step = growStep({ total, before, rendered, after: vlist.itemsAfter, windowSize: vlist.slidingWindowSize });
        if (step === null) return;
        if (step.rebuild) {
            this.componentUpdate();
            return;
        }
        for (let index = before + rendered; index < before + rendered + step.append; ++index) {
            const item = this.itemAt(index);
            if (!item) { // gone meanwhile: the list is rebuilt from what there is
                this.componentUpdate();
                return;
            }
            this.append(this.renderItem(item));
        }
        vlist.itemsAfter = step.after;
    }

    // scroll down
    appendElements(index, n) {
        if (index === undefined) index = 0;
        const elements = [];
        for (let i = 0; i < n; ++i, ++index) {
            if (index >= this.totalItems()) break;
            const item = this.itemAt(index);
            elements.push(this.renderItem(item));
        }

        this.append(elements);
        return { moreafter: (this.totalItems() - index) }; // return estimated number of items below this chunk
    }

    // scroll up
    prependElements(index, n) {
        if (index === undefined) index = this.totalItems() - 1;
        const elements = [];
        for (let i = 0; i < n; ++i, --index) {
            if (index < 0) break;
            const item = this.itemAt(index);
            elements.push(this.renderItem(item));
        }

        elements.reverse();
        this.prepend(elements);
        return { morebefore: (index < 0 ? 0 : index + 1) }; // return estimated number of items above this chunk
    }

    // scroll to
    replaceElements(index, n) {
        const elements = [];
        const start = index;
        for (let i = 0; i < n; ++i, ++index) {
            if (index >= this.totalItems()) break;
            const item = this.itemAt(index);
            elements.push(this.renderItem(item));
        }

        this.patch(elements);
        return {
            morebefore: start <= 0 ? 0 : start,
            moreafter: this.totalItems() - index,
        }; // return estimated number of items before and above this chunk
    }

    renderList(items) // overridable
    {
        return <virtual-select {this.props} styleset={this.styleset}>{items}</virtual-select>;
    }

    renderItem(item) // overridable
    {
        return <option>{String(item)}</option>;
    }

    oncontentrequired(evt) {
        const { length, start, where } = evt.data;
        if (where > 0) evt.data = this.appendElements(start, length); // scrolling down, need to append more elements
        else if (where < 0) evt.data = this.prependElements(start, length); // scrolling up, need to prepend more elements
        else evt.data = this.replaceElements(start, length); // scrolling to index
        return true;
    }
}

export class VirtualSelect extends VirtualList {
    items = [];

    this(props) {
        const { items, ...rest } = props;
        super.this(rest);
        this.items = items || [];
    }

    itemAt(at) { // virtual function, can be overriden
        return this.items?.[at];
    }

    totalItems() { // virtual function, can be overriden
        return this.items?.length || 0;
    }

    render(props) {
        if ((props?.items && (this.items !== props.items)) || !this.vlist) {
            this.items = props?.items || [];
            if (this.vlist) {
                this.post(() => {
                    this.navigateTo("start");
                });
            }
            return this.renderList([], props);
        }

        return super.render(props);
    }
}
