import MinutesCore
import SwiftUI

/// Posted when a meeting has been written to the notes folder, so an open
/// library shows it without being asked.
extension Notification.Name {
    static let minutesMeetingWritten = Notification.Name("minutes.meetingWritten")
}

/// The one window the app has: every meeting in a list on the left, grouped by
/// day, and the one selected open on the right.
///
/// A list beside the open meeting, rather than a list a meeting is pushed onto,
/// is how a desktop reads a pile of documents: moving from one meeting to the
/// next is one click or one arrow key, and the list never leaves the screen.
struct LibraryWindow: View {

    @StateObject private var model: LibraryModel
    private let settingsStore: any SettingsStoring

    init(settingsStore: any SettingsStoring = UserDefaultsSettingsStore()) {
        self.init(model: LibraryModel(settingsStore: settingsStore), settingsStore: settingsStore)
    }

    init(model: LibraryModel, settingsStore: any SettingsStoring) {
        self.settingsStore = settingsStore
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        // A split the owner can drag, drawn on the app's own surfaces rather
        // than the system sidebar material, so the list and the meeting read
        // as one page.
        HSplitView {
            MeetingList(model: model)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
            Group {
                if let path = model.selection {
                    MeetingDetailView(path: path, settingsStore: settingsStore, onChanged: { model.reload() })
                        .id(path)
                } else {
                    emptyDetail
                }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.selectionTitle ?? "Meetings")
        .frame(minWidth: 980, minHeight: 600)
        .background(Ink.surface)
        .preferredColorScheme(.dark)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .minutesMeetingWritten)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: model.hits.isEmpty ? "waveform" : "doc.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.faint)
            Text(model.hits.isEmpty ? "No meetings yet" : "Choose a meeting")
                .font(.title(20))
                .foregroundStyle(Ink.ink)
            Text(
                model.hits.isEmpty
                    ? "Record one from the menu bar. Each meeting is written to \(model.folderText) as plain files you can read without this app."
                    : "Its notes, what was said, and a box to ask about it open here."
            )
            .font(.ui(Size.row))
            .foregroundStyle(Ink.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.surface)
    }
}

/// The list of meetings, under day headings, with search above and the notes
/// folder below.
private struct MeetingList: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search meetings", text: $model.query, count: model.hitsText)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            list
            folderFooter
        }
        .background(Ink.panel)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.items) { hit in
                                MeetingRow(
                                    hit: hit, searching: searching, selected: model.selection == hit.id,
                                    select: { model.selection = hit.id }
                                )
                                .id(hit.id)
                                .contextMenu { menu(for: hit.meeting) }
                            }
                        } header: {
                            Text(day.title)
                                .font(.ui(Size.small, weight: .semibold))
                                .foregroundStyle(Ink.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .background(Ink.panel)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            // Up and down move through the meetings, the way a list of
            // documents does in every Mac app.
            .onKeyPress(.upArrow) {
                step(-1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                step(1, proxy: proxy)
                return .handled
            }
        }
        .overlay {
            if model.hits.isEmpty && searching {
                VStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 22, weight: .light))
                    Text("Nothing matches").font(.ui(Size.row, weight: .medium))
                    Text("Titles, notes and every word of the transcripts were searched.")
                        .font(.ui(Size.small))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Ink.faint)
                .padding(24)
            }
        }
        .alert(
            "Rename meeting",
            isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.cancelRename() } })
        ) {
            TextField("Title", text: $model.renameText)
            Button("Rename") {
                if let meeting = renamingMeeting { model.commitRename(meeting) }
            }
            Button("Cancel", role: .cancel) { model.cancelRename() }
        } message: {
            Text("The folder is renamed too. The notes and the transcript are not rewritten.")
        }
        .confirmationDialog(
            "Delete \u{201C}\(model.pendingDelete?.title ?? "")\u{201D}?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete the meeting", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("Its folder is removed: the notes, the transcript, what you typed, and any audio that was kept.")
        }
    }

    private var days: [MeetingDay<MeetingSearchHit>] {
        MeetingDays.group(model.hits, date: { $0.meeting.startedAt })
    }

    private func step(_ offset: Int, proxy: ScrollViewProxy) {
        let ordered = days.flatMap(\.items).map(\.id)
        guard !ordered.isEmpty else { return }
        let current = model.selection.flatMap { ordered.firstIndex(of: $0) }
        let next = current.map { min(max($0 + offset, 0), ordered.count - 1) } ?? 0
        model.selection = ordered[next]
        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(ordered[next]) }
    }

    private var searching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var renamingMeeting: MeetingSummary? {
        model.hits.first { $0.id == model.renaming }?.meeting
    }

    @ViewBuilder
    private func menu(for meeting: MeetingSummary) -> some View {
        Button("Rename…") { model.beginRename(meeting) }
        Button("Show in Finder") { model.reveal(meeting) }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = meeting }
    }

    private var folderFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 10))
            Text(model.folderText)
                .font(.mono(Size.tiny))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let service = model.syncService {
                Chip(text: service, systemImage: "icloud", color: Ink.warn)
                    .help("The notes folder is inside \(service), so the notes are copied there.")
            }
        }
        .foregroundStyle(Ink.faint)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Ink.panel)
        .overlay(alignment: .top) { HLine() }
        .help("The notes folder. Every meeting is a folder of plain files here.")
    }
}

/// One meeting in the list: its title, when and how long, and a mark for the
/// two states that ask for something, notes still waiting and a transcript
/// that failed.
private struct MeetingRow: View {

    let hit: MeetingSearchHit
    let searching: Bool
    let selected: Bool
    let select: () -> Void

    @State private var hovering = false

    private var meeting: MeetingSummary { hit.meeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(meeting.title)
                    .font(.ui(Size.body, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                stateMark
            }
            HStack(spacing: 5) {
                Text(MeetingDays.time(meeting.startedAt))
                Text("·")
                Text(meeting.lengthText)
                if !meeting.bothSidesRecorded && !meeting.tracksRecorded.isEmpty {
                    Text("·")
                    Text("your side only")
                }
            }
            .font(.ui(Size.small))
            .foregroundStyle(Ink.faint)
            .monospacedDigit()

            if searching, let snippet = hit.snippet {
                (Text(snippet.before)
                    + Text(snippet.match).foregroundColor(Ink.warn).fontWeight(.semibold)
                    + Text(snippet.after))
                    .font(.ui(Size.small))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Ink.surface2 : (hovering ? Ink.hover : Color.clear)))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1.5).fill(Ink.accentDeep).frame(width: 3).padding(.vertical, 9)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var stateMark: some View {
        Group {
            switch meeting.notesState {
        case .pending:
            Image(systemName: "clock").foregroundStyle(Ink.warn).help("Notes pending")
        case .transcriptionFailed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.fail).help("Transcription failed")
        case .transcriptOnly:
            Image(systemName: "text.alignleft").foregroundStyle(Ink.faint).help("Transcript only")
        case .written:
            EmptyView()
        }
        }
        .font(.system(size: 10.5))
    }
}
