.PHONY: build release checks app run fetch-models probe settings clean

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
