# repack-tv-repro

Minimal reproduction for three `@expo/repack-app` issues that hit Apple TV apps with a
committed native directory. Everything runs locally: **no Apple account, no signing, no
EAS** — a tvOS simulator build is enough.

## Run it

You need Xcode with a tvOS simulator runtime, CocoaPods and Node 20+. Dependencies install
themselves on the first run.

```bash
./repro.sh
```

Around 9 minutes the first time (`npm install`, `pod install`, one `xcodebuild`); seconds
afterwards with `--skip-build`. It prints a `[BUG]` / `[ OK]` line per issue, quotes the
three warnings repack emits, and exits non-zero while anything reproduces.

Then look at the icon. Install the source app first:

```bash
SIM=$(xcrun simctl list devices available | grep -m1 "Apple TV" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')
xcrun simctl boot $SIM || true          # fine if it says already booted
open -a Simulator

xcrun simctl install $SIM ios/build/Build/Products/Debug-appletvsimulator/RepackTVRepro.app
xcrun simctl spawn $SIM launchctl stop com.apple.SpringBoard   # refreshes the dock
```

The dock shows the blue **NATIVE** tile. Now the repacked one, same bundle id, so it
replaces it:

```bash
xcrun simctl uninstall $SIM dev.repro.repacktv
xcrun simctl install $SIM out/repacked.app
xcrun simctl spawn $SIM launchctl stop com.apple.SpringBoard
```

It should be the green **REPACKED** tile. It is Apple's placeholder instead — that is issue
1. One key in the plist brings the icon back, with nothing else changed:

```bash
plutil -replace CFBundleIcons.CFBundlePrimaryIcon -string "App Icon - Small" \
  out/repacked.app/Info.plist
xcrun simctl uninstall $SIM dev.repro.repacktv
xcrun simctl install $SIM out/repacked.app
xcrun simctl spawn $SIM launchctl stop com.apple.SpringBoard
```

### Verifying a fix

```bash
./repro.sh --repack-version 0.11.0
./repro.sh --repack-version file:../repack-app/packages/repack-app
./repro.sh --skip-build                # reuse the app built earlier
```

All checks green and exit code 0 mean everything here is fixed. A `file:` spec is copied,
not symlinked, and its `prepare` script runs — so a source checkout builds the way you
normally build it, and an already-built directory installs too (the script retries with
`--ignore-scripts`).

Checked in both directions: against 0.10.0 issue 1 reports `[BUG]`, and against a local copy
patched to write `CFBundlePrimaryIcon` it reports `[ OK]` and the repacked app renders the
green tile with no manual plist edit.

Verified with `@expo/repack-app@0.10.0`, `expo@56.0.20`,
`react-native@npm:react-native-tvos@0.85.3-3`, `@react-native-tvos/config-tv@0.1.6`,
Xcode 26.6 and the tvOS 26.5 simulator.

## What already works

Credit where due: on 0.10.0 the TV icon pipeline itself works. Repack detects the TV target
from `UIDeviceFamily`, runs its internal prebuild with `EXPO_TV=1`, and compiles the tvOS
brand assets with `--platform appletvos --target-device tv`. The new art really does end up
in the repacked `Assets.car`. The three issues below are what stops us shipping it.

## The issues

| # | What happens | Consequence | Since |
|---|---|---|---|
| 1 | The repacked `Assets.car` holds `App Icon - Small`, but the app's `Info.plist` still asks for `App Icon` | tvOS finds no icon and has no fallback, so the app shows Apple's placeholder tile | never written in any version; 0.10.0 warns about it |
| 2 | The brand assets to compile are picked with the first `*.brandassets` glob hit | the build setting that names the icon is ignored, and with more than one set present the choice comes from filesystem order | new in 0.10.0 |
| 3 | Only the first `**/*.xcassets` is compiled | every other asset catalog silently disappears from the binary | unchanged since 0.4.2 |

None of this is documented as a limitation: the README's TV section covers detection and the
config-tv options, and says nothing about asset catalog names, `Info.plist` icon keys, or a
one-catalog limit.

### 1. The icon name is never written to `Info.plist`

