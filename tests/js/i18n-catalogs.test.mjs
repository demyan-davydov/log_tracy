// The catalogs of resources/i18n/translations against the texts of the code: scripts/utils/i18n-extract
// was run after the texts changed, and the translations keep the parameters of the source.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { scanSources, loadCatalogs, checkCatalog } from "../../scripts/utils/i18n-extract.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const { texts, errors } = scanSources(root);

test("every tr, trc and trn of the code has a literal text", () => {
    assert.deepEqual(errors.map((e) => `${e.file}:${e.line}: ${e.call}`), []);
});

test("there is a russian catalog", () => {
    assert.ok(loadCatalogs(root).some(({ catalog }) => catalog.locale === "ru"));
});

for (const { file, catalog } of loadCatalogs(root)) {
    test(`${file} is up to the code (run node scripts/utils/i18n-extract.mjs)`, () => {
        assert.deepEqual(checkCatalog(catalog, texts), []);
    });
}
