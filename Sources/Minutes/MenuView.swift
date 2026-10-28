import MinutesCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if controller.firstRunNoticeNeeded {
                        firstRunNotice
                    }

                    ForEach(controller.recoverable) { item in
                        recoveryNotice(item)
                    }

                    recordingRow

                    if controller.isRecording, controller.systemAudioNotice != nil {
                        Notice(text: "No system audio detected", tone: .warning)
                    }
                    if !controller.modelReady {
                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "settings")
                        } label: {
                            Text("Open Settings")
                                .font(.ui(Size.small, weight: .medium))
                                .foregroundStyle(Ink.accentDeep)
                        }
                        .buttonStyle(.plain)
                    }
                    if controller.microphoneBlocked {
                        HStack(spacing: 12) {
                            Button { controller.openMicrophoneSettings() } label: {
                                Text("Open Microphone Settings")
                                    .font(.ui(Size.small, weight: .medium))
                                    .foregroundStyle(Ink.accentDeep)
                            }
                            .buttonStyle(.plain)
                            Button { controller.refreshPermissions() } label: {
                                Text("Recheck permission")
                                    .font(.ui(Size.small, weight: .medium))
                                    .foregroundStyle(Ink.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    notesSection

                    if !controller.log.isEmpty {
                        detailsSection
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)

            HLine()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 400, height: 500)
        .background(Ink.surface)
        .foregroundStyle(Ink.ink)
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshPermissions()
            if controller.endpointStatus == nil {
                controller.testEndpoint()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            controller.refreshPermissions()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.ui(13, weight: .medium))
                .foregroundStyle(Ink.accentDeep)
            Text("Minutes")
                .font(.ui(15, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Spacer()
            if controller.isRecording {
                Text(Timecode.string(from: controller.elapsed))
                    .font(.mono(Size.small))
                    .foregroundStyle(Ink.muted)
            }
        }
    }

    // MARK: - First run

    private var firstRunNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio is transcribed on this Mac. Text is sent to your model gateway for notes.")
                .font(.ui(Size.small))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                controller.acknowledgeFirstRunNotice()
            } label: {
                Text("Continue")
                    .font(.ui(Size.small, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Ink.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.lineStrong)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Ink.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.line)))
    }

    // MARK: - Interrupted recordings

    private func recoveryNotice(_ item: RecoverableRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A recording from \(item.manifest.startedAt.formatted(date: .abbreviated, time: .shortened)) was not written up. \(Timecode.string(from: item.duration)) of audio and your notes were kept.")
                .font(.ui(Size.small))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { controller.recover(item) } label: {
                    Text("Write it up").font(.ui(Size.small, weight: .semibold)).foregroundStyle(Ink.accentDeep)
                }
                .buttonStyle(.plain)
                Button { controller.discard(item) } label: {
                    Text("Delete").font(.ui(Size.small, weight: .medium)).foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Ink.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.warn.opacity(0.5))))
    }

    // MARK: - Recording

    private var recordingRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Untitled meeting", text: $controller.draft.title)
                .textFieldStyle(.plain)
                .font(.ui(19, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .disabled(
                    controller.phase == .starting || controller.isRecording
                        || controller.phase.isBusy)

            Button {
                controller.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: controller.isRecording
                            ? "stop.fill" : "circle.fill"
                    )
                    .font(.ui(12))
                    Text(controller.isRecording ? "Stop" : "Record")
                        .font(.ui(14, weight: .semibold))
                }
                .foregroundStyle(Ink.accentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Ink.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .disabled(
                !controller.isRecording
                    && (controller.phase == .starting || controller.phase.isBusy))
            .opacity(
                !controller.isRecording
                    && (controller.phase == .starting || controller.phase.isBusy)
                    ? 0.45 : 1)

            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isRecording ? (controller.capturedSilence ? Ink.warn : Color.red) : Ink.faint)
                    .frame(width: 8, height: 8)
                Text(controller.statusLine)
                    .font(.ui(Size.small))
                    .foregroundStyle(controller.capturedSilence ? Ink.warn : Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Mic")
                            .font(.ui(Size.label))
                            .foregroundStyle(Ink.faint)
                            .frame(width: 44, alignment: .leading)
                        LevelMeter(level: controller.level, active: true)
                    }
                    HStack(spacing: 6) {
                        Text("System")
                            .font(.ui(Size.label))
                            .foregroundStyle(Ink.faint)
                            .frame(width: 44, alignment: .leading)
                        LevelMeter(level: controller.systemLevel, active: true)
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PaneLabel(text: "Notes")
            TextEditor(text: $controller.draft.bullets)
                .font(.ui(14))
                .foregroundStyle(Ink.ink)
                .scrollContentBackground(.hidden)
                .disabled(controller.phase == .starting || controller.phase.isBusy)
                .frame(height: 100)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Ink.panel)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line)))
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.ui(Size.tiny))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.ui(Size.small))
        .foregroundStyle(Ink.faint)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton(
                icon: "clock.arrow.circlepath", title: "Meetings",
                action: {
                    // An accessory app has no dock icon, so a window it opens
                    // has to be brought forward by hand.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: MinutesWindow.library)
                })

            footerButton(
                icon: "folder", title: "Open meeting", labelVisible: false,
                action: { controller.openNotesFolder() })

            Spacer()

            footerButton(
                icon: "gearshape", title: "Settings",
                action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                })
            .keyboardShortcut(",")

            footerButton(
                icon: "power", title: "Quit", labelVisible: false,
                action: { NSApplication.shared.terminate(nil) })
        }
    }

    private func footerButton(
        icon: String, title: String, labelVisible: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.ui(Size.tiny))
                if labelVisible {
                    Text(title)
                        .font(.ui(Size.small))
                }
            }
            .foregroundStyle(Ink.muted)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Ink.surface2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(active ? Ink.accentDeep : Ink.faint)
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
            .font(.ui(Size.small))
            .foregroundStyle(tone == .warning ? Ink.warn : Ink.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Ink.panel)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.line)))
    }
}
