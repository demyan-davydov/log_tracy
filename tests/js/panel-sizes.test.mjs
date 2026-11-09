// The sizes of the side and search panels in the settings, see resources/panel-sizes.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { panelSizesOf, splittersOf } from "../../resources/panel-sizes.js";

test("the sizes of the panels are read from the splitters of a panel", () => {
    assert.deepEqual(panelSizesOf({ cols: "333dip,1*", rows: "1*,177dip" }),
        { sidePanelWidth: "333dip", searchPanelHeight: "177dip" });
    assert.deepEqual(panelSizesOf({ cols: "200dip, *", rows: "*, 250dip" }),
        { sidePanelWidth: "200dip", searchPanelHeight: "250dip" }, "spaces dropped");
});

test("the sizes measured on a panel win over its splitters", () => {
    // After a drag the frameset fixes the main table and leaves the search panel flexible
    assert.deepEqual(panelSizesOf({ cols: "422px,1*", rows: "512px,1*", sidePanelWidth: "422dip", searchPanelHeight: "230dip" }),
        { sidePanelWidth: "422dip", searchPanelHeight: "230dip" });
});

test("the splitters of a new panel are made of the sizes saved", () => {
    const defaults = { cols: "200dip, *", rows: "*, 250dip" };
    assert.deepEqual(splittersOf({ sidePanelWidth: "333dip", searchPanelHeight: "177dip" }, defaults),
        { cols: "333dip,*", rows: "*,177dip" });
});

test("a size not saved keeps its default", () => {
    const defaults = { cols: "200dip, *", rows: "*, 250dip" };
    assert.deepEqual(splittersOf({ sidePanelWidth: "333dip" }, defaults), { cols: "333dip,*", rows: "*, 250dip" });
    assert.deepEqual(splittersOf({ searchPanelHeight: "" }, defaults), defaults);
    assert.deepEqual(splittersOf(null, defaults), defaults);
});
