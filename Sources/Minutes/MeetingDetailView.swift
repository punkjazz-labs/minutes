import MinutesCore
import SwiftUI

/// A timestamp inside an answer becomes a link, because an answer is prose and
/// a button cannot sit inside a sentence.
enum AnchorLink {
    static let scheme = "minutes-anchor"

    static func url(line: Int) -> URL? { URL(string: "\(scheme):\(line)") }

    static func line(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }

    /// The answer with its timestamps turned into chips that jump.
    ///
    /// An answer follows the same rule the notes follow: a chip never lands on
    /// the wrong words. Two people who spoke in the same second give two lines
    /// with one timecode between them, so the sentence the timestamp sits in
    /// decides which line it points at, and an undecidable one gets no link.
    static func attributed(_ text: String, transcript: [TranscriptLine]) -> AttributedString {
        let linesByTimecode = NoteAnchoring.linesByTimecode(transcript)

        var out = AttributedString()
        var rest = Substring(text)

        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let candidate = String(rest[rest.index(after: open)..<close])
            guard Timecode.seconds(from: candidate) != nil else {
                out.append(AttributedString(String(rest[...open])))
                rest = rest[rest.index(after: open)...]
                continue
            }

            out.append(AttributedString(String(rest[..<open])))
            var chip = AttributedString(Timecode.short(candidate))
            chip.font = .mono(Size.label)
            let quoted = NoteAnchoring.context(around: open, in: text)
            if let index = NoteAnchoring.lineIndex(for: candidate, quoting: quoted, in: linesByTimecode),
                let url = url(line: index)
            {
                chip.link = url
                chip.foregroundColor = Ink.accentDeep
            } else {
                chip.foregroundColor = Ink.faint
            }
            out.append(chip)
            rest = rest[rest.index(after: close)...]
        }

        out.append(AttributedString(String(rest)))
        return out
    }
}

/// One meeting. The notes are the page, the way a document is: a title, the
/// facts about the meeting as chips, what you typed, and what the model wrote,
/// every line of it carrying a chip back to the words it rests on. Beside it,
/// a panel that holds either the transcript or the questions asked about it.
struct MeetingDetailView: View {

    enum Panel: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case ask = "Ask"
        var id: String { rawValue }
    }

    @StateObject private var model: MeetingDetailModel
    private let onChanged: () -> Void
    private let initialLine: Int?
    @State private var panel: Panel
    @State private var showsPanel = true

    /// - Parameters:
    ///   - onChanged: called when the notes on disk changed.
    ///   - initialLine: a transcript line to open at, marked, the way a click
    ///     on a chip marks it.
    ///   - initialPanel: which side of the panel to open on.
    init(
        path: String,
        settingsStore: any SettingsStoring = UserDefaultsSettingsStore(),
        onChanged: @escaping () -> Void = {},
        initialLine: Int? = nil,
        initialPanel: Panel = .transcript
    ) {
        _model = StateObject(wrappedValue: MeetingDetailModel(path: path, settingsStore: settingsStore))
        self.onChanged = onChanged
        self.initialLine = initialLine
        _panel = State(initialValue: initialPanel)
    }

    var body: some View {
        HStack(spacing: 0) {
            NotesPane(model: model, showsPanel: $showsPanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if showsPanel {
                Rectangle().fill(Ink.line).frame(width: 1)
                SidePanel(model: model, panel: $panel)
                    .frame(width: 370)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Ink.surface)
        .navigationTitle(model.title)
        .onAppear {
            model.onChanged = onChanged
            model.load()
            if let initialLine { model.jump(to: initialLine) }
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let line = AnchorLink.line(from: url) else { return .systemAction }
                show(line)
                return .handled
            })
        .onChange(of: model.hotLine) { _, line in
            // Whatever asked for a line, a chip in the notes or in an answer,
            // the transcript is where it is shown.
            if line != nil {
                withAnimation(.easeOut(duration: 0.15)) {
                    showsPanel = true
                    panel = .transcript
                }
            }
        }
    }

    private func show(_ line: Int) {
        model.jump(to: line)
    }
}

// MARK: - Notes

private struct NotesPane: View {

