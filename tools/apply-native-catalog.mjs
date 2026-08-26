// Turns a vanilla `expo prebuild` result into what a project with a hand-made Xcode TV
// target looks like. The committed ios/ already contains the result, so you
// only need this after `expo prebuild --clean`.
//   npm run native-catalog
//
// Three deviations from the prebuild output, each one the trigger for one issue:
//   1. brand assets named the way Xcode names them ("App Icon & Top Shelf Image", with an
//      "App Icon" image stack inside) instead of config-tv's "TVAppIcon"
//   2. ASSETCATALOG_COMPILER_APPICON_NAME + Info.plist CFBundleIcons pointing at it
//   3. a second asset catalog (Extra.xcassets)
import {execFileSync} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdir, readdir, readFile, rm, writeFile} from "node:fs/promises";
import path from "node:path";

import sharp from "sharp";

const ROOT = path.join(import.meta.dirname, "..");
const NATIVE_ART = path.join(ROOT, "assets/tv/native");
const APPICON_NAME = "App Icon & Top Shelf Image";

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;
const info = {author: "xcode", version: 1};

async function iosProjectDir() {
    const iosDir = path.join(ROOT, "ios");
    for (const entry of await readdir(iosDir, {withFileTypes: true})) {
        if (entry.isDirectory() && existsSync(path.join(iosDir, entry.name, "Info.plist"))) {
            return path.join(iosDir, entry.name);
        }
    }
    throw new Error("No ios/<project>/Info.plist found — run `npm run prebuild` first.");
}

async function writeImageSet(dir, images) {
    await mkdir(dir, {recursive: true});
    const entries = [];
    for (const [file, scale] of images) {
        await sharp(path.join(NATIVE_ART, file)).toFile(path.join(dir, file));
        entries.push({filename: file, idiom: "tv", ...(scale ? {scale} : {})});
    }
    await writeFile(path.join(dir, "Contents.json"), json({images: entries, info}));
}

async function writeImageStack(dir, images) {
    await mkdir(dir, {recursive: true});
    await writeFile(
        path.join(dir, "Contents.json"),
        json({
            layers: [
                {filename: "Front.imagestacklayer"},
                {filename: "Middle.imagestacklayer"},
                {filename: "Back.imagestacklayer"},
            ],
            info,
        })
    );
    for (const layer of ["Front", "Middle", "Back"]) {
        const layerDir = path.join(dir, `${layer}.imagestacklayer`);
        await mkdir(layerDir, {recursive: true});
        await writeFile(path.join(layerDir, "Contents.json"), json({info}));
        // Xcode leaves the middle layer empty unless you fill it in.
        if (layer !== "Middle") {
            await writeImageSet(path.join(layerDir, "Content.imageset"), images);
        }
    }
}

async function buildBrandAssets(catalog) {
    const brand = path.join(catalog, `${APPICON_NAME}.brandassets`);
    await rm(brand, {recursive: true, force: true});
    await writeImageStack(path.join(brand, "App Icon.imagestack"), [
        ["icon-400x240.png", "1x"],
        ["icon-800x480.png", "2x"],
    ]);
    await writeImageStack(path.join(brand, "App Icon - App Store.imagestack"), [
        ["icon-1280x768.png", "1x"],
    ]);
    await writeImageSet(path.join(brand, "Top Shelf Image.imageset"), [
        ["top-shelf-1920x720.png", "1x"],
        ["top-shelf-3840x1440.png", "2x"],
    ]);
    await writeImageSet(path.join(brand, "Top Shelf Image Wide.imageset"), [
        ["top-shelf-wide-2320x720.png", "1x"],
        ["top-shelf-wide-4640x1440.png", "2x"],
    ]);
    await writeFile(
        path.join(brand, "Contents.json"),
        json({
            assets: [
                {
                    filename: "App Icon - App Store.imagestack",
                    idiom: "tv",
                    role: "primary-app-icon",
                    size: "1280x768",
                },
                {
                    filename: "App Icon.imagestack",
                    idiom: "tv",
                    role: "primary-app-icon",
                    size: "400x240",
                },
                {
                    filename: "Top Shelf Image Wide.imageset",
                    idiom: "tv",
                    role: "top-shelf-image-wide",
                    size: "2320x720",
                },
                {
                    filename: "Top Shelf Image.imageset",
                    idiom: "tv",
                    role: "top-shelf-image",
                    size: "1920x720",
                },
            ],
            info,
        })
    );
}

