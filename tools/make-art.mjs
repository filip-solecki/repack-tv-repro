// Regenerates the placeholder art. The output PNGs are committed, so you never need to
// run this to reproduce the issues — it is here so the art is not a mystery blob.
//   npm run art
import {mkdir} from "node:fs/promises";
import path from "node:path";

import sharp from "sharp";

const ROOT = path.join(import.meta.dirname, "..");

const SETS = {
    // Art committed into ios/ and android/, i.e. what a native build shows.
    native: {dir: "assets/tv/native", bg: "#1f4e8c", label: "NATIVE"},
    // Art referenced from app.config.js, i.e. what a repack is supposed to inject.
    repacked: {dir: "assets/tv/repacked", bg: "#1d7a3c", label: "REPACKED"},
};

const SIZES = [
    ["icon-400x240", 400, 240],
    ["icon-800x480", 800, 480],
    ["icon-1280x768", 1280, 768],
    ["top-shelf-1920x720", 1920, 720],
    ["top-shelf-3840x1440", 3840, 1440],
    ["top-shelf-wide-2320x720", 2320, 720],
    ["top-shelf-wide-4640x1440", 4640, 1440],
];

function tile(width, height, {bg, label}) {
    const title = Math.round(height * 0.22);
    const sub = Math.round(height * 0.09);
    return Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">` +
            `<rect width="${width}" height="${height}" fill="${bg}"/>` +
            `<text x="50%" y="46%" fill="#ffffff" font-family="Helvetica Neue, Helvetica, Arial" ` +
            `font-weight="bold" font-size="${title}" text-anchor="middle">${label}</text>` +
            `<text x="50%" y="68%" fill="#ffffffaa" font-family="Helvetica Neue, Helvetica, Arial" ` +
            `font-size="${sub}" text-anchor="middle">${width}x${height}</text>` +
            `</svg>`
    );
}

for (const set of Object.values(SETS)) {
    const outDir = path.join(ROOT, set.dir);
    await mkdir(outDir, {recursive: true});
    for (const [name, width, height] of SIZES) {
        await sharp(tile(width, height, set))
            .png({compressionLevel: 9, effort: 10})
            .toFile(path.join(outDir, `${name}.png`));
    }
    console.log(`${set.label} -> ${set.dir} (${SIZES.length} files)`);
}
