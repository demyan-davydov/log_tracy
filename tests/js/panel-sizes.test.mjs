// The size of the bottom (search) panel in the settings, see resources/panel-sizes.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { panelSizesOf, splittersOf } from "../../resources/panel-sizes.js";

test("the size of the panel is read from the splitter of a panel", () => {
    assert.deepEqual(panelSizesOf({ rows: "1*,177dip" }), { searchPanelHeight: "177dip" });
    assert.deepEqual(panelSizesOf({ rows: "*, 250dip" }), { searchPanelHeight: "250dip" }, "spaces dropped");
});

test("the size measured on a panel wins over its splitter", () => {
    // After a drag the frameset fixes the main table and leaves the search panel flexible
    assert.deepEqual(panelSizesOf({ rows: "512px,1*", searchPanelHeight: "230dip" }), { searchPanelHeight: "230dip" });
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
