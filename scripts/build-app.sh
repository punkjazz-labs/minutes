#!/bin/bash
#
# Assembles Minutes.app from the Swift Package Manager build.
#
# macOS grants microphone and audio capture permission to a signed bundle, not
# to a bare executable, so the app has to be a .app before any of the capture
# work can be tried by hand.
#
# The script signs the bundle in one of two ways.
#
#   SIGN_IDENTITY unset   Ad-hoc signature. Good on the machine that built it
#                         and on no other machine. This is the default and it
#                         needs no identity and no network.
#   SIGN_IDENTITY set     Developer ID signature with the hardened runtime,
#                         a timestamp from Apple, and the entitlements file.
#                         This is the signature a distributable build needs.
#                         scripts/package-release.sh drives that path and adds
#                         the disk image, the notarisation and the staple.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/build/Minutes.app"
ENTITLEMENTS="$ROOT/packaging/macos/entitlements.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

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

# TCC keys off the signing identity, so a rebuild with a different identity is
# a different app as far as the privacy database is concerned, and the
# permission has to be granted again. Moving from the ad-hoc signature to the
# Developer ID signature is exactly that kind of change.

# ---------------------------------------------------------------------------
# What the entitlements file grants, and why it grants nothing else.
#
# The hardened runtime is a requirement of notarisation, and it closes doors
# that an ad-hoc build leaves open. Each door needs a key, and each key is a
# claim about the app, so the file lists one key and stops.
#
# com.apple.security.device.audio-input
#   The app records the microphone. Under the hardened runtime the microphone
#   service is refused to a process that does not carry this key, and it is
#   refused before the person is ever asked. Apple documents the key as the
#   one that covers the built-in microphone and audio input through Core
#   Audio, so this is the key the microphone path needs.
#
# The Core Audio process tap, meaning system audio, was researched separately
# because it is a second and different permission. The conclusion is that it
# needs no entitlement of its own. The reasoning:
#
#   1. The tap is gated by TCC, not by code signing. It sits in its own
#      privacy category, the one that NSAudioCaptureUsageDescription names,
#      and that string is already in packaging/macos/Info.plist. macOS reads
#      the string, asks the person, and records the answer against the app.
#   2. Apple publishes no hardened runtime entitlement for that category. The
#      published resource access keys cover the microphone, the camera,
#      location, contacts, calendars, photos and Apple events. System audio
#      is not among them, so there is no key to add.
#   3. The reference implementations agree. Apple's sample and the public
#      write-ups of this API ship the Info.plist string alone, keep the
#      hardened runtime on for notarisation, and add no audio entitlement.
#
# So the risk was the other way round: an entitlement that is not needed is
# still a claim, and a claim the app cannot justify is worse than a missing
# one. The file grants audio-input and nothing more.
#
# Two keys were considered and left out on evidence from this build:
#
#   com.apple.security.cs.disable-library-validation is not needed. The
#   bundle carries one Mach-O file and no nested code. `otool -L` shows only
#   /usr/lib and /System/Library, so the app loads no library from another
#   team.
#
#   com.apple.security.cs.allow-jit is not needed. The speech model is data,
#   not code the app maps as executable. Core ML hands the model to the
#   system, and the Neural Engine work happens in a system process rather
#   than in this one. This was tested, not assumed: the command line face was
#   signed with this same identity, this same hardened runtime and this same
#   entitlements file, and it transcribed a real file with the model on the
#   Neural Engine. See the README.
#
# The bundle has no nested code, so the signature is applied once, to the
# bundle, and --deep is not used to create it. --deep is still used to verify.
# ---------------------------------------------------------------------------

if [ -n "$SIGN_IDENTITY" ]; then
	codesign --force \
		--sign "$SIGN_IDENTITY" \
		--options runtime \
		--entitlements "$ENTITLEMENTS" \
		--timestamp \
		"$APP" || {
		echo "codesign failed with identity: $SIGN_IDENTITY"
		exit 1
	}

	echo "Built $APP"
	echo "Signed with a Developer ID identity, hardened runtime on, timestamped."
else
	codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
		echo "codesign failed. The bundle is built but macOS will not grant it microphone access."
		exit 1
	}

	echo "Built $APP"
	echo "Signed ad-hoc. This is not a notarised build and is not fit for distribution."
fi

echo "Open it with: open \"$APP\""
