#!/usr/bin/env bash
# Reproduces three @expo/repack-app issues on a minimal Apple TV project.
#
#   ./repro.sh
#   ./repro.sh --repack-version 0.11.0                             # verify a published fix
#   ./repro.sh --repack-version file:../repack-app/packages/repack-app
#   ./repro.sh --skip-build                                        # reuse the app built earlier
#
# Exit code 0 means every issue is fixed. Exit code 1 means at least one reproduces.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

REPACK_SPEC="@expo/repack-app@0.10.0"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repack-version)
            REPACK_SPEC="$2"
            [[ "$REPACK_SPEC" == *:* ]] || REPACK_SPEC="@expo/repack-app@$REPACK_SPEC"
            shift 2
            ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        *)
            echo "Usage: ./repro.sh [--repack-version <spec>] [--skip-build]" >&2
            exit 2
            ;;
    esac
done

FAILURES=0
report() { # $1 = ok|bug, $2 = issue number, $3 = title, $4 = detail
    if [[ "$1" == "bug" ]]; then
        printf '  [BUG]  %s  %-38s %s\n' "$2" "$3" "$4"
        FAILURES=$((FAILURES + 1))
    else
        printf '  [ OK]  %s  %-38s %s\n' "$2" "$3" "$4"
    fi
}

need() { command -v "$1" >/dev/null || { echo "Missing required tool: $1" >&2; exit 2; }; }
need xcodebuild
need assetutil
need plutil

echo "==> repack spec: $REPACK_SPEC"
[[ -d node_modules ]] || npm install
rm -rf .repack-tool
# --install-links copies a file: spec instead of symlinking it, so node can resolve the
# package's own dependencies. A file: spec also runs the package's prepare script (repack
# builds with bun), so fall back to skipping lifecycle scripts for an already-built copy.
if ! npm install --silent --no-save --install-links --prefix .repack-tool "$REPACK_SPEC" >/dev/null 2>&1; then
    echo "    prepare script failed, retrying with --ignore-scripts"
    npm install --silent --no-save --install-links --ignore-scripts --prefix .repack-tool "$REPACK_SPEC" >/dev/null
fi
REPACK_CLI=".repack-tool/node_modules/@expo/repack-app/bin/cli.js"
node "$REPACK_CLI" --version | sed 's/^/    installed version: /'
mkdir -p out

SRC_APP="ios/build/Build/Products/Debug-appletvsimulator/RepackTVRepro.app"
if [[ $SKIP_BUILD -eq 0 || ! -d "$SRC_APP" ]]; then
    echo "==> building the tvOS simulator app (no signing, no Apple account needed)"
    [[ -d ios/Pods ]] || (cd ios && pod install)
    (cd ios && xcodebuild -workspace RepackTVRepro.xcworkspace -scheme RepackTVRepro \
        -configuration Debug -sdk appletvsimulator -derivedDataPath build \
        -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO \
        >../out/xcodebuild.log 2>&1) || { tail -30 out/xcodebuild.log; exit 1; }
fi

echo "==> repacking $SRC_APP"
rm -rf out/repacked.app out/work
UNSTABLE_REPACK_APP_ICON=1 node "$REPACK_CLI" --platform ios \
    --source-app "$SRC_APP" --output out/repacked.app \
    -w out/work --skip-working-dir-cleanup . >out/repack.log 2>&1 \
    || { tail -30 out/repack.log; exit 1; }

# Read it from the repacked app: a fix has to make that plist point at an icon the new
# Assets.car actually contains. Reading the source app instead would keep reporting the
# bug even after repack starts writing the key.
primary_icon() {
    plutil -extract CFBundleIcons.CFBundlePrimaryIcon raw -o - "$1/Info.plist" 2>/dev/null \
        || plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles.0 raw -o - "$1/Info.plist"
}
SRC_PRIMARY="$(primary_icon "$SRC_APP")"
PRIMARY="$(primary_icon out/repacked.app)"
SRC_ASSETS="$(node tools/car-assets.mjs "$SRC_APP/Assets.car")"
OUT_ASSETS="$(node tools/car-assets.mjs out/repacked.app/Assets.car)"
DECLARED="$(sed -n 's/.*ASSETCATALOG_COMPILER_APPICON_NAME = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' \
    ios/*.xcodeproj/project.pbxproj | head -1)"

# Everything `npm test` asserts on, so the measuring lives in one place.
export R_SPEC="$REPACK_SPEC" R_DECLARED="$DECLARED" R_SRC_ICON="$SRC_PRIMARY" \
    R_OUT_ICON="$PRIMARY" R_SRC_ASSETS="$SRC_ASSETS" R_OUT_ASSETS="$OUT_ASSETS" \
    R_WARNINGS="$(grep -E '^(Multiple|The repacked app icon)' out/repack.log || true)"
node -e '
const list = (s) => (s ?? "").split("\n").filter(Boolean);
console.log(JSON.stringify({
    repackSpec: process.env.R_SPEC,
    declaredIconName: process.env.R_DECLARED,
    sourcePrimaryIcon: process.env.R_SRC_ICON,
    repackedPrimaryIcon: process.env.R_OUT_ICON,
    sourceAssets: list(process.env.R_SRC_ASSETS),
    repackedAssets: list(process.env.R_OUT_ASSETS),
    warnings: list(process.env.R_WARNINGS),
}, null, 2));
' >out/result.json

echo
echo "  icon name in the plist: source '$SRC_PRIMARY' -> repacked '$PRIMARY'"
echo "  assets in the source Assets.car:   $(echo "$SRC_ASSETS" | tr '\n' ',' | sed 's|,$||; s|,| |g')"
echo "  assets in the repacked Assets.car: $(echo "$OUT_ASSETS" | tr '\n' ',' | sed 's|,$||; s|,| |g')"
grep -E "^(Multiple|The repacked app icon)" out/repack.log | sed 's/^/  repack said: /' || true
echo

ICON_BROKEN=0
if echo "$OUT_ASSETS" | grep -qxF "$PRIMARY"; then
    report ok 1 "icon name matches Info.plist" "'$PRIMARY' is present"
else
    report bug 1 "icon name never written to plist" "plist wants '$PRIMARY', car has none"
    ICON_BROKEN=1
fi

if grep -q "Multiple .brandassets" out/repack.log; then
    report bug 2 "brand assets chosen by glob order" "see 'Multiple .brandassets' above"
else
    report ok 2 "brand assets chosen deterministically" "no glob warning"
fi

if echo "$SRC_ASSETS" | grep -qxF ExtraAsset && ! echo "$OUT_ASSETS" | grep -qxF ExtraAsset; then
    report bug 3 "second .xcassets dropped" "ExtraAsset lost from Assets.car"
else
    report ok 3 "all .xcassets compiled" "ExtraAsset survived"
fi

echo
echo "  Assert on it: npm test        (one test per issue, reads out/result.json)"
echo "  Look at it:   xcrun simctl install <tv-sim-udid> out/repacked.app"
if [[ $ICON_BROKEN -eq 1 ]]; then
    echo "  Expected the green REPACKED tile; issue 1 shows Apple's placeholder instead."
else
    echo "  Expect the green REPACKED tile."
fi

echo
if [[ $FAILURES -gt 0 ]]; then
    echo "==> $FAILURES issue(s) reproduce with $REPACK_SPEC"
    exit 1
fi
echo "==> no issues reproduce with $REPACK_SPEC"
