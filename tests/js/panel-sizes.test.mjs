// The size of the bottom (search) panel in the settings, see resources/panel-sizes.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { panelSizesOf, splittersOf, rowsOf, collapseStep, activeTabOf, defaultRows } from "../../resources/panel-sizes.js";

test("the size of the panel is read from the splitter of a panel", () => {
    assert.deepEqual(panelSizesOf({ rows: "1*,177dip" }), { searchPanelHeight: "177dip", bottomPanelCollapsed: false });
    assert.deepEqual(panelSizesOf({ rows: "*, 250dip" }), { searchPanelHeight: "250dip", bottomPanelCollapsed: false },
        "spaces dropped");
});

test("the size measured on a panel wins over its splitter", () => {
    // After a drag the frameset fixes the main table and leaves the search panel flexible
    assert.deepEqual(panelSizesOf({ rows: "512px,1*", searchPanelHeight: "230dip" }),
        { searchPanelHeight: "230dip", bottomPanelCollapsed: false });
});

test("a collapsed panel saves the height it expands to, not that of its tabs", () => {
    assert.deepEqual(panelSizesOf({ rows: "1*,0dip", collapsed: true, searchPanelHeight: "230dip" }),
        { searchPanelHeight: "230dip", bottomPanelCollapsed: true });
});

test("the splitter of a new panel is made of the size saved", () => {
    assert.deepEqual(splittersOf({ searchPanelHeight: "177dip" }, { rows: "*, 250dip" }), { rows: "*,177dip" });
});

test("a size not saved keeps its default; a width of the side panel saved before is ignored", () => {
    const defaults = { rows: "*, 250dip" };
    assert.deepEqual(splittersOf({ searchPanelHeight: "" }, defaults), defaults);
    assert.deepEqual(splittersOf({ sidePanelWidth: "333dip" }, defaults), defaults);
    assert.deepEqual(splittersOf(null, defaults), defaults);
});

test("a panel saved collapsed starts collapsed and keeps the height it expands to", () => {
    const defaults = { rows: "*, 250dip" };
    assert.deepEqual(splittersOf({ searchPanelHeight: "177dip", bottomPanelCollapsed: true }, defaults),
        { rows: "1*,0dip", collapsed: true, searchPanelHeight: "177dip" });
    assert.deepEqual(splittersOf({ bottomPanelCollapsed: true }, defaults),
        { rows: "1*,0dip", collapsed: true, searchPanelHeight: "250dip" }, "no height saved: the default one");
    assert.deepEqual(splittersOf({ searchPanelHeight: "177dip", bottomPanelCollapsed: false }, defaults),
        { rows: "*,177dip" }, "expanded as before");
});

test("the rows of the frameset: collapsed to the tabs (the CSS keeps their height), or expanded", () => {
    assert.deepEqual(rowsOf("230dip", true), ["1*", "0dip"]);
    assert.deepEqual(rowsOf("230dip", false), ["1*", "230dip"]);
    assert.deepEqual(rowsOf(null, false), ["1*", "250dip"], "no height known: the default one");
});

test("a collapsed panel with no height known saves the default one, not the 0 of its row", () => {
    assert.deepEqual(panelSizesOf({ rows: "1*,0dip", collapsed: true }), { searchPanelHeight: "250dip", bottomPanelCollapsed: true });
});

test("the default splitter is the default height", () => {
    assert.equal(defaultRows, "*,250dip");
});

test("collapsing remembers the height measured; the rows go to 0 before the pages are hidden", () => {
    assert.deepEqual(collapseStep({ collapsed: false, expandedHeight: "180dip" }, true, "230dip"),
        { collapsed: true, expandedHeight: "230dip", rows: ["1*", "0dip"], rowsFirst: true });
});

test("expanding gives back the height remembered; the pages are shown before the rows get it", () => {
    assert.deepEqual(collapseStep({ collapsed: true, expandedHeight: "230dip" }, false, null),
        { collapsed: false, expandedHeight: "230dip", rows: ["1*", "230dip"], rowsFirst: false });
    assert.deepEqual(collapseStep({ collapsed: true, expandedHeight: null }, false, null).rows, ["1*", "250dip"],
        "none remembered: the default");
});

test("no step when the panel is as asked", () => {
    assert.equal(collapseStep({ collapsed: true, expandedHeight: "230dip" }, true, "28dip"), null);
    assert.equal(collapseStep({ collapsed: false, expandedHeight: null }, false, "230dip"), null);
});

test("no tab is active while the panel is collapsed", () => {
    assert.equal(activeTabOf({ collapsed: false, bottomPage: "filters" }), "filters");
    assert.equal(activeTabOf({ collapsed: true, bottomPage: "filters" }), null);
});
