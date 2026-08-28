import Foundation
import MinutesCore

/// The version number lives in two files that are edited by hand.
///
/// `MinutesBuild.version` is what the menu, the CLI banner, the `User-Agent`
/// and every `meta.json` report. `CFBundleShortVersionString` in
/// packaging/macos/Info.plist is what Finder, the installer and macOS report.
/// Nothing joins them, so a release can ship a bundle whose menu says one
/// number while its plist says another. This check joins them.
///
/// It reads the plist from the source tree rather than from a built bundle, so
/// it needs no build and it fails at the moment the two files disagree.
func packagingChecks(_ run: CheckRun) {
    run.section("Packaging")

    // #filePath is this file, Sources/MinutesChecks/PackagingChecks.swift, so
    // three steps up is the repository root. The checks run from make, from
    // the release script and from any directory, so the root cannot be taken
    // from the working directory.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL = root.appendingPathComponent("packaging/macos/Info.plist")

    guard let data = try? Data(contentsOf: plistURL) else {
        run.failed("packaging/macos/Info.plist can be read")
        return
    }

    guard
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let entries = plist as? [String: Any]
    else {
        run.failed("packaging/macos/Info.plist is a property list")
        return
    }

    // A missing key reads as "(none)" and fails against the real version,
    // which is what a plist with no version number deserves.
    let short = entries["CFBundleShortVersionString"] as? String ?? "(none)"

    run.equal(
        short, MinutesBuild.version,
        "the bundle version and the source version are the same number")
}
