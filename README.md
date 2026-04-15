# MacSetup

MacSetup is now a native macOS SwiftUI app for rebuilding a Mac with a brew-first install catalog, a safe settings layer, and a visible manual checklist for the things Apple still keeps behind UI-only or version-sensitive controls.

## What it does

- Shows your install catalog and settings in a native app window.
- Loads the install catalog from a bundled JSON configuration file.
- Can export the active configuration to JSON and import a replacement JSON file.
- Adds menu commands for config import/export, opening the active config directory, and resetting to the bundled config.
- Runs Homebrew installs for supported apps.
- Applies a safe subset of macOS settings with `defaults`.
- Keeps manual steps visible and launchable with deep links.
- Supports dry-run mode so you can preview the work before making changes.

## Run it

```bash
cd /Users/USER/Documents/MacSetup
swift run MacSetupApp
```

## Build a `.app`

```bash
cd /Users/USER/Documents/MacSetup
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MacSetup.xcodeproj \
  -scheme MacSetup \
  -configuration Release \
  -derivedDataPath build
```

The finished app bundle will be at:

```bash
/Users/USER/Documents/MacSetup/build/Build/Products/Release/MacSetup.app
```

Inside the app bundle, the default config lives at:

```bash
/Users/USER/Documents/MacSetup/build/Build/Products/Release/MacSetup.app/Contents/Resources/catalog.json
```

## Current scope

The SwiftUI app already handles the core workflow, but a few things are intentionally still conservative:

- Command Line Tools and Homebrew can now be triggered automatically, but macOS may still require you to confirm installer prompts before the run can continue.
- Direct vendor `PKG`/`DMG`/`ZIP` installers are supported for catalog entries that provide trusted download URLs.
- UI-only settings like Apple Intelligence, Spotlight categories, Liquid Glass tint, and menu bar cleanup still live in the manual checklist.

## Project layout

- `Package.swift`: Swift package definition for the macOS app.
- `MacSetup.xcodeproj`: Native Xcode project that builds a standard `.app` bundle.
- `Sources/MacSetupApp`: App code, models, catalog, runner, and UI.
- `Sources/MacSetupApp/Resources/catalog.json`: Bundled configuration for apps, settings, and manual steps.
- `bin`, `config`, `lib`: Earlier shell-based version kept for reference while the SwiftUI app takes over.

## Config workflow

- `File -> Export JSON` writes the currently active config to a file you choose.
- `File -> Import JSON` loads a replacement config from disk and remembers that file for later launches.
- `Configuration -> Open Active Configuration Directory` reveals the folder containing the current config source.
- `Configuration -> Use Bundled Configuration` switches back to the default `catalog.json` inside the app bundle.
- Settings commands can include special `macsetup:` directives in addition to raw shell commands.
- Use `macsetup:install-rosetta2` inside a setting's `commands` array to optionally install Rosetta 2 on Apple silicon. MacSetup will open the installer in Terminal so the macOS password prompt can appear, similar to the Homebrew flow.

## Recommended next tweaks

- Add profile support like `personal`, `work`, and `gaming`.
- Add signature or checksum verification for direct download installers.
- Add an optional aggressive UI automation mode later if you want more settings enforced automatically.
