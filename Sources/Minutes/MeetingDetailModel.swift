import AppKit
import Foundation
import MinutesCore
import SwiftUI

/// The id of the app's one window, so the menu opens the window that is
/// already there rather than another one.
enum MinutesWindow {
    static let library = "minutes-library"
}

/// The endpoint the app talks to, built from the settings in force.
enum Endpoint {
    static func client(
        settings: AppSettings,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) -> OpenAICompatibleNotesClient {
        OpenAICompatibleNotesClient(
            baseURL: settings.notesBaseURL,
            model: settings.notesModel,
            apiKey: keyStore.effectiveKey())
    }
}

/// Questions and answers live for as long as the app runs and are written
/// nowhere. Held here rather than in the window so closing a meeting and
/// opening it again does not throw them away.
@MainActor
final class AskStore {
    static let shared = AskStore()
    private var conversations: [String: AskConversation] = [:]

    func conversation(for path: String, title: String) -> AskConversation {
        if let existing = conversations[path] { return existing }
        let created = AskConversation(title: title)
        conversations[path] = created
        return created
    }
}

/// One meeting on screen: the notes with their anchors, the transcript, and
/// the questions asked about it.
@MainActor
final class MeetingDetailModel: ObservableObject {

    @Published private(set) var record: MeetingRecord?
    @Published private(set) var anchored = AnchoredNotes(lines: [], unanchored: [])
    @Published var hotLine: Int?
    @Published var question = ""
    @Published private(set) var turnsAsked: [AskConversation.Turn] = []
    /// The transcript in speaker turns, worked out once per load.
    @Published private(set) var turns: [TranscriptTurn] = []
    @Published var transcriptQuery = "" {
        didSet {
            guard transcriptQuery != oldValue else { return }
            matches = TranscriptFile.matches(transcriptQuery, in: transcript)
            matchCursor = nil
            if let first = matches.first { jump(to: first) }
        }
    }
    @Published private(set) var matches: [Int] = []
    private var matchCursor: Int?
    @Published private(set) var isAsking = false
    @Published private(set) var askFailure: String?
    @Published private(set) var isRewriting = false
    @Published private(set) var failure: String?

    let path: String
    /// Called when the notes on disk changed, so the list beside this meeting
    /// shows the new state.
    var onChanged: (() -> Void)?
    private let settingsStore: any SettingsStoring
    private var conversation: AskConversation?

    init(path: String, settingsStore: any SettingsStoring = UserDefaultsSettingsStore()) {
        self.path = path
        self.settingsStore = settingsStore
    }

    var settings: AppSettings { settingsStore.load() }
    var library: MeetingLibrary { MeetingLibrary(settings: settings) }

    var title: String { record?.summary.title ?? "" }

    /// The line under the title: when it was, how long it ran, and whether
    /// both sides were recorded.
    var metaText: String {
        guard let summary = record?.summary else { return "" }
        var parts = [summary.dateText(), summary.lengthText]
        if summary.bothSidesRecorded { parts.append("both sides recorded") }
        return parts.joined(separator: " · ")
    }

    var transcript: [TranscriptLine] { record?.transcript ?? [] }
    var ownerLines: [String] { record?.ownerLines ?? [] }

    func load() {
        let directory = MeetingDirectory(url: URL(fileURLWithPath: path, isDirectory: true))
        guard let summary = MeetingSummary.read(directory) else {
            failure = LibraryError.notAMeeting(directory.url.lastPathComponent).localizedDescription
            return
        }
        let loaded = library.record(for: summary)
        record = loaded
        anchored = loaded.anchoredNotes
        turns = TranscriptTurn.group(loaded.transcript)
        matches = TranscriptFile.matches(transcriptQuery, in: loaded.transcript)
        let conversation = AskStore.shared.conversation(for: path, title: summary.title)
        self.conversation = conversation
        turnsAsked = conversation.turns
        isAsking = conversation.isAsking
        askFailure = conversation.failure
    }

    /// What the notes pane says when there are no model notes to show.
    var notesPlaceholder: String {
        switch record?.summary.notesState {
        case .pending:
            let reason = record?.notes?.pendingReason.map { " \($0)" } ?? ""
            return "The notes are waiting.\(reason) Write notes again when the endpoint is back."
        case .transcriptionFailed:
            return "The speech engine could not read this meeting, so there is nothing to write notes from. The audio was kept."
        case .transcriptOnly:
            return "This meeting has a transcript and no notes. Write notes to make them."
        default:
            return "The model wrote nothing for this meeting."
        }
    }

    /// "3 of 12" while stepping through matches, "12 found" before.
    var matchText: String? {
        guard !transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if matches.isEmpty { return "none" }
        if let matchCursor { return "\(matchCursor + 1) of \(matches.count)" }
        return matches.count == 1 ? "1 line" : "\(matches.count) lines"
    }

    func nextMatch() { stepMatch(by: 1) }
    func previousMatch() { stepMatch(by: -1) }

    private func stepMatch(by step: Int) {
        guard !matches.isEmpty else { return }
        let next = ((matchCursor ?? (step > 0 ? -1 : 0)) + step + matches.count) % matches.count
        matchCursor = next
        jump(to: matches[next])
    }

    func reveal() {
        guard let directory = record?.summary.directory.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Jumping

    func jump(to lineIndex: Int) {
        hotLine = lineIndex
    }

    func copyTranscript() {
        guard let record else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.transcriptText, forType: .string)
    }

    // MARK: - Writing the notes again

    func rewriteNotes() {
        guard let summary = record?.summary, !isRewriting else { return }
        isRewriting = true
        failure = nil
        let current = settings
        let client = Endpoint.client(settings: current)
        let library = MeetingLibrary(settings: current)

        Task { @MainActor in
            do {
                _ = try await library.rewriteNotes(
                    for: summary,
                    using: client,
                    endpoint: current.notesBaseURL,
                    model: current.notesModel)
                load()
                onChanged?()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isRewriting = false
        }
    }

    // MARK: - Asking

    /// Asks one of the ready-made questions, the way typing it would.
    func ask(_ preset: String) {
        question = preset
        ask()
    }

    func ask() {
        guard let conversation, let record else { return }
        guard let request = conversation.begin(question, transcript: record.transcriptText) else { return }
        question = ""
        isAsking = true
        askFailure = nil
        let client = Endpoint.client(settings: settings)

        Task { @MainActor in
            do {
                let answer = try await client.ask(request)
                conversation.finish(answer, for: request)
            } catch {
                conversation.fail(error)
            }
            turnsAsked = conversation.turns
            isAsking = conversation.isAsking
            askFailure = conversation.failure
        }
    }
}
