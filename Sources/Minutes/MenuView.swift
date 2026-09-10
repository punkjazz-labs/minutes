import MinutesCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    if controller.firstRunNoticeNeeded {
                        firstRunNotice
                    }

                    recordingRow

                    if let notice = controller.systemAudioNotice {
                        // Plain before a meeting, because it is how the permission
                        // works. A warning during one, because then it is a fact about
                        // this recording.
                        Notice(text: notice, tone: controller.isRecording ? .warning : .plain)
                    }
                    if let error = controller.userError {
                        Notice(text: error, tone: .warning)
                    }
                    if let completion = controller.completionNotice {
                        Notice(text: completion, tone: .plain)
                    }
                    if !controller.modelReady {
                        Notice(
                            text: "The speech model is not downloaded yet.",
                            tone: .warning)
                        Button("Open Settings") {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "settings")
                        }
                        .controlSize(.small)
                    }
                    if controller.microphoneBlocked {
                        VStack(alignment: .leading, spacing: 6) {
                            if let notice = controller.microphoneNotice {
                                Notice(text: notice, tone: .warning)
                            }
                            HStack {
                                Button("Open Microphone Settings") { controller.openMicrophoneSettings() }
                                    .controlSize(.small)
                                Button("Recheck permission") { controller.refreshPermissions() }
                                    .controlSize(.small)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes you type during the meeting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controller.draft.bullets)
                            .font(.system(size: 12))
                            .disabled(controller.phase == .starting || controller.phase.isBusy)
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

                }
                .padding(14)
            }
            Divider()
            footer
                .padding(14)
        }
        .frame(width: 400, height: 640)
        .onAppear {
            controller.refreshPermissions()
            if controller.endpointStatus == nil {
                controller.testEndpoint()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
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
            TextField("Meeting title", text: $controller.draft.title)
                .textFieldStyle(.roundedBorder)
                .disabled(
                    controller.phase == .starting || controller.isRecording || controller.phase.isBusy)

            HStack(spacing: 10) {
                Button(controller.isRecording ? "Stop and write up" : "Record") {
                    controller.toggleRecording()
                }
                .keyboardShortcut("r")
                .buttonStyle(.borderedProminent)
                .disabled(
                    !controller.isRecording && (controller.phase == .starting || controller.phase.isBusy))

                if controller.isRecording {
                    Circle()
                        .fill(controller.capturedSilence ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                    Text(Timecode.string(from: controller.elapsed))
                        .font(.system(.body, design: .monospaced))
                }
                Spacer()
            }

            if controller.isRecording {
                HStack(spacing: 6) {
                    Text("Mic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    LevelMeter(level: controller.level, active: true)
                }
                HStack(spacing: 6) {
                    Text("System")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    LevelMeter(level: controller.systemLevel, active: true)
                }
            } else {
                LevelMeter(level: controller.level, active: false)
            }

            Text(controller.statusLine)
                .font(.caption)
                .foregroundStyle(controller.capturedSilence ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let endpointStatus = controller.endpointStatus {
                Text(endpointStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Meetings") {
                    // An accessory app has no dock icon, so a window it opens
                    // has to be brought forward by hand.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: MinutesWindow.library)
                }
                .controlSize(.small)

                Button(controller.lastMeetingURL == nil ? "Open notes folder" : "Open this meeting") {
                    controller.openNotesFolder()
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
            HStack {
                Button("Settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
                .controlSize(.small)
                .keyboardShortcut(",")
                Spacer()
            }
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
