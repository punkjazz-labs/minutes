import Foundation

/// A very small assertion harness.
///
/// XCTest ships with Xcode, and this project is built with the Command Line
/// Tools, so the checks are an ordinary executable. `swift run minutes-checks`
/// exits non-zero when anything fails, which is all a build gate needs.
final class CheckRun {

    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var group = ""

    func section(_ name: String) {
        group = name
        print("\n\(name)")
    }

    func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
            print("  ok   \(what)")
        } else {
            let message = "\(group): \(what) (line \(line))"
            failures.append(message)
            print("  FAIL \(what) (line \(line))")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
        if actual == expected {
            passed += 1
            print("  ok   \(what)")
        } else {
            let message = "\(group): \(what) (line \(line)) got \(actual), wanted \(expected)"
            failures.append(message)
            print("  FAIL \(what) (line \(line)) got \(actual), wanted \(expected)")
        }
    }

    func close(_ actual: Double, _ expected: Double, _ tolerance: Double, _ what: String, line: UInt = #line) {
        expect(abs(actual - expected) <= tolerance, "\(what) (\(actual) within \(tolerance) of \(expected))", line: line)
    }

    func failed(_ what: String, line: UInt = #line) {
        expect(false, what, line: line)
    }

    var exitCode: Int32 { failures.isEmpty ? 0 : 1 }

    func report() {
        print("")
        if failures.isEmpty {
            print("\(passed) checks passed.")
        } else {
            print("\(passed) checks passed, \(failures.count) failed:")
            for failure in failures { print("  \(failure)") }
        }
    }
}

enum Scratch {
    /// A directory that is removed when the process exits.
    static func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-checks-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        created.append(url)
        return url
    }

    nonisolated(unsafe) private static var created: [URL] = []

    static func cleanUp() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
    }
}
