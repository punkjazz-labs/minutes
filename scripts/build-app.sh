#!/bin/bash
#
# Assembles Minutes.app from the Swift Package Manager build.
#
# macOS grants microphone and audio capture permission to a signed bundle, not
# to a bare executable, so the app has to be a .app before any of the capture
# work can be tried by hand. This script produces an ad-hoc signed bundle,
# which is enough to raise the permission prompt on the machine that built it.
# It is not a distributable build: a Developer ID identity and notarisation are
# not wired up in v0.1.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/build/Minutes.app"

echo "Building minutes in $CONFIGURATION configuration"
swift build -c "$CONFIGURATION" --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/minutes" "$APP/Contents/MacOS/minutes"
cp "$ROOT/packaging/macos/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Swift Package Manager resource bundles are found next to the executable.
for bundle in "$BUILD_DIR"/*.bundle; do
	[ -e "$bundle" ] || continue
	cp -R "$bundle" "$APP/Contents/MacOS/"
done

# Ad-hoc signature. TCC keys off the signing identity, so a rebuild with a
# different identity is a different app as far as the privacy database is
# concerned, and the permission has to be granted again.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
	echo "codesign failed. The bundle is built but macOS will not grant it microphone access."
	exit 1
}

echo "Built $APP"
echo "Signed ad-hoc. This is not a notarised build and is not fit for distribution."
echo "Open it with: open \"$APP\""
