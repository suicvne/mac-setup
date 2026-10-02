#!/bin/bash
# Build a universal, ad-hoc signed app. Usage: VERSION=1.1 ./build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
BUILD="$ROOT/build"
APP="$BUILD/MacSetup.app"

# Honor the caller's Xcode selection; fall back when only CLT are selected.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -version >/dev/null
mkdir -p "$BUILD"
xcodebuild -quiet \
    -project "$ROOT/MacSetup.xcodeproj" \
    -scheme MacSetup \
    -configuration Release \
    -derivedDataPath "$BUILD/DerivedData" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CODE_SIGNING_ALLOWED=NO build

# Replace only this script's app output, leaving other build products alone.
rm -rf "$APP"
ditto "$BUILD/DerivedData/Build/Products/Release/MacSetup.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose "$APP"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/MacSetup")"
for ARCH in arm64 x86_64; do
    case " $ARCHITECTURES " in
        *" $ARCH "*) ;;
        *) echo "Missing architecture: $ARCH" >&2; exit 1 ;;
    esac
done
test -f "$APP/Contents/Resources/catalog.json"
printf '\nBuilt: %s (v%s build %s)\n' "$APP" "$VERSION" "$BUILD_NUMBER"
printf 'Run: open "%s"\n' "$APP"
