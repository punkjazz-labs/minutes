# 0001: a native Swift menu bar app, built with Swift Package Manager

Date: 2026-08-04
Status: accepted for v0.1

## Context

Spec 17 in the basement repository leaves the shape of the program open and
names two candidates:

1. A Go core with a Swift capture sidecar inside a signed `.app`, serving a
   loopback page in the browser, reusing basement's packaging scripts.
2. A native Swift app.

The spec is not neutral about one thing: capture must be native Swift on
macOS, and the app must be a signed `.app` bundle, because TCC keys off the
signing identity and a bare executable never even raises the permission
prompt.

Two further facts about this project decided the rest:

- The product is asked for as a menu bar app. Shape 1 puts the interface in a
  browser tab, which is a different product surface.
- The machine this is built on has the Command Line Tools and no Xcode.
  `xcodebuild` is unavailable, so the build has to work with `swift build`.

## Decision

A native Swift app, built as a Swift Package Manager package, with SwiftUI
`MenuBarExtra` for the menu bar surface. Four targets:

- `MinutesCore`, a library holding everything that is not a window: settings,
  capture interfaces, the speech engine seam, the transcript arithmetic, the
  notes client and the storage layout.
- `Minutes`, the menu bar app.
- `minutes-cli`, a command line face over the same core, so model download,
  transcription and notes generation can be exercised without a window or a
  permission prompt.
- `minutes-checks`, the verification suite.

The `.app` bundle is assembled by `scripts/build-app.sh` from the SPM build
output, with `packaging/macos/Info.plist` carrying `LSUIElement`,
`NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`.

## The checks are an executable, not XCTest

XCTest ships with Xcode. On a Command Line Tools installation `swift test`
fails with "no such module XCTest", so an XCTest suite here would be a suite
nobody on this machine could run. `minutes-checks` is an ordinary executable
with a small assertion harness. It exits non-zero on failure, which is what a
build gate needs, and it runs with the toolchain that is actually present.

If Xcode is installed later, moving these files to a test target is
mechanical. The checks already use only the public API of `MinutesCore`.

## macOS floor

`LSMinimumSystemVersion` is 14.4. Core Audio process taps need 14.2 and are
documented as best from 14.4, and that is the capture path v0.2 will take.
macOS 26.1 fixed several audio capture bugs, which is an argument for a higher
floor, and that argument should be settled with measurements when taps are
actually implemented rather than by raising the floor speculatively now.

## Consequences

- A second design language to maintain, as the spec warned. Nothing is shared
  with basement's console.
- The build is verified by running it. `swift build` and `swift run
  minutes-checks` both work on a Command Line Tools machine.
- Signing is ad-hoc. A Developer ID identity and notarisation are not wired
  up, so this build is not fit for distribution and the README says so.
