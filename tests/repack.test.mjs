// Asserts on out/result.json, which ./repro.sh writes. Run the repro first:
//
//   ./repro.sh --repack-version file:../repack-app/packages/repack-app
//   npm test
//
// One test per reported issue. All three pass = all three are fixed.
import assert from "node:assert/strict";
import {existsSync, readFileSync} from "node:fs";
import path from "node:path";
import {describe, it} from "node:test";

const RESULT = path.join(import.meta.dirname, "..", "out", "result.json");

// Bail out before the runner starts: throwing inside a hook would cancel every test and
// bury this line under stack traces.
if (!existsSync(RESULT)) {
    console.error("out/result.json is missing. Run ./repro.sh first, then npm test.");
    process.exit(1);
}

const result = JSON.parse(readFileSync(RESULT, "utf8"));
console.log(`repack spec under test: ${result.repackSpec}\n`);

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
