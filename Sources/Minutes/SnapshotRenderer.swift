#if DEBUG
import AppKit
import MinutesCore
import SwiftUI

/// Renders the app's real views, filled with a made-up notes folder, to PNG
/// files, so what the app looks like can be checked without a person taking
/// screenshots and without a screen recording permission.
///
///     swift run minutes --render-snapshots <directory>
///
/// Debug builds only. It uses scratch folders and in-memory settings, opens
/// no audio device, sends nothing anywhere, and quits when it is done.
@MainActor
enum SnapshotRenderer {

    static func runIfAsked() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-snapshots"), flag + 1 < arguments.count else {
            return false
        }
        let output = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        Task { @MainActor in
            do {
                try await render(into: output)
                print("Snapshots written to \(output.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Snapshots failed: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func render(into output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let notes = scratch.appendingPathComponent("Meetings", isDirectory: true)
        let featured = try SnapshotFixtures.writeLibrary(in: notes)
        let settings = InMemorySettingsStore(AppSettings(notesFolderPath: notes.path))

        // The menu while a meeting records.
        let recording = RecordingController(
            settingsStore: settings, keyStore: EnvironmentAPIKeyStore(),
            sessionsRoot: scratch.appendingPathComponent("no-sessions"))
        recording.showForSnapshot(
            recording: true, elapsed: 1_847, level: 0.42, systemLevel: 0.31,
            draft: MeetingDraft(
                title: "Pricing call with Northwind",
                bullets: "- renewal terms\n- do they commit to Q4 volume?\n- who owns the follow-up"),
            log: ["Recording started.", "Recording what this Mac plays as well."])
        try await snapshot(MenuView(controller: recording), size: CGSize(width: 400, height: 560), to: output, name: "menu-recording")

        // The menu at rest, offering back a recording a crash left behind,
        // while the last meeting is written up.
        let sessions = scratch.appendingPathComponent("sessions", isDirectory: true)
        let interrupted = try SnapshotFixtures.writeInterruptedSession(in: sessions)
        let idle = RecordingController(
            settingsStore: settings, keyStore: EnvironmentAPIKeyStore(), sessionsRoot: sessions)
        idle.showForSnapshot(
            recording: false,
            draft: MeetingDraft(title: "28 Oct 2026 · 16:02:11"),
            writingUp: [RecordingController.RunningWriteUp(id: "a", title: "Weekly product sync")],
            recoverable: interrupted.map { [$0] } ?? [])
        try await snapshot(MenuView(controller: idle), size: CGSize(width: 400, height: 560), to: output, name: "menu-idle")

        // The library, with one meeting open beside the list.
        let library = LibraryModel(settingsStore: settings)
        library.folderTextForSnapshot = "~/Documents/minutes"
        library.selection = URL(fileURLWithPath: featured.path).resolvingSymlinksInPath().path
        try await snapshot(
            LibraryWindow(model: library, settingsStore: settings), size: CGSize(width: 1_280, height: 780),
            to: output, name: "library")

        let search = LibraryModel(settingsStore: settings)
        search.folderTextForSnapshot = "~/Documents/minutes"
        search.query = "renewal"
        try await snapshot(
            LibraryWindow(model: search, settingsStore: settings), size: CGSize(width: 1_280, height: 520),
            to: output, name: "library-search")

        // One meeting, opened at the line its first chip points at, and then
        // with a question asked about it.
        try await snapshot(
            MeetingDetailView(path: featured.path, settingsStore: settings, initialLine: 3),
            size: CGSize(width: 1_120, height: 760), to: output, name: "meeting")

        let conversation = AskStore.shared.conversation(for: featured.path, title: "Pricing call with Northwind")
        if let request = conversation.begin("Did they agree to the Q4 volume?", transcript: "") {
            conversation.finish(
                AskAnswer(
                    text: "Only on a condition: they commit to Q4 volume if list price holds through March [00:07:10]. Nobody agreed to the condition in the meeting.",
                    model: "profile/general", endpoint: "http://127.0.0.1:4000/v1"),
                for: request)
        }
        try await snapshot(
            MeetingDetailView(path: featured.path, settingsStore: settings, initialPanel: .ask),
            size: CGSize(width: 1_120, height: 760), to: output, name: "meeting-ask")
    }

    private static func snapshot<V: View>(
        _ view: V, size: CGSize, to directory: URL, name: String
    ) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // Let onAppear, the search and the loads run before the picture.
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            hosting.layoutSubtreeIfNeeded()
        }
        hosting.display()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
#endif
