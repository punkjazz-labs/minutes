import MinutesCore
import SwiftUI

/// The one window the app has. The list is the root and a meeting is pushed
/// onto it, so the back control in the title bar is the way out of a meeting
/// and there is never a second window to find.
struct LibraryWindow: View {

    @StateObject private var model = LibraryModel()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(model: model, open: { path.append($0.id) })
                .navigationTitle("minutes")
                .navigationDestination(for: String.self) { MeetingDetailView(path: $0) }
        }
        .background(Ink.surface)
        .frame(minWidth: 820, minHeight: 480)
        .preferredColorScheme(.dark)
        .onChange(of: path) { _, current in
            // Coming back from a meeting whose notes were written again, or
            // whose title was changed, shows the new state rather than the old.
            if current.isEmpty { model.reload() }
        }
    }
}

/// The meetings on disk, as a dense table. One row per meeting, the search
/// snippet under the title, and the three row actions on the right.
struct LibraryView: View {

    @ObservedObject var model: LibraryModel
    let open: (MeetingSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            HLine()
            headerRow
            HLine()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.hits) { hit in
                        MeetingRow(
                            hit: hit,
                            model: model,
                            selected: model.selection == hit.id,
                            open: { show(hit.meeting) })
                        HLine()
                    }
                }
            }
            if let failure = model.failure {
                HLine()
                Text(failure)
                    .font(.ui(Size.small))
                    .foregroundStyle(Ink.fail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .background(Ink.surface)
        .onAppear { model.reload() }
        .confirmationDialog(
            model.pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Search:")
                    .font(.ui(Size.row))
                    .foregroundStyle(Ink.faint)
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.ui(Size.row))
                    .foregroundStyle(Ink.ink)
                if let hitsText = model.hitsText {
                    Text(hitsText)
                        .font(.ui(Size.tiny))
                        .foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Ink.bg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.lineStrong)))
            .frame(maxWidth: 340)

            Spacer(minLength: 12)

            HStack(spacing: 0) {
                Text(model.folderText)
                    .font(.mono(Size.tiny))
                    .foregroundStyle(Ink.faint)
                if let service = model.syncService {
                    Text(" · syncs to \(service)")
                        .font(.ui(Size.tiny))
                        .foregroundStyle(Ink.warn)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            PaneLabel(text: "Date").frame(width: Column.date, alignment: .leading)
            PaneLabel(text: "Meeting").frame(maxWidth: .infinity, alignment: .leading)
            PaneLabel(text: "Length").frame(width: Column.length, alignment: .trailing)
            PaneLabel(text: "Notes").frame(width: Column.state, alignment: .leading)
            Color.clear.frame(width: Column.actions)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func show(_ meeting: MeetingSummary) {
        model.selection = meeting.id
        open(meeting)
    }
}

enum Column {
    static let date: CGFloat = 104
    static let length: CGFloat = 62
    static let state: CGFloat = 118
    static let actions: CGFloat = 168
}

private struct MeetingRow: View {

    let hit: MeetingSearchHit
    @ObservedObject var model: LibraryModel
    let selected: Bool
    let open: () -> Void

    @State private var hovering = false
    @FocusState private var renameFocused: Bool

    private var meeting: MeetingSummary { hit.meeting }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(meeting.dateText())
                .font(.ui(Size.row))
                .foregroundStyle(Ink.muted)
                .monospacedDigit()
                .frame(width: Column.date, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if model.renaming == meeting.id {
                    TextField("", text: $model.renameText)
                        .textFieldStyle(.plain)
                        .font(.ui(Size.row, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .focused($renameFocused)
                        .onSubmit { model.commitRename(meeting) }
                        .onExitCommand { model.cancelRename() }
                        .onAppear { renameFocused = true }
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Ink.bg)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.lineStrong)))
                } else {
                    Text(meeting.title)
                        .font(.ui(Size.row, weight: .medium))
                        .foregroundStyle(Ink.ink)
                }
                if let snippet = hit.snippet {
                    snippetText(snippet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(meeting.lengthText)
                .font(.ui(Size.row))
                .foregroundStyle(Ink.muted)
                .monospacedDigit()
                .frame(width: Column.length, alignment: .trailing)

            Text(meeting.notesState.label)
                .font(.ui(Size.tiny))
                .foregroundStyle(stateColor)
                .frame(width: Column.state, alignment: .leading)
                .padding(.leading, 12)

            HStack(spacing: 0) {
                WordButton(title: "Rename") { model.beginRename(meeting) }
                WordButton(title: "Files") { model.reveal(meeting) }
                WordButton(title: "Delete", hoverTint: Ink.fail) { model.pendingDelete = meeting }
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(selected ? Ink.surface2 : (hovering ? Ink.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selection = meeting.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
    }

    private func snippetText(_ snippet: SearchSnippet) -> some View {
        (Text("\"" + snippet.before)
            + Text(snippet.match).foregroundColor(Ink.warn).fontWeight(.medium)
            + Text(snippet.after + "\""))
            .font(.ui(Size.small))
            .foregroundStyle(Ink.faint)
            .lineLimit(1)
    }

    private var stateColor: Color {
        switch meeting.notesState {
        case .written: return Ink.muted
        case .pending: return Ink.warn
        case .transcriptOnly: return Ink.faint
        }
    }
}
