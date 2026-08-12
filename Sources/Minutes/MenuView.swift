import MinutesCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if controller.firstRunNoticeNeeded {
                firstRunNotice
            }

            recordingRow

            if let notice = controller.microphoneNotice {
                Notice(text: notice, tone: .warning)
            }
            if let notice = controller.systemAudioNotice {
                Notice(text: notice, tone: .plain)
            }
            if !controller.modelReady {
                Notice(
                    text: "The speech model is not downloaded yet. Open settings and download it, or run make fetch-models.",
                    tone: .warning)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes you type during the meeting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.bullets)
                    .font(.system(size: 12))
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("These bullets are the prompt. They are kept word for word in notes.md.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !controller.log.isEmpty {
                Divider()
                activity
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("minutes")
                    .font(.headline)
                Spacer()
                Text("v\(MinutesBuild.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(controller.privacyClaim)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firstRunNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PrivacyClaim.firstRunNotice)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("I understand") { controller.acknowledgeFirstRunNotice() }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private var recordingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $controller.title)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.phase.isBusy)

            HStack(spacing: 10) {
                Button(controller.isRecording ? "Stop and write up" : "Record") {
                    controller.toggleRecording()
                }
                .keyboardShortcut("r")
                .disabled(controller.phase.isBusy)

                if controller.isRecording {
                    Circle()
                        .fill(controller.capturedSilence ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                    Text(Timecode.string(from: controller.elapsed))
                        .font(.system(.body, design: .monospaced))
                }
                Spacer()
            }

            LevelMeter(level: controller.level, active: controller.isRecording)

            Text(controller.statusLine)
                .font(.caption)
                .foregroundStyle(controller.capturedSilence ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Activity")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
    }

    private var footer: some View {
        HStack {
            Button("Meetings") {
                // An accessory app has no dock icon, so a window it opens has
                // to be brought forward by hand.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: MinutesWindow.library)
            }
            .controlSize(.small)

            Button(controller.lastMeetingURL == nil ? "Open notes folder" : "Open this meeting") {
                controller.openNotesFolder()
            }
            .controlSize(.small)

            Button("Settings") { openSettings() }
                .controlSize(.small)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(active ? Color.green : Color.gray)
                    .frame(width: max(2, geometry.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(height: 6)
    }
}

struct Notice: View {
    enum Tone {
        case plain
        case warning
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
