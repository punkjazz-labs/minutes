import AppKit
import Foundation
import MinutesCore
import SwiftUI

/// The library window's state: what is on disk, what was searched for, and
/// which row is being renamed or deleted.
@MainActor
final class LibraryModel: ObservableObject {

    @Published private(set) var hits: [MeetingSearchHit] = []
    @Published var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    @Published var selection: String?
    @Published var renaming: String?
    @Published var renameText = ""
    @Published var pendingDelete: MeetingSummary?
    @Published private(set) var failure: String?

    private let settingsStore: any SettingsStoring

    init(settingsStore: any SettingsStoring = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
    }

    var settings: AppSettings { settingsStore.load() }
    var library: MeetingLibrary { MeetingLibrary(settings: settings) }

    var folderText: String { library.folderText }
    var syncService: String? { library.syncService }

    /// The count beside the search field, in the design's words.
    var hitsText: String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hits.count == 1 ? "1 meeting" : "\(hits.count) meetings"
    }

    func reload() {
        do {
            hits = try library.search(query)
            failure = nil
        } catch {
            hits = []
            failure = error.localizedDescription
        }
    }

    // MARK: - Row actions

    func beginRename(_ meeting: MeetingSummary) {
        renaming = meeting.id
        renameText = meeting.title
    }

    func commitRename(_ meeting: MeetingSummary) {
        let wanted = renameText
        renaming = nil
        guard wanted.trimmingCharacters(in: .whitespacesAndNewlines) != meeting.title else { return }
        do {
            let renamed = try library.rename(meeting, to: wanted)
            selection = renamed.id
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        reload()
    }

    func cancelRename() {
        renaming = nil
    }

    func reveal(_ meeting: MeetingSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.directory.url])
    }

    func confirmDelete() {
        guard let meeting = pendingDelete else { return }
        pendingDelete = nil
        do {
            try library.delete(meeting)
            if selection == meeting.id { selection = nil }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        reload()
    }
}
