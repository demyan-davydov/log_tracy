// The tab strip of the window: a tab per open document in the order of the
// workspace, then the New Tab while it is open, and the + button. A tab is
// activated on mousedown (as in browsers) and can then be dragged to another
// place, Chrome-like (drag-strip.js); the close button closes it. What
// activating, closing and moving a tab mean is up to the host (script.js).
import { $, $$ } from "@sciter";
import { setShift, pressItem, dragTo, drop, showDropMarker } from "drag-strip.js";

export const NEW_TAB_ID = "new-tab";

// The tabs of the documents, without the New Tab
const DOC_TABS = `#tabs-container > .tab:not(#${NEW_TAB_ID})`;

// The strip a tab tooltip belongs to (there is one strip)
let strip = null;

// Tooltip of the tab strip: the full name Sciter shows by itself for a name
// cut by text-overflow (tabs have no title). style.css gives it this
// prototype: one that is about to appear while a tab is held is closed at
// once, the shown ones are tracked to close them when a tab is pressed (they
// can't be found with a selector).
const shownTabTooltips = new Set();

globalThis.TabTooltip = class extends Element {
    componentDidMount() {
        if (strip?.drag) this.state.popup = false;
        else shownTabTooltips.add(this);
    }
    componentWillUnmount() {
        shownTabTooltips.delete(this);
    }
};

function closeTabTooltips() {
    for (const popup of [...shownTabTooltips]) {
        shownTabTooltips.delete(popup);
        try { popup.state.popup = false; } catch (e) { }
    }
}

// Rectangle of a separator relative to the left edge of its tab
function measureTabSeparator(tab, tabRect) {
    const r = tab.$(".tab-sep").getBoundingClientRect();
    return { offset: r.left - tabRect.left, top: r.top, width: r.right - r.left, height: r.bottom - r.top };
}

export class TabStrip {
    // host: {
    //   pressTab(docId) - a document tab was pressed (it is dragged from there)
    //   pressNewTab(), closeNewTab(), closeTab(docId), addTab() (the + button)
    //   moveTab(docId, index) - a tab was dropped at another place
    //   refresh() - render the tabs again (see holdWhileDragging)
    // }
    constructor(host) {
        this.host = host;
        // The drag of drag-strip.js with { tab, sep }, null when no tab is held
        this.drag = null;
        this.refreshPending = false; // a refresh came while a tab was held
        strip = this;
        this.bind();
    }

    bind() {
        document.on("click", "#btn-add-tab", () => this.host.addTab());

        // Click only handles the close button: a tab is activated on mousedown
        document.on("click", ".tab .tab-close", (evt, close) => {
            const tab = close.parentElement;
            if (tab.id === NEW_TAB_ID) this.host.closeNewTab();
            else this.host.closeTab(parseInt(tab.id));
            return true;
        });

        document.on("mousedown", ".tab", (evt, tab) => {
            // Only the left button activates and drags: the right (2) and middle
            // (4) bits are the same in DOM and in Sciter (PROP_/MIDDLE_MOUSE_BUTTON)
            if (evt.buttons & 6) return;
            if (evt.target.classList.contains("tab-close")) return;
            if (this.drag?.settling) return; // the previous drop is still settling
            if (this.drag) this.finishDrag(false); // released outside the window: the press is dropped
            if (tab.id === NEW_TAB_ID) { // stays the last one: not dragged
                this.host.pressNewTab();
                return true;
            }
            this.host.pressTab(parseInt(tab.id)); // keeps the tab elements
            this.beginDrag(tab, evt.clientX);
            return true; // no text selection
        });

        document.on("mousemove", evt => { if (this.drag) this.moveDrag(evt.clientX); });
        document.on("mouseup", () => { if (this.drag) this.endDrag(); });
    }

    // While a tab is held the tabs are not rendered again (it would take the
    // tab from under the mouse): the refresh is done after the drop.
    // @returns true if the caller is to wait for it
    holdWhileDragging() {
        if (!this.drag) return false;
        this.refreshPending = true;
        return true;
    }

