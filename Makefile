.PHONY: build release checks app run dmg fetch-models probe settings clean

# The identity and the notary profile this project ships with. Both are names.
# The secrets behind the names stay in the keychain and appear in no file here.
# Set either one in the environment to build with another account.
SIGN_IDENTITY ?= Developer ID Application: Simone Pomposi (E46XB3XSV9)
NOTARY_PROFILE ?= basement

# Everything here works with the Command Line Tools alone. Xcode is not needed
# and xcodebuild is not used.

build:
	swift build

release:
	swift build -c release

# The verification suite. Exits non-zero on any failure.
checks:
	swift run minutes-checks

# The signed .app bundle. macOS only grants microphone access to a bundle.
app:
	./scripts/build-app.sh

run: app
	open build/Minutes.app

# The disk image another Mac can install. Signed, notarised and stapled.
# Needs the network and takes a few minutes, because Apple has to answer twice.
dmg:
	SIGN_IDENTITY="$(SIGN_IDENTITY)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ./scripts/package-release.sh

# Downloads the Parakeet speech model once. Needs the network.
fetch-models:
	swift run minutes-cli fetch-models

# Proves the notes endpoint and the key work before a meeting, not after one.
probe:
	swift run minutes-cli probe

settings:
	swift run minutes-cli settings

clean:
	swift package clean
	rm -rf build