    @ObservedObject var model: MeetingDetailModel
    @Binding var showsPanel: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 26)

                if !model.ownerLines.isEmpty {
                    PaneLabel(text: "Your notes")
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.ownerLines.enumerated()), id: \.offset) { _, line in
                            bullet(line, color: Ink.ink, anchors: [])
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Ink.panel))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Ink.accentDeep).frame(width: 3).padding(.vertical, 8)
                    }
                    .padding(.bottom, 26)
                }

                HStack {
                    PaneLabel(text: "Notes")
                    Spacer()
                    if !model.anchored.lines.isEmpty {
                        Text("Each timestamp opens what was said")
                            .font(.ui(Size.tiny))
                            .foregroundStyle(Ink.faint)
                    }
                }
                .padding(.bottom, 2)

                if model.anchored.isEmpty {
                    Text(model.notesPlaceholder)
                        .font(.ui(Size.body))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                ForEach(model.anchored.lines) { line in
                    noteLine(line)
                }

                if !model.anchored.unanchored.isEmpty {
                    unanchoredBox
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                actions
            }
            .padding(.bottom, 2)
            Text(model.title)
                .font(.title(30))
                .foregroundStyle(Ink.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let summary = model.record?.summary {
                HStack(spacing: 8) {
                    Chip(text: summary.dateText(), systemImage: "calendar")
                    Chip(text: summary.lengthText, systemImage: "clock")
                    Chip(
                        text: summary.bothSidesRecorded ? "Both sides" : "Your side only",
                        systemImage: summary.bothSidesRecorded ? "person.2.fill" : "person.fill")
                    Chip(
                        text: summary.notesState.chipText, systemImage: summary.notesState.symbol,
                        color: summary.notesState.chipColor)
                }
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(Size.small))
                    .foregroundStyle(Ink.fail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                model.rewriteNotes()
            } label: {
                HStack(spacing: 6) {
                    if model.isRewriting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    }
                    Text(model.isRewriting ? "Writing…" : "Generate notes")
                        .font(.ui(12, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(model.isRewriting ? Ink.faint : Ink.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Ink.surface2)
                        .overlay(Capsule().stroke(Ink.lineStrong)))
            }
            .buttonStyle(.plain)
            .disabled(model.isRewriting)
            .help("Ask the endpoint for the notes again, from the transcript and what you typed. The notes shown stay until it answers.")

            IconButton(systemImage: "folder", help: "Show in Finder") { model.reveal() }
            IconButton(
                systemImage: "sidebar.right",
                help: showsPanel ? "Hide the transcript panel" : "Show the transcript panel",
                tint: showsPanel ? Ink.ink : Ink.muted
            ) {
                withAnimation(.easeOut(duration: 0.15)) { showsPanel.toggle() }
            }
        }
    }

    @ViewBuilder
    private func noteLine(_ line: AnchoredLine) -> some View {
        switch line.kind {
        case .heading:
            Text(line.text)
                .font(.ui(15, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .padding(.top, 20)
                .padding(.bottom, 8)
        case .bullet:
            bullet(line.text, color: Ink.muted, anchors: line.anchors)
                .padding(.bottom, 8)
        case .paragraph:
            anchoredText(line.text, color: Ink.muted, anchors: line.anchors)
                .padding(.bottom, 8)
        }
    }

    private func bullet(_ text: String, color: Color, anchors: [NoteAnchor]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Ink.faint)
                .frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            anchoredText(text, color: color, anchors: anchors)
        }
    }

    private func anchoredText(_ text: String, color: Color, anchors: [NoteAnchor]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.ui(14.5))
                .foregroundStyle(color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            ForEach(anchors) { anchor in
                if let line = anchor.lineIndex {
                    AnchorChip(label: anchor.label, hot: model.hotLine == line) {
                        model.jump(to: line)
                    }
                    .help("Show the line this rests on")
                } else {
                    // Written by the model and not in the transcript. Shown,
                    // struck through, and pointing nowhere.
                    Text(anchor.label)
                        .font(.mono(Size.label))
                        .strikethrough()
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                        .help("This timestamp is not in the transcript, so it points nowhere.")
                }
            }
        }
    }

    private var unanchoredBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                PaneLabel(text: "Not in the transcript", color: Ink.warn)
            }
            .foregroundStyle(Ink.warn)
            Text("The model wrote these, and nothing in the transcript backs them.")
                .font(.ui(Size.tiny))
                .foregroundStyle(Ink.faint)
            ForEach(Array(model.anchored.unanchored.enumerated()), id: \.offset) { _, line in
                Text("\u{201C}\(line)\u{201D}")
                    .font(.ui(Size.row))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.warn.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.warn.opacity(0.25)))
        .padding(.top, 24)
    }
}

// MARK: - The panel: transcript, or questions

private struct SidePanel: View {

    @ObservedObject var model: MeetingDetailModel
    @Binding var panel: MeetingDetailView.Panel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $panel) {
                ForEach(MeetingDetailView.Panel.allCases) { item in
                    Text(item == .ask && !model.turnsAsked.isEmpty ? "Ask (\(model.turnsAsked.count))" : item.rawValue)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch panel {
            case .transcript: TranscriptPanel(model: model)
            case .ask: AskPanel(model: model)
            }
        }
        .background(Ink.panel)
    }
}

