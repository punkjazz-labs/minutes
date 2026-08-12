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
    static func attributed(_ text: String, transcript: [TranscriptLine]) -> AttributedString {
        var byTimecode: [String: Int] = [:]
        for line in transcript where byTimecode[line.timecode] == nil {
            byTimecode[line.timecode] = line.index
        }

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
            if let index = byTimecode[candidate], let url = url(line: index) {
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

/// Notes on the left, transcript on the right, and a question box under the
/// transcript. Every model line that rests on something said carries a chip
/// back to the line it rests on.
struct MeetingDetailView: View {

    @StateObject private var model: MeetingDetailModel

    init(path: String) {
        _model = StateObject(wrappedValue: MeetingDetailModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHead
            HLine()
            HStack(spacing: 0) {
                NotesPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Ink.line).frame(width: 1)
                TranscriptPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.surface)
        .navigationTitle(model.title)
        .onAppear { model.load() }
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let line = AnchorLink.line(from: url) else { return .systemAction }
                model.jump(to: line)
                return .handled
            })
    }

    private var detailHead: some View {
        HStack(spacing: 14) {
            Text(model.title)
                .font(.ui(15, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Text(model.metaText)
                .font(.ui(12))
                .foregroundStyle(Ink.muted)
            Spacer(minLength: 8)
            if let failure = model.failure {
                Text(failure)
                    .font(.ui(Size.small))
                    .foregroundStyle(Ink.fail)
                    .lineLimit(2)
            }
            OutlineButton(title: "Write notes again", enabled: !model.isRewriting) {
                model.rewriteNotes()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Notes

private struct NotesPane: View {

    @ObservedObject var model: MeetingDetailModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    PaneLabel(text: "Notes")
                    Spacer()
                    HStack(spacing: 8) {
                        Text("■ you").foregroundStyle(Ink.ink)
                        Text("■ model").foregroundStyle(Ink.muted)
                    }
                    .font(.ui(Size.tiny))
                }
                .padding(.bottom, 10)

                if !model.ownerLines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.ownerLines.enumerated()), id: \.offset) { _, line in
                            bullet(line, color: Ink.ink, anchors: [])
                        }
                    }
                    .padding(.bottom, 6)
                }

                ForEach(model.anchored.lines) { line in
                    noteLine(line)
                }

                if !model.anchored.unanchored.isEmpty {
                    unanchoredBox
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func noteLine(_ line: AnchoredLine) -> some View {
        switch line.kind {
        case .heading:
            Text(line.text)
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .padding(.top, 14)
                .padding(.bottom, 6)
        case .bullet:
            bullet(line.text, color: Ink.muted, anchors: line.anchors)
                .padding(.bottom, 6)
        case .paragraph:
            anchoredText(line.text, color: Ink.muted, anchors: line.anchors)
                .padding(.bottom, 6)
        }
    }

    private func bullet(_ text: String, color: Color, anchors: [NoteAnchor]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.ui(Size.row))
                .foregroundStyle(Ink.faint)
            anchoredText(text, color: color, anchors: anchors)
        }
    }

    private func anchoredText(_ text: String, color: Color, anchors: [NoteAnchor]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.ui(Size.body))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(anchors) { anchor in
                if let line = anchor.lineIndex {
                    AnchorChip(label: anchor.label, hot: model.hotLine == line) {
                        model.jump(to: line)
                    }
                }
            }
        }
    }

    private var unanchoredBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            PaneLabel(text: "Not in the transcript", color: Ink.warn)
            ForEach(Array(model.anchored.unanchored.enumerated()), id: \.offset) { _, line in
                Text("\"\(line)\"")
                    .font(.ui(Size.row))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line)))
        .overlay(alignment: .leading) {
            Rectangle().fill(Ink.warn).frame(width: 3)
        }
        .padding(.top, 18)
    }
}

// MARK: - Transcript and the question box

private struct TranscriptPane: View {

    @ObservedObject var model: MeetingDetailModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PaneLabel(text: "Transcript")
                Spacer()
                WordButton(title: "Copy") { model.copyTranscript() }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.transcript) { line in
                            transcriptLine(line)
                                .id(line.index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .onChange(of: model.hotLine) { _, line in
                    guard let line else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(line, anchor: .center)
                    }
                }
            }

            askBox
        }
    }

    private func transcriptLine(_ line: TranscriptLine) -> some View {
        let hot = model.hotLine == line.index
        return HStack(alignment: .top, spacing: 10) {
            Text(line.timecode)
                .font(.mono(Size.tiny))
                .foregroundStyle(Ink.faint)
                .frame(width: 58, alignment: .leading)
            Text(line.speaker)
                .font(.ui(Size.tiny, weight: .semibold))
                .foregroundStyle(line.isOwner ? Ink.muted : Ink.them)
                .frame(width: 46, alignment: .leading)
            Text(line.text)
                .font(.ui(Size.row))
                .foregroundStyle(hot ? Ink.ink : Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hot ? Ink.hot : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(hot ? Ink.accentDeep : Color.clear)))
    }

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HLine()
            VStack(alignment: .leading, spacing: 8) {
                if !model.turns.isEmpty || model.askFailure != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.turns) { turn in
                            Text(turn.question)
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10).fill(Ink.surface2))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(AnchorLink.attributed(turn.answer, transcript: model.transcript))
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let failure = model.askFailure {
                            Text(failure)
                                .font(.ui(Size.row))
                                .foregroundStyle(Ink.fail)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 2)
                }

                HStack(spacing: 8) {
                    TextField("Ask about this meeting", text: $model.question)
                        .textFieldStyle(.plain)
                        .font(.ui(Size.row))
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Ink.bg)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.lineStrong)))
                        .onSubmit { model.ask() }
                        .disabled(model.isAsking)

                    Button(action: { model.ask() }) {
                        Text("Ask")
                            .font(.ui(Size.row, weight: .semibold))
                            .foregroundStyle(Ink.accentInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Ink.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isAsking)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(Ink.panel)
        }
    }
}
