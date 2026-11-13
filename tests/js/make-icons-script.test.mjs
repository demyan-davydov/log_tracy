// The pure part of scripts/make-icons.mjs: the sizes made and the .ico packed of PNGs.
// Run: node --test "tests/js/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { icoFile, iconsetNames, pngSizes } from "../../scripts/make-icons.mjs";

test("the PNGs: the small sizes of Windows and Linux up to the 1024 of macOS", () => {
    assert.deepEqual(pngSizes, [16, 24, 32, 48, 64, 128, 256, 512, 1024]);
});

test("the .ico: a header, an entry per image, then the PNGs as they are", () => {
    const small = Buffer.from("png-16"), big = Buffer.from("png-256!");
    const ico = icoFile([{ size: 16, png: small }, { size: 256, png: big }]);
    assert.equal(ico.readUInt16LE(0), 0, "reserved");
    assert.equal(ico.readUInt16LE(2), 1, "an icon, not a cursor");
    assert.equal(ico.readUInt16LE(4), 2, "two images");
    const entry = (i) => 6 + 16 * i;
    assert.equal(ico[entry(0)], 16, "the width");
    assert.equal(ico[entry(0) + 1], 16, "the height");
    assert.equal(ico[entry(1)], 0, "256 is written as 0");
    assert.equal(ico.readUInt16LE(entry(0) + 4), 1, "planes");
    assert.equal(ico.readUInt16LE(entry(0) + 6), 32, "bits per pixel");
    assert.equal(ico.readUInt32LE(entry(0) + 8), small.length);
    const first = ico.readUInt32LE(entry(0) + 12), second = ico.readUInt32LE(entry(1) + 12);
    assert.equal(first, 6 + 16 * 2, "the images right after the entries");
    assert.equal(second, first + small.length);
    assert.deepEqual(ico.subarray(first, first + small.length), small);
    assert.deepEqual(ico.subarray(second), big);
});

test("the iconset of macOS: each size at 1x and 2x, named as iconutil wants", () => {
    assert.deepEqual(iconsetNames, [
        ["icon_16x16.png", 16], ["icon_16x16@2x.png", 32], ["icon_32x32.png", 32], ["icon_32x32@2x.png", 64],
        ["icon_128x128.png", 128], ["icon_128x128@2x.png", 256], ["icon_256x256.png", 256],
        ["icon_256x256@2x.png", 512], ["icon_512x512.png", 512], ["icon_512x512@2x.png", 1024]]);
});
