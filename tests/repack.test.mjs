// Asserts on out/result.json, which ./repro.sh writes. Run the repro first:
//
//   ./repro.sh --repack-version file:../repack-app/packages/repack-app
//   npm test
//
// One test per reported issue. All three pass = all three are fixed.
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import path from "node:path";
import {before, describe, it} from "node:test";

const RESULT = path.join(import.meta.dirname, "..", "out", "result.json");

let result;
before(() => {
    try {
        result = JSON.parse(readFileSync(RESULT, "utf8"));
    } catch {
        throw new Error(`${RESULT} is missing — run ./repro.sh first`);
    }
    console.log(`  repack spec under test: ${result.repackSpec}`);
});

describe("@expo/repack-app TV icon repacking", () => {
    it("1. the icon the Info.plist points at exists in the repacked Assets.car", () => {
        assert.ok(
            result.repackedAssets.includes(result.repackedPrimaryIcon),
            `Info.plist asks for "${result.repackedPrimaryIcon}", but the repacked car holds ` +
                `[${result.repackedAssets.join(", ")}]. tvOS has no fallback, so the app shows ` +
                `Apple's placeholder tile.`
        );
    });

    it("2. the brand asset set named by ASSETCATALOG_COMPILER_APPICON_NAME is the one compiled", () => {
        // That set holds "App Icon"; config-tv's TVAppIcon holds "App Icon - Small".
        assert.ok(
            result.repackedAssets.includes("App Icon"),
            `The project declares "${result.declaredIconName}", whose primary icon is ` +
                `"App Icon", but the repacked car holds [${result.repackedAssets.join(", ")}] — ` +
                `the other .brandassets won because the choice comes from glob order.`
        );
    });

    it("3. assets from every .xcassets survive the repack", () => {
        assert.ok(
            result.sourceAssets.includes("ExtraAsset"),
            "the source app should carry ExtraAsset — rebuild it with ./repro.sh"
        );
        assert.ok(
            result.repackedAssets.includes("ExtraAsset"),
            "ExtraAsset lives in the project's second .xcassets. Xcode compiled it into the " +
                "source app, the repack dropped it: only the first **/*.xcassets is compiled."
        );
    });
});