    // Renders the tabs. Same documents in the same order (e.g. another tab
    // was activated): the elements are kept, so a tab being pressed or dragged
    // stays in the DOM.
    // @param docs - [{ id, name, active }] in the order of the workspace
    // @param newTab - { open, active } (new-tab.js)
    // @param plusShown - whether the + button is shown
    render(docs, newTab, plusShown) {
        const container = $("#tabs-container");
        let tabs = [...$$(DOC_TABS)];
        const sameTabs = tabs.length === docs.length
            && tabs.every((tab, i) => parseInt(tab.id) === docs[i].id);
        if (!sameTabs) {
            // The + button is kept, the tabs follow it
            for (const tab of tabs) tab.remove();
            const newTabElement = $(`#${NEW_TAB_ID}`); // kept, after the documents
            for (const doc of docs) {
                container.append(<div class="tab" id={doc.id}>
                    <span class="tab-sep"></span>
                    <span class="tab-name"></span>
                    <span class="tab-close">×</span>
                </div>);
                if (newTabElement) container.insertBefore(container.lastElementChild, newTabElement);
            }
            tabs = [...$$(DOC_TABS)];
        }
        $("#btn-add-tab").style.display = plusShown ? "" : "none";
        docs.forEach((doc, i) => {
            const tab = tabs[i];
            if (doc.active && !newTab.active) tab.classList.add("active");
            else tab.classList.remove("active");
            tab.$(".tab-name").textContent = doc.name;
        });
        this.renderNewTab(newTab);
    }

    // Exposes the status of a document on its tab for CSS: main-status, search-status
    setStatus(docId, mainStatus, searchStatus) {
        const tab = $(`#tabs-container > .tab[id="${docId}"]`);
        if (!tab) return;
        tab.setAttribute("main-status", mainStatus || "");
        tab.setAttribute("search-status", searchStatus || "");
    }

    // The New Tab element: after all the document tabs while open
    renderNewTab(newTab) {
        const container = $("#tabs-container");
        let tab = $(`#${NEW_TAB_ID}`);
        if (!newTab.open) {
            if (tab) tab.remove();
            return;
        }
        if (!tab) {
            container.append(<div class="tab" id={NEW_TAB_ID}>
                <span class="tab-sep"></span>
                <span class="tab-name">New Tab</span>
                <span class="tab-close">×</span>
            </div>);
            tab = container.lastElementChild;
        }
        if (newTab.active) tab.classList.add("active");
        else tab.classList.remove("active");
    }

    // ---- dragging: no tooltips while a tab is held, they would cover the strip ----

    beginDrag(tab, clientX) {
        const tabs = [...$$(DOC_TABS)];
        const from = tabs.indexOf(tab);
        if (from < 0) return;
        this.drag = pressItem(tabs, from, clientX);
        this.drag.tab = tab;
        this.drag.sep = measureTabSeparator(tabs[0], this.drag.rects[0]);
        this.refreshPending = false;
        closeTabTooltips();
    }

    moveDrag(clientX) {
        const landed = dragTo(this.drag, clientX, () => {
            closeTabTooltips();
            $("#tabs-container").append(<div id="tab-drop-marker"></div>);
        });
        if (landed) this.showDropMarker(this.drag);
    }

    endDrag() {
        const d = this.drag;
        if (d.settling) return;
        // Slide into the free place, then commit the new order
        if (!drop(d, () => this.finishDrag(d.to !== d.from)))
            this.finishDrag(false); // a plain click
    }

    finishDrag(moved) {
        const d = this.drag;
        this.drag = null;
        const marker = $("#tab-drop-marker");
        if (marker) marker.remove();
        if (moved) {
            console.log("Tab", d.tab.id, "moved from", d.from, "to", d.to);
            this.host.moveTab(parseInt(d.tab.id), d.to); // renders the tabs in the new order
            return;
        }
        for (const t of d.items) {
            for (const cls of ["dragging", "shifting", "settling"]) t.classList.remove(cls);
            setShift(t, 0);
        }
        if (this.refreshPending) this.host.refresh();
    }

    // The marker is on the edge of the place the tab will land on, between it
    // and the tab it was moved past. It takes exactly the rectangle of a
    // separator on that edge (d.sep), so it covers the separator there.
    showDropMarker(d) {
        const marker = $("#tab-drop-marker");
        showDropMarker(marker, d, origin => {
            const edge = d.to > d.from ? d.rects[d.to].right : d.rects[d.to].left;
            marker.style.left = `${edge + d.sep.offset - origin.left}px`;
            marker.style.top = `${d.sep.top - origin.top}px`;
            marker.style.width = `${d.sep.width}px`;
            marker.style.height = `${d.sep.height}px`;
        });
    }
}
