// scripts/utils/prepare-sciter.mjs: puts the Sciter library of a build in place before dub
// copies it (preGenerateCommands of dub.sdl).
// Run: node --test "tests/js/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { archOfDub, pickArch } from "../../scripts/utils/prepare-sciter.mjs";

test("the architecture of dub's build is the first word of what it tells, named as build.mjs names it", () => {
    assert.equal(archOfDub("x86_64"), "x64");
    assert.equal(archOfDub("aarch64"), "arm64");
    assert.equal(archOfDub("aarch64 arm_hardfloat"), "arm64"); // dub adds the features of the target
});

test("an architecture without a library is no architecture: dub tells the rest", () => {
    assert.equal(archOfDub("x86"), null);
    assert.equal(archOfDub(""), null);
    assert.equal(archOfDub(undefined), null);
});

test("the architecture is the one asked by --arch, else dub's, else this machine's", () => {
    assert.equal(pickArch(["--arch", "x64"], { DUB_ARCH: "aarch64" }, "arm64"), "x64");
    assert.equal(pickArch([], { DUB_ARCH: "aarch64 arm_hardfloat" }, "x64"), "arm64");
    assert.equal(pickArch([], {}, "x64"), "x64");
    assert.equal(pickArch([], { DUB_ARCH: "" }, "arm64"), "arm64"); // dub told nothing
});

test("an architecture dub tells that has no library is none: dub tells the rest", () => {
    assert.equal(pickArch([], { DUB_ARCH: "x86" }, "arm64"), null);
});
