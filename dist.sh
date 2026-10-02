#!/bin/bash
# Build and package a release ZIP. Usage: VERSION=1.1 ./dist.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${VERSION:-1.0}"
# VERSION is also used in a filename.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*([a-zA-Z0-9._-]*)$ ]]; then
    echo 'VERSION must start with a number and contain only letters, digits, dots, underscores or hyphens.' >&2
    exit 1
fi
DIST="$ROOT/dist"
ZIP_NAME="MacSetup-$VERSION.zip"
VERSION="$VERSION" "$ROOT/build.sh"
mkdir -p "$DIST"
# Preserve bundle metadata and signatures, matching the reference release.sh.
ditto -c -k --keepParent "$ROOT/build/MacSetup.app" "$DIST/$ZIP_NAME"
(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
cat "$DIST/$ZIP_NAME.sha256"
printf '\nRelease artifact: %s\n' "$DIST/$ZIP_NAME"
