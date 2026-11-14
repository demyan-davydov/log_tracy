// Makes the icons of the program from its logo, resources/icons/logo.png (square, 1024 px):
// png/icon-<size>.png of every size, app.ico (Windows, built in by resources/app.rc),
// app.icns (the macOS bundle) and app.png (Linux, the .deb). Run it on macOS after the logo
// changes and commit what it writes: it resizes with sips and packs the .icns with iconutil.
// Run: node scripts/utils/make-icons.mjs. Tests: tests/js/make-icons-script.test.mjs.
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/// The sizes of the PNGs: the small ones of Windows and Linux up to the 1024 of macOS.
export const pngSizes = [16, 24, 32, 48, 64, 128, 256, 512, 1024];

/// The sizes packed into app.ico: what Windows shows, from the title bar to the large icons.
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

/// The images of an .iconset for iconutil: its name and its size in pixels.
export const iconsetNames = [16, 32, 128, 256, 512].flatMap((size) =>
    [[`icon_${size}x${size}.png`, size], [`icon_${size}x${size}@2x.png`, size * 2]]);

/// An .ico of PNG images (`[{ size, png }]`, Windows Vista and newer read them): the header,
/// an entry of 16 bytes per image, then the images as they are.
export function icoFile(images) {
    const header = Buffer.alloc(6);
    header.writeUInt16LE(0, 0); // reserved
    header.writeUInt16LE(1, 2); // an icon
    header.writeUInt16LE(images.length, 4);
    let offset = header.length + 16 * images.length;
    const entries = images.map(({ size, png }) => {
        const entry = Buffer.alloc(16);
        entry[0] = size >= 256 ? 0 : size; // 0 stands for 256
        entry[1] = size >= 256 ? 0 : size;
        entry[2] = 0; // no palette
        entry[3] = 0; // reserved
        entry.writeUInt16LE(1, 4); // planes
        entry.writeUInt16LE(32, 6); // bits per pixel
        entry.writeUInt32LE(png.length, 8);
        entry.writeUInt32LE(offset, 12);
        offset += png.length;
        return entry;
    });
    return Buffer.concat([header, ...entries, ...images.map(({ png }) => png)]);
}

function runOrFail(program, args) {
    const result = spawnSync(program, args, { encoding: "utf8" });
    if (result.error || result.status !== 0)
        throw new Error(`${program} ${args.join(" ")} failed: ${result.error?.message ?? result.stderr}`);
    return result.stdout;
}

/// Writes `source` resized to `size` × `size` into `out`.
function resize(source, size, out) {
    runOrFail("sips", ["-z", String(size), String(size), source, "--out", out]);
}

function main() {
    if (process.platform !== "darwin") throw new Error("the icons are made on macOS (sips, iconutil)");
    const dir = resolve(fileURLToPath(new URL("../../resources/icons", import.meta.url)));
    const logo = join(dir, "logo.png");
    const dimensions = runOrFail("sips", ["-g", "pixelWidth", "-g", "pixelHeight", logo]);
    const [width, height] = [/pixelWidth: (\d+)/, /pixelHeight: (\d+)/].map((r) => Number(dimensions.match(r)?.[1]));
    if (width !== height || width < 1024) throw new Error(`${logo} is ${width}×${height}: a square of 1024 px or more is needed`);

    const png = join(dir, "png");
    rmSync(png, { recursive: true, force: true });
    mkdirSync(png, { recursive: true });
    const pngOf = (size) => join(png, `icon-${size}.png`);
    for (const size of pngSizes) resize(logo, size, pngOf(size));

    writeFileSync(join(dir, "app.ico"), icoFile(icoSizes.map((size) => ({ size, png: readFileSync(pngOf(size)) }))));

    const work = mkdtempSync(join(tmpdir(), "log-tracy-icons-"));
    try {
        const iconset = join(work, "app.iconset");
        mkdirSync(iconset);
        for (const [name, size] of iconsetNames) copyFileSync(pngOf(size), join(iconset, name));
        runOrFail("iconutil", ["--convert", "icns", "--output", join(dir, "app.icns"), iconset]);
    } finally {
        rmSync(work, { recursive: true, force: true });
    }

    copyFileSync(pngOf(512), join(dir, "app.png")); // Linux scales it for the menus and the dock
    console.log(`Icons made in ${dir}`);
}

// run, not imported (by the tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    try {
        main();
    } catch (e) {
        console.error(e.message);
        process.exit(1);
    }
}