// A second catalog, registered in the Xcode project so the real build compiles it.
// Repack compiles only the first catalog it finds, so this asset is the canary for issue 3.
async function buildExtraCatalog(projectDir) {
    const catalog = path.join(projectDir, "Extra.xcassets");
    const set = path.join(catalog, "ExtraAsset.imageset");
    await mkdir(set, {recursive: true});
    await writeFile(path.join(catalog, "Contents.json"), json({info}));
    await sharp({
        create: {width: 64, height: 64, channels: 4, background: "#c81e1e"},
    })
        .png()
        .toFile(path.join(set, "extra-asset.png"));
    await writeFile(
        path.join(set, "Contents.json"),
        json({
            images: [{filename: "extra-asset.png", idiom: "universal", scale: "1x"}],
            info,
        })
    );
    await registerInXcodeProject(projectDir, catalog);
}

async function registerInXcodeProject(projectDir, catalog) {
    const mod = await import("@expo/config-plugins");
    const {IOSConfig} = mod.default ?? mod;
    const project = IOSConfig.XcodeUtils.getPbxproj(ROOT);
    const groupName = path.basename(projectDir);
    const relative = path.relative(path.join(ROOT, "ios"), catalog);
    if (project.hasFile(relative)) {
        return;
    }
    IOSConfig.XcodeUtils.addResourceFileToGroup({
        filepath: relative,
        groupName,
        project,
        isBuildFile: true,
        verbose: false,
    });
    await writeFile(project.filepath, project.writeSync());
}

async function patchPbxproj() {
    const iosDir = path.join(ROOT, "ios");
    const projects = (await readdir(iosDir)).filter((name) => name.endsWith(".xcodeproj"));
    for (const project of projects) {
        const file = path.join(iosDir, project, "project.pbxproj");
        const before = await readFile(file, "utf8");
        const after = before.replace(
            /ASSETCATALOG_COMPILER_APPICON_NAME = [^;]+;/g,
            `ASSETCATALOG_COMPILER_APPICON_NAME = "${APPICON_NAME}";`
        );
        if (before !== after) {
            await writeFile(file, after);
        }
        console.log(`  pbxproj: ASSETCATALOG_COMPILER_APPICON_NAME = "${APPICON_NAME}"`);
    }
}

// Xcode writes this key for a hand-made target; config-tv/prebuild does not.
function patchInfoPlist(projectDir) {
    const plist = path.join(projectDir, "Info.plist");
    try {
        execFileSync("plutil", ["-remove", "CFBundleIcons", plist], {stdio: "ignore"});
    } catch {
        // Key absent on a fresh prebuild — nothing to remove.
    }
    execFileSync("plutil", [
        "-insert",
        "CFBundleIcons",
        "-xml",
        "<dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>" +
            "<array><string>App Icon</string></array></dict></dict>",
        plist,
    ]);
    console.log('  Info.plist: CFBundleIcons -> CFBundleIconFiles ["App Icon"]');
}

const projectDir = await iosProjectDir();
const catalog = path.join(projectDir, "Images.xcassets");
console.log(`Patching ${path.relative(ROOT, projectDir)}`);
await rm(path.join(catalog, "TVAppIcon.brandassets"), {recursive: true, force: true});
await buildBrandAssets(catalog);
console.log(`  catalog: ${APPICON_NAME}.brandassets (TVAppIcon.brandassets removed)`);
await buildExtraCatalog(projectDir);
console.log("  catalog: Extra.xcassets/ExtraAsset.imageset");
await patchPbxproj();
patchInfoPlist(projectDir);
console.log("Done.");
