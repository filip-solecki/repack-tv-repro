// Prints the top-level asset names inside a compiled Assets.car, one per line.
//   node tools/car-assets.mjs <path/to/Assets.car>
import {execFileSync} from "node:child_process";

const car = process.argv[2];
const raw = execFileSync("assetutil", ["--info", car], {encoding: "utf8", maxBuffer: 1 << 28});
const names = new Set();
for (const entry of JSON.parse(raw)) {
    const name = entry.Name;
    // Skip the per-layer children ("App Icon/Front/Content") and the catalog header.
    if (typeof name === "string" && !name.includes("/")) {
        names.add(name);
    }
}
console.log([...names].sort().join("\n"));