private struct TranscriptPanel: View {

    @ObservedObject var model: MeetingDetailModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SearchField(
                    prompt: "Find in transcript", text: $model.transcriptQuery, count: model.matchText,
                    onSubmit: { model.nextMatch() })
                if model.matches.count > 1 {
                    IconButton(systemImage: "chevron.up", help: "Previous match") { model.previousMatch() }
                    IconButton(systemImage: "chevron.down", help: "Next match") { model.nextMatch() }
                }
                IconButton(systemImage: "doc.on.doc", help: "Copy the transcript") { model.copyTranscript() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.transcript.isEmpty {
                            Text("This meeting has no transcript lines.")
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.faint)
                                .padding(.top, 8)
                        }
                        ForEach(model.turns) { turn in
                            turnView(turn)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.hotLine) { _, line in
                    guard let line else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(line, anchor: .center)
                    }
                }
                .onAppear {
                    if let line = model.hotLine { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
    }

    private func turnView(_ turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SpeakerBadge(speaker: turn.speaker, isOwner: turn.isOwner)
                Text(turn.speaker)
                    .font(.ui(Size.row, weight: .semibold))
                    .foregroundStyle(turn.isOwner ? Ink.ink : Ink.them)
                Text(Timecode.short(turn.timecode))
                    .font(.mono(Size.tiny))
                    .foregroundStyle(Ink.faint)
            }
            ForEach(turn.lines) { line in
                transcriptLine(line, showsTime: line.index != turn.id)
                    .id(line.index)
            }
        }
    }

    private func transcriptLine(_ line: TranscriptLine, showsTime: Bool) -> some View {
        let hot = model.hotLine == line.index
        let matched = model.matches.contains(line.index)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(highlighted(line.text))
                .font(.ui(Size.body))
                .foregroundStyle(hot ? Ink.ink : Ink.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(Timecode.short(line.timecode))
                .font(.mono(Size.label))
                .foregroundStyle(hot ? Ink.accentDeep : Ink.faint.opacity(0.7))
                .opacity(showsTime || hot ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hot ? Ink.hot : (matched ? Ink.warn.opacity(0.07) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(hot ? Ink.accentDeep : Color.clear)))
        .padding(.leading, 20)
    }

    /// The line with the words looked for marked, so a match is seen without
    /// reading the whole line.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let needle = model.transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return out }
        var searchStart = out.startIndex
        while searchStart < out.endIndex,
            let range = out[searchStart...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        {
            out[range].foregroundColor = Ink.ink
            out[range].backgroundColor = Ink.warn.opacity(0.35)
            searchStart = range.upperBound
        }
        return out
    }
}

private struct AskPanel: View {

    @ObservedObject var model: MeetingDetailModel

    /// Questions most meetings are asked first. They go to the endpoint like
    /// a typed one, and the answer is held to the transcript like any other.
    private let suggestions = [
        "What was decided?",
        "What are the follow-ups, and who owns them?",
        "What is still open?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.turnsAsked.isEmpty && !model.isAsking && model.askFailure == nil {
                            intro
                        }
                        ForEach(model.turnsAsked) { turn in
                            Text(turn.question)
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface2))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(AnchorLink.attributed(turn.answer, transcript: model.transcript))
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if model.isAsking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Reading the transcript")
                                    .font(.ui(Size.small))
                                    .foregroundStyle(Ink.faint)
                            }
                        }
                        if let failure = model.askFailure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.fail)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.turnsAsked.count) { _, _ in
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            composer
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this meeting")
                .font(.ui(Size.body, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Text("Answers come from the transcript only, with the time of each line they rest on. Nothing is kept after the app quits.")
                .font(.ui(Size.small))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.ask(suggestion)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            Text(suggestion).font(.ui(Size.row))
                        }
                        .foregroundStyle(Ink.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Ink.surface2).overlay(Capsule().stroke(Ink.line)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                "", text: $model.question,
                prompt: Text("Ask about this meeting").foregroundStyle(Ink.faint)
            )
            .textFieldStyle(.plain)
            .font(.ui(Size.row))
            .foregroundStyle(Ink.ink)
            .onSubmit { model.ask() }
            .disabled(model.isAsking)

            Button(action: { model.ask() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(canAsk ? Ink.accentInk : Ink.faint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canAsk ? Ink.accent : Ink.surface2))
            }
            .buttonStyle(.plain)
            .disabled(!canAsk)
            .help("Ask. The answer comes from the transcript only.")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Ink.bg)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Ink.lineStrong)))
    }

    private var canAsk: Bool {
        !model.isAsking && !model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