Repack already rewrites `CFBundleDisplayName`, `CFBundleIdentifier`, the versions and the
URL schemes. It replaces the icon payload but leaves the pointer to it untouched, and it
already knows the correct value: 0.10.0 parses the `actool` partial plist and warns about
exactly this mismatch.

```
The repacked app icon is named 'App Icon - Small' but the app Info.plist references
'App Icon'. The TV icon may not be used at runtime.
```

Writing that name into `Info.plist` (the way `CFBundleDisplayName` is already handled)
would make the swap work for any naming, with no change required in the app project.

Source app, and the same app after a repack:

| source app | after a repack | after patching one plist key |
|---|---|---|
| ![source](docs/tvos-1-source-native-icon.png) | ![repacked](docs/tvos-2-after-repack-placeholder.png) | ![patched](docs/tvos-3-plist-patched-works.png) |

The blue `NATIVE` tile is the art committed in `ios/`. The repack was supposed to replace
it with the green `REPACKED` tile from `app.config.js` — the art *is* in the new
`Assets.car`, under a name nothing points at.

The third screenshot is the same repacked app with only `CFBundlePrimaryIcon` changed (the
`plutil` step under [Run it](#run-it)). So the swap itself is already correct; only the
pointer is missing.

This does not show up on a pure CNG project, where prebuild owns both sides and the names
happen to agree. It shows up on every project with a committed `ios/`, which is the case
repack exists for.

### 2. Brand assets are chosen by glob order

```
Multiple .brandassets directories found. Trying to use the first one.
```

After the prebuild output is layered onto the project's catalog there are two
`*.brandassets`, and the first glob hit wins. The project states which one it wants in
`ASSETCATALOG_COMPILER_APPICON_NAME` (here: `App Icon & Top Shelf Image`), and that setting
is not consulted. Reading it — or the primary icon name from the source app's plist — would
make the choice deterministic and would also fix issue 1.

It also blocks per-build-configuration icons, which is how the same app ships different
iPhone icons today: with three committed brand asset sets, a repack becomes a coin flip.

### 3. Non-first asset catalogs are dropped

```
Multiple .xcassets directories found. Trying to use the first one.
```

`Extra.xcassets/ExtraAsset` is in the source app's `Assets.car` and gone from the repacked
one — Xcode compiled both catalogs, the repack kept one. Real apps split colours, launch
images and app assets across catalogs; today each of those silently loses whatever is not in
the first one.

`actool` takes several catalogs in one invocation, so passing all of them is enough. Checked
against the two catalogs in this project:

```bash
actool A.xcassets B.xcassets --compile out --app-icon "App Icon & Top Shelf Image" \
  --include-all-app-icons --target-device tv --platform appletvos \
  --minimum-deployment-target 15.1 --notices --warnings
# 0 errors, 0 warnings; the car holds App Icon, ExtraAsset, Top Shelf Image, Top Shelf Image Wide
```

## How this project is set up

An `expo prebuild --no-install` result with `@react-native-tvos/config-tv`, with the native
directory **committed on purpose** — that is the condition all three issues need. On top of
the vanilla prebuild output, `tools/apply-native-catalog.mjs` applies three deviations that
make the project look like one whose TV target was made in Xcode:

1. brand assets named `App Icon & Top Shelf Image.brandassets` with an `App Icon` image
   stack inside (Xcode's naming), instead of config-tv's `TVAppIcon`
2. `ASSETCATALOG_COMPILER_APPICON_NAME` and `Info.plist` `CFBundleIcons` pointing at it
3. a second catalog, `Extra.xcassets`, registered in the Xcode project

Two clearly labelled art sets make the outcome readable at a glance: **blue `NATIVE`** is
committed in `ios/`, **green `REPACKED`** is referenced from `app.config.js` and is what a
repack should inject. `npm run art` regenerates both, `npm run native-catalog` re-applies
the deviations after an `expo prebuild --clean`.

## Not in scope

The flat tvOS icon (config-tv duplicates one image into the Front, Middle and Back layers,
so the repacked icon loses its parallax) belongs to
[`react-native-tvos/config-tv`](https://github.com/react-native-tvos/config-tv) and is
reported separately.
