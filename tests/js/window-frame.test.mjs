// The frame of the window restored from the settings, see resources/window-frame.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { restorableFrame } from "../../resources/window-frame.js";

const monitor = { left: 0, top: 0, width: 1920, height: 1080 };
const right = { left: 1920, top: 0, width: 1280, height: 1024 };

test("a frame on a monitor is restored as it is", () => {
    const frame = { left: 200, top: 150, width: 900, height: 600 };
    assert.deepEqual(restorableFrame(frame, [monitor]), frame);
    const onRight = { left: 2000, top: 100, width: 800, height: 600 };
    assert.deepEqual(restorableFrame(onRight, [monitor, right]), onRight);
});

test("no frame saved or an empty one: the window stays as the markup makes it", () => {
    assert.equal(restorableFrame(null, [monitor]), null);
    assert.equal(restorableFrame(undefined, [monitor]), null);
    assert.equal(restorableFrame({ left: 0, top: 0, width: 0, height: 0 }, [monitor]), null);
});

test("a frame on a monitor no longer there is not restored", () => {
    assert.equal(restorableFrame({ left: 2000, top: 100, width: 800, height: 600 }, [monitor]), null);
});

test("a frame that shows only a sliver on the monitors is not restored", () => {
    // 20 px of it visible: too little to catch it by the title bar
    assert.equal(restorableFrame({ left: 1900, top: 100, width: 800, height: 600 }, [monitor]), null);
    assert.equal(restorableFrame({ left: 100, top: 1070, width: 800, height: 600 }, [monitor]), null);
});

test("a frame partly off the monitor but well within reach is restored", () => {
    const frame = { left: -300, top: 100, width: 800, height: 600 };
    assert.deepEqual(restorableFrame(frame, [monitor]), frame);
});
