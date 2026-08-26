# repack-tv-repro

Minimal reproduction for four `@expo/repack-app` issues that hit TV apps with committed
native directories. Everything runs locally: **no Apple or Google account, no signing, no
EAS** — a tvOS simulator build and an Android debug build are enough.

```bash
npm install
./repro.sh ios        # issues 1, 2, 4
./repro.sh android    # issue 3
```

Each run prints a `[BUG]` / `[ OK]` line per issue and exits non-zero while any of them
reproduce. To check a fix, point it at another version or at a local checkout:

```bash
./repro.sh ios --repack-version 0.11.0
./repro.sh ios --repack-version file:../repack-app/packages/repack-app
```

Verified with `@expo/repack-app@0.10.0`, `expo@56.0.20`,
`react-native@npm:react-native-tvos@0.85.3-3`, `@react-native-tvos/config-tv@0.1.6`,
Xcode 26.6, tvOS 26.5 simulator, Android build-tools 37.0.0.

## What already works

Credit where due: on 0.10.0 the TV icon pipeline itself works. Repack detects a TV target,
compiles the tvOS brand assets with `--platform appletvos --target-device tv`, and rewrites
`android:banner` to the resource config-tv generated. The repro shows the Android banner
swap going from `drawable/banner` to `drawable/tv_banner`, correctly. The four issues below
are what stops us shipping it.

## The issues

| # | What happens | Consequence |
|---|---|---|
| 1 | The repacked `Assets.car` holds `App Icon - Small`, but the app's `Info.plist` still asks for `App Icon` | tvOS finds no icon and has no fallback, so the app shows Apple's placeholder tile |
| 2 | The brand assets to compile are picked with the first `*.brandassets` glob hit | which icon wins depends on filesystem order, and the build setting that names it is ignored |
| 3 | `android:versionCode` is set from the Expo config, defaulting to `1` | a Gradle-versioned app drops from `101395450` to `1` and cannot install as an update |
| 4 | Only the first `**/*.xcassets` is compiled | every other asset catalog silently disappears from the binary |

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

| before | after |
|---|---|
| ![source](docs/tvos-1-source-native-icon.png) | ![repacked](docs/tvos-2-after-repack-placeholder.png) |

The blue `NATIVE` tile is the art committed in `ios/`. The repack was supposed to replace
it with the green `REPACKED` tile from `app.config.js` — the art *is* in the new
`Assets.car`, under a name nothing points at.

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

### 3. `versionCode` falls back to `1`

The Android manifest updater computes the version code from the Expo config with a default
of `1`. A project that versions Android in `build.gradle` (this one uses `101395450`) has
nothing to read in the config, so the repacked APK is stamped `versionCode 1` and Android
refuses it as an update over the source build. Falling back to the source APK's existing
`versionCode` instead of `1` would fix it.

### 4. Non-first asset catalogs are dropped

```
Multiple .xcassets directories found. Trying to use the first one.
```

`Extra.xcassets/ExtraAsset` is in the source app's `Assets.car` and gone from the repacked
one. `actool` accepts several catalogs, so compiling all of them would preserve them. Real
apps split colours, launch images and app assets across catalogs; today each of those
silently loses whatever is not in the first one.

## How this project is set up

An `expo prebuild --no-install` result with `@react-native-tvos/config-tv`, with the native
directories **committed on purpose** — that is the condition all four issues need. On top
of the vanilla prebuild output, `tools/apply-native-catalog.mjs` applies four deviations
that make the project look like one whose TV target was made in Xcode:

1. brand assets named `App Icon & Top Shelf Image.brandassets` with an `App Icon` image
   stack inside (Xcode's naming), instead of config-tv's `TVAppIcon`
2. `ASSETCATALOG_COMPILER_APPICON_NAME` and `Info.plist` `CFBundleIcons` pointing at it
3. a second catalog, `Extra.xcassets`, registered in the Xcode project
4. `versionCode` in `build.gradle`, and `android:banner` pointing at the project's own
   `drawable/banner`

Two clearly labelled art sets make the outcome readable at a glance: **blue `NATIVE`** is
committed in `ios/` and `android/`, **green `REPACKED`** is referenced from
`app.config.js` and is what a repack should inject. `npm run art` regenerates both,
`npm run native-catalog` re-applies the deviations after an `expo prebuild --clean`.

## Not in scope

The flat tvOS icon (config-tv duplicates one image into the Front, Middle and Back layers,
so the repacked icon loses its parallax) belongs to
[`react-native-tvos/config-tv`](https://github.com/react-native-tvos/config-tv) and is
reported separately.
