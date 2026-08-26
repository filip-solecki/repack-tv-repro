#!/usr/bin/env bash
# Reproduces four @expo/repack-app issues on a minimal TV project.
#
#   ./repro.sh ios
#   ./repro.sh android
#   ./repro.sh ios --repack-version 0.11.0            # verify a published fix
#   ./repro.sh ios --repack-version file:../repack-app/packages/repack-app
#
# Exit code 0 means every issue is fixed. Exit code 1 means at least one reproduces.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PLATFORM="${1:-}"
shift || true
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
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "android" ]]; then
    echo "Usage: ./repro.sh <ios|android> [--repack-version <spec>] [--skip-build]" >&2
    exit 2
fi

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

if [[ "$PLATFORM" == "ios" ]]; then
    need xcodebuild; need assetutil; need plutil
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
        -w out/work --skip-working-dir-cleanup . >out/repack-ios.log 2>&1 \
        || { tail -30 out/repack-ios.log; exit 1; }

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

    echo
    echo "  icon name in the plist: source '$SRC_PRIMARY' -> repacked '$PRIMARY'"
    echo "  assets in the source Assets.car:   $(echo "$SRC_ASSETS" | tr '\n' ',' | sed 's|,$||; s|,| |g')"
    echo "  assets in the repacked Assets.car: $(echo "$OUT_ASSETS" | tr '\n' ',' | sed 's|,$||; s|,| |g')"
    grep -E "^(Multiple|The repacked app icon)" out/repack-ios.log | sed 's/^/  repack said: /' || true
    echo

    ICON_BROKEN=0
    if echo "$OUT_ASSETS" | grep -qxF "$PRIMARY"; then
        report ok 1 "icon name matches Info.plist" "'$PRIMARY' is present"
    else
        report bug 1 "icon name never written to plist" "plist wants '$PRIMARY', car has none"
        ICON_BROKEN=1
    fi

    if grep -q "Multiple .brandassets" out/repack-ios.log; then
        report bug 2 "brand assets chosen by glob order" "see 'Multiple .brandassets' above"
    else
        report ok 2 "brand assets chosen deterministically" "no glob warning"
    fi

    if echo "$SRC_ASSETS" | grep -qxF ExtraAsset && ! echo "$OUT_ASSETS" | grep -qxF ExtraAsset; then
        report bug 4 "second .xcassets dropped" "ExtraAsset lost from Assets.car"
    else
        report ok 4 "all .xcassets compiled" "ExtraAsset survived"
    fi

    echo
    echo "  Look at it: xcrun simctl install <tv-sim-udid> out/repacked.app"
    if [[ $ICON_BROKEN -eq 1 ]]; then
        echo "  Expected the green REPACKED tile; issue 1 shows Apple's placeholder instead."
    else
        echo "  Expect the green REPACKED tile."
    fi
else
    need java
    # repack shells out to the Android build tools and asserts on this variable.
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    AAPT="$(ls -d "$ANDROID_SDK_ROOT"/build-tools/* | sort -V | tail -1)/aapt2"
    [[ -x "$AAPT" ]] || { echo "aapt2 not found under ANDROID_HOME" >&2; exit 2; }
    SRC_APK="android/app/build/outputs/apk/debug/app-debug.apk"
    if [[ $SKIP_BUILD -eq 0 || ! -f "$SRC_APK" ]]; then
        echo "==> building the Android TV debug APK"
        (cd android && ./gradlew --quiet assembleDebug)
    fi

    echo "==> repacking $SRC_APK"
    KEYSTORE=".repack-tool/node_modules/@expo/repack-app/dist/debug.keystore"
    rm -rf out/repacked.apk out/work-android
    UNSTABLE_REPACK_APP_ICON=1 node "$REPACK_CLI" --platform android \
        --source-app "$SRC_APK" --output out/repacked.apk \
        --ks "$KEYSTORE" --ks-pass pass:android --ks-key-alias androiddebugkey \
        --ks-key-pass pass:android \
        -w out/work-android --skip-working-dir-cleanup . >out/repack-android.log 2>&1 \
        || { tail -30 out/repack-android.log; exit 1; }

    vcode() { "$AAPT" dump badging "$1" | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1; }
    banner() { # resolves the android:banner resource id to its resource name
        local id
        id="$("$AAPT" dump xmltree "$1" --file AndroidManifest.xml | sed -n 's/.*android:banner([^)]*)=@\(0x[0-9a-f]*\).*/\1/p' | head -1)"
        "$AAPT" dump resources "$1" | sed -n "s/ *resource $id \([^ ]*\).*/\1/p" | head -1
    }
    SRC_VC="$(vcode "$SRC_APK")"
    OUT_VC="$(vcode out/repacked.apk)"

    echo
    echo "  versionCode: source $SRC_VC -> repacked $OUT_VC"
    echo "  android:banner: source $(banner "$SRC_APK") -> repacked $(banner out/repacked.apk)"
    echo

    if [[ "$OUT_VC" -lt "$SRC_VC" ]]; then
        report bug 3 "versionCode reset to $OUT_VC" "source had $SRC_VC, cannot install as an update"
    else
        report ok 3 "versionCode preserved" "$OUT_VC"
    fi
    report ok - "banner swap (works today)" "$(banner out/repacked.apk)"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
    echo "==> $FAILURES issue(s) reproduce with $REPACK_SPEC"
    exit 1
fi
echo "==> all checked issues are fixed with $REPACK_SPEC"
