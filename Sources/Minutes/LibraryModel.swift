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
        didSet { if query != oldValue { reload(debounce: true) } }
    }
    @Published var selection: String?
    @Published var renaming: String?
    @Published var renameText = ""
    @Published var pendingDelete: MeetingSummary?
    @Published private(set) var failure: String?

    private let settingsStore: any SettingsStoring
    /// One cache for the life of the window, so a keystroke reads only the
    /// files that changed since the last search.
    private let cache = MeetingTextCache()
    private var searchTask: Task<Void, Never>?

    init(settingsStore: any SettingsStoring = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
    }

    var settings: AppSettings { settingsStore.load() }
    var library: MeetingLibrary { MeetingLibrary(settings: settings) }

    var folderText: String {
        #if DEBUG
        if let folderTextForSnapshot { return folderTextForSnapshot }
        #endif
        return library.folderText
    }

    #if DEBUG
    /// The folder a screenshot names, so a picture in the repository shows the
    /// default folder and not a scratch path on the Mac that drew it.
    var folderTextForSnapshot: String?
    #endif
    var syncService: String? { library.syncService }

    /// The count beside the search field, in the design's words.
    var hitsText: String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hits.count == 1 ? "1 meeting" : "\(hits.count) meetings"
    }

    /// Searches away from the main thread, so the window never stalls on a
    /// folder of long transcripts. A search that a newer keystroke overtook is
    /// dropped rather than shown.
    func reload(debounce: Bool = false) {
        searchTask?.cancel()
        let library = self.library
        let query = self.query
        let cache = self.cache
        searchTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
            }
            let result = await Task.detached {
                Result { try library.search(query, cache: cache) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let found):
                hits = found
                failure = nil
            case .failure(let error):
                hits = []
                failure = error.localizedDescription
            }
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
