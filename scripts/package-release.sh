#!/bin/bash
#
# Builds the disk image another Mac can install.
#
# The path is: build and sign the app with a Developer ID identity, ask Apple
# to notarise it, staple the answer to the app, put the app in a disk image
# next to a link to /Applications, sign the image, notarise the image, staple
# the answer to the image, then prove the result.
#
# The app is notarised on its own before it goes in the image, and the image is
# notarised after. That is two submissions and it is on purpose. A staple on
# the image alone leaves the app without one, and an app without a staple has
# to reach Apple over the network the first time it opens. A stapled app opens
# on a Mac that is offline.
#
# Nothing here is a substitute for the one human step. macOS asks for the
# microphone and for system audio in a prompt a person clicks, and it asks
# again when the signing identity changes. The README says which step that is.
#
# Environment:
#   SIGN_IDENTITY    Required. The Developer ID Application identity.
#   NOTARY_PROFILE   The notarytool keychain profile name. Defaults to basement.
#   SKIP_CHECKS      Set to 1 to skip the verification suite. Not advised.
#
# No credential is read, printed or written by this script. The identity is a
# name in the keychain and the profile is a name in the keychain. macOS holds
# the secrets behind both names.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Minutes.app"
DMG="$ROOT/build/Minutes.dmg"
STAGING="$ROOT/build/dmg-staging"
ZIP="$ROOT/build/Minutes-for-notarisation.zip"
VOLUME_NAME="minutes"

NOTARY_PROFILE="${NOTARY_PROFILE:-basement}"
SKIP_CHECKS="${SKIP_CHECKS:-0}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
	echo "SIGN_IDENTITY is not set. This script cannot make a distributable build without it."
	echo "Run 'make dmg', which supplies the identity this project uses."
	exit 1
fi

step() {
	echo
	echo "=== $1"
}

# Submits one file and waits. Fails loudly on any answer that is not Accepted,
# and prints Apple's own log when Apple refuses, because the log is the only
# place that says which rule was broken.
notarise() {
	local path="$1"
	local json="$ROOT/build/notary-$(basename "$path").json"
	local id status

	xcrun notarytool submit "$path" \
		--keychain-profile "$NOTARY_PROFILE" \
		--wait \
		--output-format json > "$json"

	id="$(plutil -extract id raw -o - "$json")"
	status="$(plutil -extract status raw -o - "$json")"

	echo "submission id: $id"
	echo "status:        $status"

	if [ "$status" != "Accepted" ]; then
		echo "Apple did not accept $(basename "$path"). The log follows."
		xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
		exit 1
	fi
}

if [ "$SKIP_CHECKS" != "1" ]; then
	step "Verification suite"
	# A release artefact must never be built from a tree whose checks fail.
	swift run --package-path "$ROOT" minutes-checks | tail -1
fi

step "Build and sign the app"
SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build-app.sh"

step "Check the signature before Apple sees it"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --verbose=2 --entitlements - "$APP"

step "Notarise the app"
rm -f "$ZIP"
# ditto keeps the bundle whole. zip loses the symlinks a bundle can hold.
ditto -c -k --keepParent "$APP" "$ZIP"
notarise "$ZIP"
xcrun stapler staple "$APP"
rm -f "$ZIP"

step "Build the disk image"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# ditto keeps the staple and the signature. cp is not trusted with either.
ditto "$APP" "$STAGING/Minutes.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
# HFS+ rather than APFS. An APFS image needs a newer macOS to open, and the
# app already runs on 14.4, so the image must not raise that floor.
hdiutil create \
	-volname "$VOLUME_NAME" \
	-srcfolder "$STAGING" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"$DMG"
rm -rf "$STAGING"

step "Sign the disk image"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

step "Notarise the disk image"
notarise "$DMG"
xcrun stapler staple "$DMG"

step "Prove it"
# The signature still holds after the staple.
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$DMG"
# Gatekeeper answers for a downloaded image and for the app inside it.
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
spctl --assess --type exec --verbose=4 "$APP"
# The ticket is on the disk, so a Mac with no network can read it.
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

step "The artefact"
shasum -a 256 "$DMG"
echo "size: $(stat -f %z "$DMG") bytes"
echo
echo "$DMG is signed, notarised and stapled."
echo "One human step is left. Open the app and answer the two permission"
echo "prompts. macOS asks again because the signing identity changed."
